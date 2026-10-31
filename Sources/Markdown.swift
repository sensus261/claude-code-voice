import Foundation

/// A reply parsed from markdown into display blocks plus the sentences to speak,
/// so the Full view can render formatted text and still highlight what is spoken.
struct ReplyDoc {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case bullet(marker: String, indent: Int)
        case code
        case table
        case quote
        case rule
    }

    struct Block: Identifiable {
        let id: Int
        let kind: Kind
        let markdown: String      // inline markdown (code: raw text)
        let rows: [[String]]      // table cells, inline markdown; row 0 = header
        var plain: String { ReplyDoc.plain(markdown) }
    }

    /// One spoken sentence and where it sits in the display.
    struct Spoken {
        let text: String          // what the synthesizer says
        let block: Int
        let range: NSRange?       // within block.plain (UTF-16)
        let row: Int?             // table row
    }

    let blocks: [Block]
    let spoken: [Spoken]

    var lines: [String] { spoken.map(\.text) }

    // MARK: cache

    private static var cache: [String: (Date, ReplyDoc)] = [:]

    /// Parsed reply for a session: raw markdown saved by the hook, else the cleaned text.
    static func of(_ s: Session) -> ReplyDoc {
        if let c = cache[s.id], c.0 == s.modified { return c.1 }
        let md = Paths.replies.appendingPathComponent("\(s.id).md")
        let doc: ReplyDoc
        if let raw = try? String(contentsOf: md, encoding: .utf8), !raw.isEmpty {
            doc = parse(raw)
        } else {
            doc = parse(s.text.replacingOccurrences(of: "\n", with: "\n\n"))   // one paragraph per line
        }
        cache[s.id] = (s.modified, doc)
        return doc
    }

    // MARK: parsing

    private static let headingRE = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
    private static let bulletRE = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let ruleRE = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)
    private static let tableSepRE = try! NSRegularExpression(pattern: #"^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$"#)

    static func parse(_ md: String) -> ReplyDoc {
        var blocks: [Block] = []
        var para: [String] = []
        let lines = md.components(separatedBy: "\n")
        var i = 0

        func add(_ kind: Kind, _ text: String, rows: [[String]] = []) {
            blocks.append(Block(id: blocks.count, kind: kind, markdown: text, rows: rows))
        }
        func flush() {
            if !para.isEmpty { add(.paragraph, para.joined(separator: " ")); para = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("```") {                                   // fenced code
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                add(.code, code.joined(separator: "\n"))
                i += 1
                continue
            }
            if t.isEmpty { flush(); i += 1; continue }

            if let m = match(headingRE, t) {                         // heading
                flush()
                add(.heading(m[1].count), m[2])
            } else if t.hasPrefix("|") {                              // table
                flush()
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    if match(tableSepRE, r) == nil {
                        var cells = r.split(separator: "|", omittingEmptySubsequences: false)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                        if cells.first == "" { cells.removeFirst() }
                        if cells.last == "" { cells.removeLast() }
                        rows.append(cells)
                    }
                    i += 1
                }
                add(.table, "", rows: rows)
                continue
            } else if match(ruleRE, t) != nil {                      // horizontal rule
                flush()
                add(.rule, "")
            } else if let m = match(bulletRE, line) {                // list item (+ continuation lines)
                flush()
                let indent = m[1].count / 2
                let marker = m[2].first?.isNumber == true ? m[2] : "•"
                var text = m[3]
                while i + 1 < lines.count {
                    let next = lines[i + 1]
                    let nt = next.trimmingCharacters(in: .whitespaces)
                    let indented = next.prefix { $0 == " " }.count > m[1].count
                    if nt.isEmpty || !indented || match(bulletRE, next) != nil || nt.hasPrefix("```") { break }
                    text += " " + nt
                    i += 1
                }
                add(.bullet(marker: marker, indent: indent), text)
            } else if t.hasPrefix(">") {                              // quote
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                add(.quote, q.joined(separator: " "))
                continue
            } else {
                para.append(t)
            }
            i += 1
        }
        flush()
        return ReplyDoc(blocks: blocks, spoken: speak(blocks))
    }

    private static func speak(_ blocks: [Block]) -> [Spoken] {
        var out: [Spoken] = []
        for b in blocks {
            switch b.kind {
            case .rule:
                continue
            case .code:
                out.append(Spoken(text: "Code block.", block: b.id, range: nil, row: nil))
            case .table:
                for (r, cells) in b.rows.enumerated() {
                    let text = cells.map(plain).filter { !$0.isEmpty }.joined(separator: ", ")
                    if text.rangeOfCharacter(from: .alphanumerics) != nil {
                        out.append(Spoken(text: Speech.spoken(text, end: true), block: b.id, range: nil, row: r))
                    }
                }
            default:
                let p = b.plain
                let ranges = Sentences.ranges(p)
                for (k, r) in ranges.enumerated() {
                    let sentence = (p as NSString).substring(with: r)
                    let isLast = k == ranges.count - 1
                    out.append(Spoken(text: Speech.spoken(sentence, end: isLast), block: b.id, range: r, row: nil))
                }
            }
        }
        return out
    }

    /// Inline markdown -> the visible characters (same string the view renders).
    static func plain(_ md: String) -> String {
        guard let a = try? AttributedString(
            markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return md }
        return String(a.characters)
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// Turns display text into something that sounds right.
enum Speech {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"https?://\S+"#, "link"),
        (#"→|⇒|->"#, " to "), (#"←"#, " from "), (#"≈|~(?=\d)"#, " about "),
        (#"≥"#, " at least "), (#"≤"#, " at most "), (#"×"#, " times "),
        (#"\[\[|\]\]"#, ""), (#"[ \t]{2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func spoken(_ text: String, end: Bool) -> String {
        var s = text
        for (re, rep) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: rep)
        }
        s = s.trimmingCharacters(in: .whitespaces)
        // a pause after headings and list items that have no final punctuation
        if end, let last = s.last, !".!?:;,".contains(last) { s += "." }
        return s
    }
}
