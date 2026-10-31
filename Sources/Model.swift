import AVFoundation
import Foundation

/// A summary waiting for the user's OK (shown as an alert).
struct SummaryAsk: Identifiable {
    let id = UUID()
    let session: Session
    let mode: ReadMode
    let title: String
    let message: String
    let canRun: Bool
    let onConfirm: () -> Void
    let onDone: (Bool) -> Void
}

/// Wires the reply store, summarizer and speaker: heard markers, auto-read, headers, commands from
/// Claude Code, and the confirmation before any Claude call.
///
/// No LLM call is ever made automatically. The automatic paths (`autoRead`, `autoReadProgress`)
/// only queue text the hooks already saved. The one Claude call this app can start is the Haiku
/// summary (`Summarizer.summary(.quick)`), and only behind the confirmation alert.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = Store()
    let speaker = Speaker()
    let summarizer = Summarizer()

    @Published var ask: SummaryAsk?

    /// Replies shorter than this have no summary option: it would gain nothing.
    static let summaryMinWords = 70

    private var lastSid: String?
    private var request = 0   // the newest explicit play request wins
    private var inbox: CommandInbox?
    private var lastStatus = Data()

    private init() {
        Voices.migrate()
        VoiceCatalog.shared.refresh()
        speaker.onItemStart = { [weak self] sid in
            self?.store.markHeard(sid)
            self?.lastSid = sid
        }
        store.onNewReply = { [weak self] s in self?.autoRead(s) }
        store.onNewProgress = { [weak self] n in self?.autoReadProgress(n) }
        inbox = CommandInbox { [weak self] c in self?.run(c) }
        syncProgressFlag()
        writeStatus()
        // Keeps `voicectl status`, the summary language and the progress flag current.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncProgressFlag()
                self?.writeStatus()
            }
        }
    }

    // MARK: playing

    /// Play a reply. Summary modes must already be cached (see ensureSummary).
    func play(_ s: Session, mode: ReadMode = .full, from start: Int = 0) {
        request += 1
        let r = request
        guard mode != .full else {
            speaker.play([fullItem(s)], from: start)
            return
        }
        Task {
            guard let text = await summarizer.summary(for: s, mode), r == request else { return }
            speaker.play([summaryItem(s, text, mode)], from: start)
        }
    }

    func queue(_ s: Session) { speaker.enqueue(withHeader(fullItem(s), s)) }

    /// Every unheard reply, full text, top to bottom.
    func playAllNew() {
        let new = store.visible.filter(\.isNew)
        guard !new.isEmpty else { return }
        request += 1
        speaker.play(new.map { withHeader(fullItem($0), $0) })
    }

    /// Auto-read always uses the full reply: no Claude calls without a click.
    private func autoRead(_ s: Session) {
        guard shouldAutoRead(s.id) else { return }
        speaker.dropQueuedProgress(sid: s.id)    // the final reply supersedes progress not yet spoken
        var it = fullItem(s)
        if needsHeader(s.id) { it = withHeader(it, project: s.displayProject, title: s.title) }
        speaker.enqueue(it)
    }

    /// With "Read progress" on, the short messages between tool calls are read as they appear.
    /// Same gate as `autoRead`; text only, no Claude calls.
    private func autoReadProgress(_ n: ProgressNote) {
        guard UserDefaults.standard.bool(forKey: "readProgress"), shouldAutoRead(n.sid) else { return }
        let lines = Sentences.split(n.text)
        guard !lines.isEmpty else { return }
        var it = PlayItem(sid: n.sid, lines: lines, voiceID: Voices.replyVoiceID(for: n.text), isProgress: true)
        if needsHeader(n.sid) {
            let meta = store.readMeta(n.sid)
            it = withHeader(it, project: meta["project"] ?? "", title: meta["title"] ?? "")
        }
        speaker.enqueue(it)
    }

    /// Auto-read is on for every session, or for this one, and the session is not hidden.
    private func shouldAutoRead(_ sid: String) -> Bool {
        let d = UserDefaults.standard
        return !store.isHidden(sid)
            && (d.bool(forKey: "autoAll") || AutoRead.contains(d.string(forKey: "autoSids") ?? "", sid))
    }

    /// Say "From <project>." when the listener may not know whose text comes next.
    private func needsHeader(_ sid: String) -> Bool {
        if speaker.state != .idle { return speaker.items.last?.sid != sid }
        return lastSid != sid
    }

    // MARK: summaries (always confirmed first)

    /// Run `then` once the summary exists. If it is not cached, ask the user first.
    func ensureSummary(_ s: Session, _ mode: ReadMode, onConfirm: @escaping () -> Void = {},
                       then: @escaping (Bool) -> Void) {
        guard mode != .full else { then(true); return }
        if summarizer.cached(s, mode) != nil { onConfirm(); then(true); return }
        let lang = Languages.selected
        switch mode {
        case .quick:
            ask = SummaryAsk(
                session: s, mode: mode, title: "Create a low-cost summary?",
                message: "Claude Haiku 5.5 turns this \(s.words)-word reply into a short summary in \(lang.name). "
                    + "It uses your Claude subscription, takes about 5 seconds and very little usage. "
                    + "It sees only this reply, not the rest of the conversation.",
                canRun: true, onConfirm: onConfirm, onDone: then)
        case .session:
            // Never run from here: the session writes it itself (see hook/commands/summarize-for-voice.md).
            ask = SummaryAsk(
                session: s, mode: mode, title: "No session summary yet",
                message: "In the Claude Code session \(s.displayProject), run /summarize-for-voice. The session "
                    + "writes the summary itself from its own memory, which costs about one short message "
                    + "there while its cache is warm. It appears here and plays on its own. "
                    + "Nothing is sent from this app.",
                canRun: false, onConfirm: {}, onDone: then)
        case .full:
            break
        }
    }

    /// Called by the alert's Summarize button.
    func confirm(_ a: SummaryAsk) {
        ask = nil
        a.onConfirm()
        Task {
            let ok = await summarizer.summary(for: a.session, a.mode) != nil
            a.onDone(ok)
        }
    }

    func cancel(_ a: SummaryAsk) {
        ask = nil
        a.onDone(false)
    }

    // MARK: items

    /// The full reply, read by the voice for its language when that differs from the main voice.
    func fullItem(_ s: Session) -> PlayItem {
        PlayItem(sid: s.id, lines: ReplyDoc.of(s).lines, voiceID: Voices.replyVoiceID(for: s.text))
    }

    private func summaryItem(_ s: Session, _ text: String, _ mode: ReadMode) -> PlayItem {
        // A Haiku summary is in the chosen summary language; a session's own is in whatever it wrote.
        let voice = mode == .quick ? Voices.summaryVoiceID() : Voices.replyVoiceID(for: text)
        return PlayItem(sid: s.id, lines: Sentences.split(text), mode: mode, voiceID: voice)
    }

    private func withHeader(_ it: PlayItem, _ s: Session) -> PlayItem {
        withHeader(it, project: s.displayProject, title: s.title)
    }

    private func withHeader(_ it: PlayItem, project: String, title: String) -> PlayItem {
        let name = (project.isEmpty ? "session" : project).replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let line = "From \(name)." + (title.isEmpty ? "" : " \(title).")
        var out = it
        out = PlayItem(sid: it.sid, lines: [line] + it.lines, mode: it.mode, voiceID: it.voiceID,
                       headerLines: it.headerLines + 1, isProgress: it.isProgress)
        return out
    }

    // MARK: commands from Claude Code (hook/voicectl)

    func run(_ c: VoiceCommand) {
        let d = UserDefaults.standard
        switch c.action {
        case "pause": speaker.pause()
        case "resume": speaker.resume()
        case "stop": speaker.stop()
        case "restart": speaker.restart()
        case "next": speaker.skip()
        case "prev": speaker.prev()
        case "back": speaker.back(c.count)
        case "fwd": speaker.next(c.count)
        case "play": playCommand(sid: c.sid, summary: c.arg == "summary")
        case "auto": d.set(c.arg == "on", forKey: "autoAll")
        case "progress": d.set(c.arg == "on", forKey: "readProgress"); syncProgressFlag()
        case "speed":
            let x = Double(c.arg ?? "") ?? 1
            d.set(min(0.7, max(0.3, x * Double(AVSpeechUtteranceDefaultSpeechRate))), forKey: "rate")
        case "summary": if let sid = c.arg { importSummary(sid) }
        default: break
        }
        writeStatus()
    }

    /// "/voice play": the session's latest reply (or the newest unheard one), or its summary.
    private func playCommand(sid: String?, summary: Bool) {
        let target = store.sessions.first { $0.id == sid && !$0.hidden }
            ?? store.visible.first(where: \.isNew) ?? store.visible.first
        guard let s = target else { return }
        guard summary else { play(s); return }
        let mode: ReadMode? = summarizer.cached(s, .session) != nil ? .session
            : summarizer.cached(s, .quick) != nil ? .quick : nil
        if let mode {
            play(s, mode: mode)
        } else {
            request += 1
            speaker.play([PlayItem(sid: "_note", lines: ["There is no summary for this reply yet."])])
        }
    }

    /// The session wrote its own summary (/summarize-for-voice): keep it, and read it now. The user
    /// asked for it, so it plays even when auto-read is off.
    private func importSummary(_ sid: String) {
        let file = Paths.inbox.appendingPathComponent("summary-\(sid).txt")
        let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: file)
        guard !text.isEmpty, let s = store.sessions.first(where: { $0.id == sid }) else { return }
        summarizer.storeImported(text, for: s)
        request += 1
        var it = summaryItem(s, text, .session)
        if lastSid != s.id { it = withHeader(it, s) }
        speaker.play([it])
    }

    // MARK: progress flag + status

    /// The PostToolUse hook does nothing unless this file exists (zero cost while the mode is off).
    func syncProgressFlag() {
        let fm = FileManager.default
        let on = UserDefaults.standard.bool(forKey: "readProgress")
        let exists = fm.fileExists(atPath: Paths.progressFlag.path)
        if on && !exists {
            try? fm.createDirectory(at: Paths.base, withIntermediateDirectories: true)
            fm.createFile(atPath: Paths.progressFlag.path, contents: Data())
        } else if !on && exists {
            try? fm.removeItem(at: Paths.progressFlag)
        }
    }

    /// What `voicectl status` prints, and the language /summarize-for-voice should write in.
    func writeStatus() {
        let d = UserDefaults.standard
        let state = speaker.state == .playing ? "playing" : speaker.state == .paused ? "paused" : "idle"
        var line = 0, total = 0
        if speaker.lines.indices.contains(speaker.index) {
            let l = speaker.lines[speaker.index]
            line = l.local + 1
            total = speaker.lines(ofItem: l.item).count
        }
        let sid = speaker.displayItem.map { speaker.items[$0].sid }
        let obj: [String: Any] = [
            "state": state,
            "reply": store.sessions.first { $0.id == sid }?.displayProject ?? "",
            "line": line, "lines": total,
            "autoAll": d.bool(forKey: "autoAll"), "readProgress": d.bool(forKey: "readProgress"),
            "rate": (Settings.speed * 100).rounded() / 100,
            "summaryLanguage": Languages.selected.name,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              data != lastStatus else { return }
        lastStatus = data
        try? data.write(to: Paths.status, options: .atomic)
    }
}

/// Per-session auto-read flags, stored as a comma-separated @AppStorage string.
enum AutoRead {
    static func contains(_ list: String, _ sid: String) -> Bool {
        list.split(separator: ",").contains { $0 == sid }
    }

    static func toggled(_ list: String, _ sid: String) -> String {
        var ids = list.split(separator: ",").map(String.init)
        if let i = ids.firstIndex(of: sid) { ids.remove(at: i) } else { ids.append(sid) }
        return ids.joined(separator: ",")
    }
}
