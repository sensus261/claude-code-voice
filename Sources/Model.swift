import AppKit
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
/// No LLM call is made unless the user asked for it. The automatic paths (`autoRead`, `autoReadProgress`)
/// only queue text the hooks already saved. The one Claude call this app can start is the Haiku
/// summary (`Summarizer.summary(.quick)`), and only on an explicit request: the confirmation alert,
/// the user saying "summarized" to the headset while "voiceSummary" is on (default off), or, for long
/// replies of auto-read sessions, the "autoSummarize" setting (default off) that is itself that consent.
///
/// Talk back: when a reply or summary has been read to the end and its session is waiting for input
/// (`Waiters`), `ReplyCoordinator` opens a listening window, reads the spoken answer back, and after
/// "send" drops it in reply-in/ for the session's `talk wait` hook.
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

    /// Talk back: the spoken answer to a session. Replaceable, so tests can use a fake microphone.
    private(set) var replies: ReplyCoordinator
    /// Replies of other sessions that arrived while an answer was being taken: read afterwards, newest per session.
    private var held: [String: Session] = [:]
    /// Latest auto-summary request per session: a late summary of an older request is dropped.
    private var autoPending: [String: Int] = [:]
    private var autoCounter = 0
    private var awakeActivity: NSObjectProtocol?

    /// How long an automatic summary may take before the full reply is read instead.
    static var autoSummaryPatience: TimeInterval = 25

    private init() {
        replies = ReplyCoordinator(mic: VoiceListener.shared)
        Voices.migrate()
        VoiceCatalog.shared.refresh()
        speaker.onItemStart = { [weak self] sid in
            self?.store.markHeard(sid)
            if !sid.hasPrefix("_") { self?.lastSid = sid }      // "_note" and "_reply" are not sessions
        }
        speaker.onFinish = { [weak self] item in self?.playbackFinished(item) }
        store.onNewReply = { [weak self] s in self?.autoRead(s) }
        store.onNewProgress = { [weak self] n in self?.autoReadProgress(n) }
        inbox = CommandInbox { [weak self] c in self?.run(c) }
        wireReplies()
        syncProgressFlag()
        syncTalkbackFlag()
        writeStatus()
        // Keeps `voicectl status`, the summary language and the progress and talk-back flags current.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncProgressFlag()
                self?.syncTalkbackFlag()
                self?.writeStatus()
            }
        }
    }

    /// Use another microphone for the spoken answers (tests).
    func useReplyMic(_ mic: ReplyMic) {
        replies = ReplyCoordinator(mic: mic)
        wireReplies()
    }

    private func wireReplies() {
        replies.say = { [weak self] text in
            guard let self else { return }
            request += 1
            speaker.play([PlayItem(sid: "_reply", lines: [text])])
        }
        replies.chime = { NSSound(named: "Tink")?.play() }
        replies.onIdle = { [weak self] in self?.releaseHeld() }
        replies.onChange = { [weak self] in self?.writeStatus() }
    }

    // MARK: playing

    /// Play a reply. Summary modes must already be cached (see ensureSummary).
    /// `offerReply`: once it has been read to the end, listen for a spoken answer (voice-started plays).
    func play(_ s: Session, mode: ReadMode = .full, from start: Int = 0, offerReply: Bool = false) {
        replies.abort()
        request += 1
        let r = request
        guard mode != .full else {
            speaker.play([offerReply ? offering(fullItem(s), s) : fullItem(s)], from: start)
            return
        }
        Task {
            guard let text = await summarizer.summary(for: s, mode), r == request else { return }
            let it = summaryItem(s, text, mode)
            speaker.play([offerReply ? offering(it, s) : it], from: start)
        }
    }

    func queue(_ s: Session) { speaker.enqueue(withHeader(fullItem(s), s)) }

    /// Every unheard reply, full text, top to bottom.
    func playAllNew() {
        let new = store.visible.filter(\.isNew)
        guard !new.isEmpty else { return }
        replies.abort()
        request += 1
        speaker.play(new.map { withHeader(fullItem($0), $0) })
    }

    /// Auto-read reads the full reply, or, only with "autoSummarize" on, a summary of a long one.
    private func autoRead(_ s: Session) { autoRead(s, retrying: false) }

    private func autoRead(_ s: Session, retrying: Bool) {
        guard shouldAutoRead(s.id) || answersByVoice(s.id) else {
            // The waiter is armed by a Stop hook that runs beside the one that saved this reply, so it
            // can be a moment late. Look once more before giving up.
            if !retrying, Self.talkBackOn, !store.isHidden(s.id) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, let now = store.sessions.first(where: { $0.id == s.id }),
                          now.modified == s.modified else { return }      // a newer reply took over
                    autoRead(now, retrying: true)
                }
            }
            return
        }
        if replies.isBusy {
            if replies.activeSid == s.id {
                replies.abort()              // the session moved on: the answer being taken is stale
            } else {
                held[s.id] = s                // not over somebody's answer: after it
                return
            }
        }
        speaker.dropQueuedProgress(sid: s.id)    // the final reply supersedes progress not yet spoken
        autoCounter += 1
        autoPending[s.id] = autoCounter           // any summary still being made for an older reply is stale
        if UserDefaults.standard.bool(forKey: "autoSummarize"), s.words >= Self.summaryMinWords {
            autoSummarize(s, ticket: autoCounter)
        } else {
            autoPending[s.id] = nil
            enqueueAuto(fullItem(s), s)
        }
    }

    private func enqueueAuto(_ item: PlayItem, _ s: Session) {
        var it = offering(item, s)
        if needsHeader(s.id) { it = withHeader(it, project: s.displayProject, title: s.title) }
        speaker.enqueue(it)
    }

    /// "autoSummarize" (off by default) is the user's consent to one low-cost Haiku call per long reply
    /// of an auto-read session. A cached summary is used as it is; if the call fails or takes longer than
    /// `autoSummaryPatience`, the full reply is read instead.
    private func autoSummarize(_ s: Session, ticket: Int) {
        let cached = summarizer.cached(s, .session).map { ($0, ReadMode.session) }
            ?? summarizer.cached(s, .quick).map { ($0, ReadMode.quick) }
        if let (text, mode) = cached {
            autoPending[s.id] = nil
            enqueueAuto(summaryItem(s, text, mode), s)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let text = await summarizer.summary(for: s, .quick)
            finishAutoSummary(s, ticket: ticket, text: text)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoSummaryPatience * 1_000_000_000))
            self?.finishAutoSummary(s, ticket: ticket, text: nil)
        }
    }

    private func finishAutoSummary(_ s: Session, ticket: Int, text: String?) {
        guard autoPending[s.id] == ticket else { return }     // already read, or a newer reply took over
        autoPending[s.id] = nil
        if let text, !text.isEmpty {
            enqueueAuto(summaryItem(s, text, .quick), s)
        } else {
            enqueueAuto(fullItem(s), s)
        }
    }

    /// Replies that waited for a spoken answer to be finished.
    private func releaseHeld() {
        guard !replies.isBusy, !held.isEmpty else { return }
        let waiting = held.values.sorted { $0.modified < $1.modified }
        held = [:]
        waiting.forEach(autoRead)
    }

    /// With "Read progress" on, the short messages between tool calls are read as they appear.
    /// Same gate as `autoRead`; text only, no Claude calls.
    private func autoReadProgress(_ n: ProgressNote) {
        guard UserDefaults.standard.bool(forKey: "readProgress"), shouldAutoRead(n.sid) else { return }
        guard !replies.isBusy else { return }        // stale by the time the answer is done
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

    /// "Answer Claude by voice" is on and this session waits for an answer: its reply is read even when
    /// auto-read is off, so the listener hears what they are about to answer. A waiter exists only in
    /// an interactive session, so `claude -p` runs are never read this way.
    private func answersByVoice(_ sid: String) -> Bool {
        Self.talkBackOn && !store.isHidden(sid) && replies.waiterAlive(sid)
    }

    /// Say "From <project>." when the listener may not know whose text comes next.
    private func needsHeader(_ sid: String) -> Bool {
        // Answering by voice: no "From <project>." announcement, even with several sessions waiting.
        if answersByVoice(sid) { return false }
        // Spoken notes ("_reply", "_note") are not sessions: they must not make the same session look new.
        if speaker.state != .idle { return speaker.items.last(where: { !$0.sid.hasPrefix("_") })?.sid != sid }
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
                       headerLines: it.headerLines + 1, isProgress: it.isProgress,
                       offersReply: it.offersReply, stamp: it.stamp)
        return out
    }

    /// After this item is read to the end, the user may answer the session by voice.
    private func offering(_ it: PlayItem, _ s: Session) -> PlayItem {
        var out = it
        out.offersReply = true
        out.stamp = s.modified
        return out
    }

    // MARK: commands from Claude Code (hook/voicectl)

    func run(_ c: VoiceCommand) {
        let d = UserDefaults.standard
        if !["reply", "talkback"].contains(c.action) { replies.abort() }      // any other command wins
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
        case "talkback":
            d.set(c.arg == "on", forKey: "talkBack")
            syncTalkbackFlag()
        case "reply":
            if c.arg == "cancel" { replies.abort(say: "Cancelled.") } else { startReply(project: nil, sid: c.sid) }
        default: break
        }
        writeStatus()
    }

    /// "/voice play": the session's latest reply (or the newest unheard one), or its summary.
    private func playCommand(sid: String?, summary: Bool) {
        let target = store.sessions.first { $0.id == sid && !$0.hidden }
            ?? store.visible.first(where: \.isNew) ?? store.visible.first
        guard let s = target else { return }
        guard summary else { play(s, offerReply: true); return }
        let mode: ReadMode? = summarizer.cached(s, .session) != nil ? .session
            : summarizer.cached(s, .quick) != nil ? .quick : nil
        if let mode {
            play(s, mode: mode, offerReply: true)
        } else {
            request += 1
            speaker.play([PlayItem(sid: "_note", lines: ["There is no summary for this reply yet."])])
        }
    }

    // MARK: spoken commands (VoiceListener -> VoiceIntent)

    /// Run what the user said into the headset. Transport commands share `run(_:)` with `/voice`.
    func runVoice(_ intent: VoiceIntent) {
        switch intent {
        case .pause: run(VoiceCommand(action: "pause"))
        case .resume: run(VoiceCommand(action: "resume"))
        case .stop: run(VoiceCommand(action: "stop"))
        case .restart: run(VoiceCommand(action: "restart"))
        case .next: run(VoiceCommand(action: "next"))
        case .previous: run(VoiceCommand(action: "prev"))
        case .back(let n): run(VoiceCommand(action: "back", arg: String(n)))
        case .forward(let n): run(VoiceCommand(action: "fwd", arg: String(n)))
        case .progress(let on):
            run(VoiceCommand(action: "progress", arg: on ? "on" : "off"))
            speakNote(on ? "Progress updates on." + readAloudSuffix() : "Progress updates off.")
        case .play(let summary, let project): playLast(summary: summary, project: project)
        case .status: speakStatus()
        case .listSessions: speakSessions()
        case .reply(let project): startReply(project: project, sid: nil)
        }
    }

    /// Progress is only read for sessions that are read aloud. Said "progress on" away from the keyboard:
    /// make sure the session being followed is one of them.
    private func readAloudSuffix() -> String {
        guard let s = store.sessions.first(where: { $0.id == lastSid }) ?? store.visible.first,
              !store.isHidden(s.id), !shouldAutoRead(s.id) else { return "" }
        let d = UserDefaults.standard
        d.set(AutoRead.toggled(d.string(forKey: "autoSids") ?? "", s.id), forKey: "autoSids")
        return " Reading \(s.displayProject.replacingOccurrences(of: "-", with: " ")) out loud."
    }

    /// "Play last response [summarized] [from <project>]": the newest reply of all sessions, or of the
    /// session named. A summary comes from the cache; when there is none, Haiku makes one, but only
    /// because the user asked for it out loud AND turned on "voiceSummary". Never from auto-read.
    private func playLast(summary: Bool, project: String?) {
        let target: Session?
        if let project {
            target = resolveSession(named: project)
            if target == nil { speakNote("No session called \(project)."); return }
        } else {
            target = store.visible.first
        }
        guard let s = target else { speakNote("No replies yet."); return }

        guard summary, s.words >= Self.summaryMinWords else {
            play(s, offerReply: true)
            return
        }
        if summarizer.cached(s, .session) != nil {
            play(s, mode: .session, offerReply: true)
        } else if summarizer.cached(s, .quick) != nil {
            play(s, mode: .quick, offerReply: true)
        } else if UserDefaults.standard.bool(forKey: "voiceSummary") {
            speakNote("Summarizing.")       // bumps `request`; a newer command makes `r` stale
            let r = request
            Task {
                let text = await summarizer.summary(for: s, .quick)
                guard r == request else { return }       // the user asked for something else meanwhile
                guard let text else { speakNote("I could not make a summary."); return }
                speaker.play([offering(summaryItem(s, text, .quick), s)])
            }
        } else {
            speakNote("There is no summary yet. Turn on summaries by voice in settings.")
        }
    }

    /// The visible session whose project or title best matches what was said ("claude voice", "api").
    /// Ties go to the newest reply. Words are compared as the grammar writes them (`VoiceGrammar.normalize`).
    func resolveSession(named name: String) -> Session? {
        let want = Set(VoiceGrammar.normalize(name))
        guard !want.isEmpty else { return nil }
        var best: (score: Int, session: Session)?
        for s in store.visible {    // newest first, so a tie keeps the newer session
            let have = Set(VoiceGrammar.normalize(s.project))
            let inTitle = Set(VoiceGrammar.normalize(s.title))
            let score = want.intersection(have).count * 2 + want.intersection(inTitle).count
            guard score > 0, want.isSubset(of: have.union(inTitle)) else { continue }
            if best == nil || score > best!.score { best = (score, s) }
        }
        return best?.session
    }

    /// The saved progress updates of the newest session, read once.
    private func speakStatus() {
        guard let s = store.visible.first else { speakNote("No sessions yet."); return }
        let notes = store.progress[s.id] ?? []
        guard !notes.isEmpty else {
            speakNote("No progress updates. Say progress on, and I will record them.")
            return
        }
        request += 1
        var lines: [String] = []
        for n in notes.suffix(3) { lines += Sentences.split(n.text) }
        speaker.play([PlayItem(sid: s.id, lines: lines, voiceID: Voices.replyVoiceID(for: notes.last?.text ?? ""),
                               isProgress: true)])
    }

    private func speakSessions() {
        let names = store.visible.map { $0.displayProject.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ") }
        guard !names.isEmpty else { speakNote("No sessions yet."); return }
        let list = names.prefix(6).joined(separator: ", ")
        speakNote("\(names.count) session\(names.count == 1 ? "" : "s"): \(list).")
    }

    /// A short spoken answer that is not a reply (confirmations, errors).
    func speakNote(_ text: String) {
        request += 1
        speaker.play([PlayItem(sid: "_note", lines: [text])])
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
        var it = offering(summaryItem(s, text, .session), s)
        if lastSid != s.id { it = withHeader(it, s) }
        replies.abort()
        speaker.play([it])
    }

    // MARK: talk back

    static var talkBackOn: Bool { UserDefaults.standard.bool(forKey: "talkBack") }

    /// A reply or summary was read to the end (or an answer sentence was spoken).
    private func playbackFinished(_ item: PlayItem) {
        if item.sid == "_reply" { replies.sayFinished(); return }
        guard Self.talkBackOn, UserDefaults.standard.object(forKey: "talkbackAuto") as? Bool ?? true,
              item.offersReply, !item.isProgress, !item.sid.hasPrefix("_"),
              let s = store.sessions.first(where: { $0.id == item.sid }), s.modified == item.stamp,
              !replies.isBusy, replies.micReady, replies.waiterAlive(s.id) else { return }
        openReplyWindow(for: s)
    }

    private func openReplyWindow(for s: Session) {
        var cfg = replies.config
        let window = UserDefaults.standard.double(forKey: "replyWindow")
        cfg.window = window >= 5 ? window : 30
        replies.config = cfg
        replies.open(sid: s.id, project: s.displayProject.replacingOccurrences(of: "-", with: " ")
                        .replacingOccurrences(of: "_", with: " "),
                     announce: false)       // no "To <project>." in the read-back, whatever the session count
    }

    /// "Hey Claude, reply [to <project>]" or `/voice reply`: open the window now.
    private func startReply(project: String?, sid: String?) {
        guard Self.talkBackOn else { speakNote("Answering by voice is off. Turn it on in settings."); return }
        let target: Session?
        if let project {
            target = resolveSession(named: project)
            if target == nil { speakNote("No session called \(project)."); return }
        } else if let sid, let s = store.sessions.first(where: { $0.id == sid }) {
            target = s
        } else {
            let live = Set(Waiters.all())
            target = store.sessions.first(where: { $0.id == lastSid && live.contains($0.id) })
                ?? store.visible.first(where: { live.contains($0.id) })
        }
        guard let s = target, replies.waiterAlive(s.id) else {
            speakNote("This session isn't listening for replies.")
            return
        }
        guard replies.micReady else { speakNote("I cannot hear you. Turn on voice commands in settings."); return }
        replies.abort()
        openReplyWindow(for: s)
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

    /// While "Answer Claude by voice" is on, this file exists and is touched every few seconds: the Stop
    /// hook `talk wait` arms only then, so an app that is closed (or crashed) never promises an answer
    /// it cannot deliver. The Mac also stays awake while a session is waiting.
    func syncTalkbackFlag() {
        let fm = FileManager.default
        let on = Self.talkBackOn
        let path = Paths.talkbackFlag.path
        if on {
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            } else {
                try? fm.createDirectory(at: Paths.base, withIntermediateDirectories: true)
                fm.createFile(atPath: path, contents: Data())
            }
        } else if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }
        let needAwake = on && !Waiters.all().isEmpty
        if needAwake, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "A Claude Code session is waiting for a spoken answer")
        } else if !needAwake, let a = awakeActivity {
            ProcessInfo.processInfo.endActivity(a)
            awakeActivity = nil
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
            "talkBack": Self.talkBackOn, "autoSummarize": d.bool(forKey: "autoSummarize"),
            "listening": Waiters.all().sorted(), "answering": replies.isBusy,
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
