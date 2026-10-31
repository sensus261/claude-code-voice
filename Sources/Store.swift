import Foundation

/// Latest reply of one Claude Code session, as saved by the Stop hook
/// (~/.claude/tts/talk hook) into ~/.claude/tts/state/replies/<sid>.{txt,json}.
struct Session: Identifiable, Equatable {
    let id: String
    var project: String
    var title: String
    var text: String
    var modified: Date
    var heard: Date?

    var isNew: Bool { heard.map { modified > $0 } ?? true }
    var displayProject: String { project.isEmpty ? "session" : project }
    var displayTitle: String { title.isEmpty ? String(text.prefix(80)) : title }
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

enum Paths {
    static let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/tts/state")
    static let replies = base.appendingPathComponent("replies")
    static let heard = base.appendingPathComponent("heard")
}

/// Watches the replies folder (polling; it holds a few dozen tiny files).
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    /// A session finished a new reply since the app started.
    var onNewReply: ((Session) -> Void)?

    private var seen: [String: Date] = [:]
    private var textCache: [String: (Date, String)] = [:]
    private var timer: Timer?
    private var firstScan = true

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.replies, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Paths.heard, withIntermediateDirectories: true)
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.replies, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Session] = []
        var fresh: [Session] = []

        for f in files where f.pathExtension == "txt" && !f.lastPathComponent.hasPrefix(".") {
            let sid = f.deletingPathExtension().lastPathComponent
            guard let mod = modDate(f) else { continue }
            let text: String
            if let c = textCache[sid], c.0 == mod {
                text = c.1
            } else {
                text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                textCache[sid] = (mod, text)
            }
            let meta = readMeta(sid)
            let s = Session(id: sid, project: meta["project"] ?? "", title: meta["title"] ?? "",
                            text: text, modified: mod,
                            heard: modDate(Paths.heard.appendingPathComponent(sid)))
            out.append(s)
            if !firstScan, seen[sid] != mod, !text.isEmpty { fresh.append(s) }
            seen[sid] = mod
        }

        out.sort { $0.modified > $1.modified }
        if out != sessions { sessions = out }
        firstScan = false
        fresh.sorted { $0.modified < $1.modified }.forEach { onNewReply?($0) }
    }

    func markHeard(_ sid: String) {
        guard !sid.hasPrefix("_") else { return }
        FileManager.default.createFile(atPath: Paths.heard.appendingPathComponent(sid).path, contents: Data())
        scan()
    }

    private func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func readMeta(_ sid: String) -> [String: String] {
        let url = Paths.replies.appendingPathComponent("\(sid).json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }
}

enum Sentences {
    private static let boundary = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[\p{Lu}\d"(])"#)

    /// Each line is at least one sentence; long lines split at ". X".
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).flatMap { sub -> [String] in
            let line = String(sub)
            return ranges(line).map { (line as NSString).substring(with: $0) }
        }
    }

    /// Sentence ranges (UTF-16) within one paragraph, trimmed, skipping symbol-only bits.
    static func ranges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var cuts: [NSRange] = []
        var start = 0
        for m in boundary.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            cuts.append(NSRange(location: start, length: m.range.location - start))
            start = m.range.location + m.range.length
        }
        cuts.append(NSRange(location: start, length: ns.length - start))
        return cuts.compactMap { r in
            var r = r
            while r.length > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: r.location)) ?? " ") {
                r.location += 1; r.length -= 1
            }
            while r.length > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: r.location + r.length - 1)) ?? " ") {
                r.length -= 1
            }
            guard r.length > 0, ns.substring(with: r).rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
            return r
        }
    }
}
