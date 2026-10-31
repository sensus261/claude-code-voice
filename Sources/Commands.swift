import Foundation

/// A command from Claude Code, dropped as commands/<time>.cmd by hook/voicectl:
/// "pause", "back 3", "play summary --sid <session>", "summary <session>"…
struct VoiceCommand: Equatable {
    let action: String
    let arg: String?
    let sid: String?

    init(action: String, arg: String? = nil, sid: String? = nil) {
        self.action = action
        self.arg = arg
        self.sid = sid
    }

    init?(line: String) {
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var sid: String?
        if let i = words.firstIndex(of: "--sid") {
            if i + 1 < words.count { sid = words[i + 1] }
            words.removeSubrange(i..<min(words.count, i + 2))
        }
        guard let action = words.first else { return nil }
        self.init(action: action, arg: words.count > 1 ? words[1] : nil, sid: sid)
    }

    /// "back 3" -> 3 (1 when missing).
    var count: Int { max(1, min(999, arg.flatMap { Int($0) } ?? 1)) }
}

/// Watches commands/ and hands each command to `handler`, oldest first, then deletes the file.
/// Files older than `maxAge` (the app was not running) are dropped unread: a "stop" from an hour
/// ago must not fire when the app starts.
@MainActor
final class CommandInbox {
    static let maxAge: TimeInterval = 15

    private let dir: URL
    private let handler: (VoiceCommand) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init(dir: URL = Paths.commands, handler: @escaping (VoiceCommand) -> Void) {
        self.dir = dir
        self.handler = handler
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watch()
        // The directory watcher is instant; the timer only covers a missed event.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        drain()
    }

    deinit {
        source?.cancel()
        timer?.invalidate()
    }

    private func watch() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func drain() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "cmd" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let line = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: f)
            guard let mod, Date().timeIntervalSince(mod) <= Self.maxAge,
                  let cmd = VoiceCommand(line: line) else { continue }
            handler(cmd)
        }
    }
}
