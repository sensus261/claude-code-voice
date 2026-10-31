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
    /// Tokens in the session's context when it wrote this reply (nil until looked up, or unknown).
    var context: Int?
    /// Hidden from the list (see Store.hide).
    var hidden = false

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

    /// Hidden sessions: id -> date of the reply they were hidden at (they come back with a newer
    /// reply), or -1 to stay hidden. Kept in UserDefaults.
    @Published private(set) var hiddenAt: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "hiddenSessions") as? [String: Double] ?? [:]

    /// A session finished a new reply since the app started.
    var onNewReply: ((Session) -> Void)?

    var visible: [Session] { sessions.filter { !$0.hidden } }
    var hiddenCount: Int { sessions.lazy.filter(\.hidden).count }

    private var seen: [String: Date] = [:]
    private var textCache: [String: (Date, String)] = [:]
    private var contextCache: [String: (Date, Int?)] = [:]   // per reply, read in the background
    private var contextPending: Set<String> = []
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
            let context = contextCache[sid].flatMap { $0.0 == mod ? $0.1 : nil }
            let s = Session(id: sid, project: meta["project"] ?? "", title: meta["title"] ?? "",
                            text: text, modified: mod,
                            heard: modDate(Paths.heard.appendingPathComponent(sid)), context: context,
                            hidden: Self.hides(hiddenAt[sid], mod))
            out.append(s)
            if contextCache[sid]?.0 != mod { lookUpContext(sid, mod, transcript: meta["transcript"]) }
            if !firstScan, seen[sid] != mod, !text.isEmpty { fresh.append(s) }
            seen[sid] = mod
        }

        out.sort { $0.modified > $1.modified }
        if out != sessions { sessions = out }
        // "Until next reply" entries end when the session replies again or its files are gone.
        let ended = hiddenAt.filter { sid, at in at >= 0 && !out.contains { $0.id == sid && $0.hidden } }
        if !ended.isEmpty { save(hiddenAt.filter { ended[$0.key] == nil }) }
        firstScan = false
        fresh.sorted { $0.modified < $1.modified }.forEach { onNewReply?($0) }
    }

    /// Reads the context size from the session's transcript once per reply, off the main thread.
    private func lookUpContext(_ sid: String, _ mod: Date, transcript: String?) {
        guard !contextPending.contains(sid) else { return }
        contextPending.insert(sid)
        DispatchQueue.global(qos: .utility).async {
            let tokens = Transcript.url(for: sid, hint: transcript).flatMap { Transcript.lastUsage($0)?.tokens }
            DispatchQueue.main.async {
                self.contextPending.remove(sid)
                self.contextCache[sid] = (mod, tokens)
                if let i = self.sessions.firstIndex(where: { $0.id == sid && $0.modified == mod }) {
                    self.sessions[i].context = tokens
                }
            }
        }
    }

    /// Hide a session until it replies again, or for good.
    func hide(_ s: Session, always: Bool) {
        var h = hiddenAt
        h[s.id] = always ? -1 : s.modified.timeIntervalSince1970
        save(h)
        scan()
    }

    func unhide(_ sid: String) {
        var h = hiddenAt
        h[sid] = nil
        save(h)
        scan()
    }

    private func save(_ h: [String: Double]) {
        hiddenAt = h
        UserDefaults.standard.set(h, forKey: "hiddenSessions")
    }

    static func hides(_ at: Double?, _ reply: Date) -> Bool {
        guard let at else { return false }
        return at < 0 || reply.timeIntervalSince1970 <= at + 0.001
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

/// A Claude Code session's transcript (~/.claude/projects/<folder>/<sid>.jsonl).
enum Transcript {
    /// The path the hook saved, else a search of the projects folder.
    static func url(for sid: String, hint: String? = nil) -> URL? {
        if let p = hint ?? readHint(sid), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("\(sid).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Model and context size (input + cache read + cache write) of the session's last main-thread
    /// model call. Subagent and synthetic entries are skipped.
    static func lastUsage(_ url: URL) -> (model: String?, tokens: Int)? {
        for line in tail(url, bytes: 2 * 1024 * 1024).split(separator: "\n").reversed() {
            guard line.contains("\"usage\""), let o = json(line), o["type"] as? String == "assistant",
                  o["isSidechain"] as? Bool != true,
                  let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            guard tokens > 0 else { continue }
            return (msg["model"] as? String, tokens)
        }
        return nil
    }

    static func tail(_ url: URL, bytes: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    }

    static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func readHint(_ sid: String) -> String? {
        let meta = Paths.replies.appendingPathComponent("\(sid).json")
        guard let d = try? Data(contentsOf: meta),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["transcript"] as? String
    }
}

/// "850", "85k", "1.2M"
func tokenCount(_ n: Int) -> String {
    switch n {
    case ..<1000: return "\(n)"
    case ..<1_000_000: return "\(Int((Double(n) / 1000).rounded()))k"
    default: return String(format: "%.1fM", Double(n) / 1_000_000)
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
