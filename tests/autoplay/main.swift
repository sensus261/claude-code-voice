// Autoplay test: no Claude call is ever made by auto-read, progress reading or "play summary" (auto-read
// calls Claude only for long replies, and only when "autoSummarize" is on), and the talk-back wiring:
// a finished reply opens the answer window, an answer is read back and delivered after "send".
// Hermetic: its own state folder and a stub `claude` that records whether (and how often) it was started.
//   swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Commands,Model,VoiceIntent,ReplyFlow,ReplyCoordinator,VoiceListener}.swift tests/autoplay/main.swift -o build/autotest
//   build/autotest        (plays about a second of speech)
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)      // line by line, also when piped

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cv-auto-\(UUID().uuidString)")
let marker = tmp.appendingPathComponent("claude-was-started")
let stub = tmp.appendingPathComponent("claude-stub")
let counter = tmp.appendingPathComponent("claude-runs")       // one line per start
let okMode = tmp.appendingPathComponent("stub-ok")            // exists: the stub prints a summary and succeeds
let slowMode = tmp.appendingPathComponent("stub-slow")        // exists: ... after 3 seconds
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
try """
    #!/bin/sh
    touch '\(marker.path)'
    echo run >> '\(counter.path)'
    [ -f '\(slowMode.path)' ] && sleep 3
    if [ -f '\(okMode.path)' ]; then echo "I fixed the migration and every table was copied."; exit 0; fi
    exit 1

    """.write(to: stub, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

// Must be set before Paths / ClaudeCLI are first used.
setenv("CLAUDE_VOICE_STATE", tmp.appendingPathComponent("state").path, 1)
setenv("CLAUDE_VOICE_CLAUDE", stub.path, 1)
UserDefaults.standard.set(true, forKey: "autoAll")
UserDefaults.standard.set(true, forKey: "readProgress")

var failed = false
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + name)
    if !ok { failed = true }
}
func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
// Spinning the run loop does not let main-actor Tasks run (we are inside one); awaiting does.
func nap(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
// Waits while main-actor tasks and dispatch blocks (speech finished, summaries) run. Run-loop timers do not
// fire in this harness once a task has awaited, so the two polls the app drives with timers are driven by
// hand: the store's folder scan and the answer flow's tick.
func pump(_ s: Double) async {
    let end = Date().addingTimeInterval(s)
    var n = 0
    while Date() < end {
        await nap(0.05)
        n += 1
        if n % 3 == 0 {
            await MainActor.run {
                AppModel.shared.store.scan()
                AppModel.shared.replies.tick()
            }
        }
    }
}
func write(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
var claudeStarted: Bool { FileManager.default.fileExists(atPath: marker.path) }
var claudeRuns: Int { ((try? String(contentsOf: counter, encoding: .utf8)) ?? "").split(separator: "\n").count }

@MainActor final class FakeMic: ReplyMic {
    var isReady = true
    var heardSound = true
    var kinds: [ReplyCaptureKind] = []
    var onText: ((String) -> Void)?
    func beginCapture(_ kind: ReplyCaptureKind, onText: @escaping (String) -> Void) { kinds.append(kind); self.onText = onText }
    func endCapture() { onText = nil }
}

Task { @MainActor in
    let model = AppModel.shared
    let sid = "_auto1"
    check("stub is the claude binary", ClaudeCLI.path == stub.path)
    check("progress flag created by the app", FileManager.default.fileExists(atPath: Paths.progressFlag.path))

    // a session with a reply already on disk at launch (must not be auto-read)
    write(Paths.replies.appendingPathComponent("\(sid).json"), #"{"sid":"_auto1","project":"demo","title":"Fix parser"}"#)

    // progress note arrives -> read
    write(Paths.progress.appendingPathComponent("\(sid)/0000000000001-00.txt"), "Looking at the parser now.\n")
    wait(2)
    check("progress note queued", model.speaker.items.contains { $0.sid == sid && $0.isProgress })
    check("header on the first item", model.speaker.items.first?.headerLines == 1)

    // a second note, then the final reply in the same moment: stale note dropped, reply queued
    write(Paths.progress.appendingPathComponent("\(sid)/0000000000002-00.txt"), "Now fixing the bug.\n")
    write(Paths.replies.appendingPathComponent("\(sid).md"), "All done, the bug is fixed and the tests pass.\n")
    write(Paths.replies.appendingPathComponent("\(sid).txt"), "All done, the bug is fixed and the tests pass.\n")
    wait(2)
    let kinds = model.speaker.items.map { $0.isProgress ? "progress" : "reply" }
    check("final reply queued after the playing note", kinds == ["progress", "reply"])
    check("no second header for the same session", model.speaker.items.last?.headerLines == 0)
    check("recorded notes are kept for the UI", model.store.progress[sid]?.count == 2)

    // explicit commands
    model.run(VoiceCommand(action: "play", arg: "summary", sid: sid))
    check("play summary with none stored: only a spoken note", model.speaker.items.first?.sid == "_note")

    write(Paths.inbox.appendingPathComponent("summary-\(sid).txt"), "I fixed the parser bug and the tests pass.\n")
    model.run(VoiceCommand(action: "summary", arg: sid))
    let session = model.store.sessions.first { $0.id == sid }
    check("imported summary stored", session.flatMap { model.summarizer.cached($0, .session) } == "I fixed the parser bug and the tests pass.")
    check("imported summary plays", model.speaker.items.first?.mode == .session)
    model.run(VoiceCommand(action: "pause"))
    check("pause command", model.speaker.state == .paused)
    model.run(VoiceCommand(action: "stop"))

    if let s = session {
        try? FileManager.default.removeItem(at: Summarizer.dir.appendingPathComponent("\(sid).session.json"))
        model.ensureSummary(s, .session) { _ in }
        check("session summary request only shows a hint", model.ask?.canRun == false)
        model.ask = nil
    }
    model.run(VoiceCommand(action: "stop"))

    // MARK: spoken commands (VoiceIntent -> AppModel.runVoice), "voiceSummary" still off

    UserDefaults.standard.set(false, forKey: "autoAll")
    UserDefaults.standard.removeObject(forKey: "voiceSummary")
    let sid2 = "_auto2"
    let long = Array(repeating: "The migration finished and every table was copied without a single error.", count: 8)
        .joined(separator: " ")
    wait(1.2)    // the second reply must be newer than the first
    write(Paths.replies.appendingPathComponent("\(sid2).json"), #"{"sid":"_auto2","project":"api-server","title":"Migrate"}"#)
    write(Paths.replies.appendingPathComponent("\(sid2).md"), long)
    write(Paths.replies.appendingPathComponent("\(sid2).txt"), long)
    wait(2)
    let session2 = model.store.sessions.first { $0.id == sid2 }
    check("second session listed, newest first", model.store.visible.first?.id == sid2)

    model.runVoice(.play(summary: false, project: nil))
    check("voice: last response is the newest session's", model.speaker.items.first?.sid == sid2)
    check("voice: no spoken \"From <project>\" header, even with several sessions", model.speaker.items.first?.headerLines == 0)
    model.runVoice(.play(summary: false, project: "demo"))
    check("voice: 'from demo' plays the older session", model.speaker.items.first?.sid == sid)
    model.runVoice(.play(summary: false, project: "api"))
    check("voice: partial project name matches", model.speaker.items.first?.sid == sid2)
    model.runVoice(.play(summary: false, project: "api server"))
    check("voice: full project name matches", model.speaker.items.first?.sid == sid2)
    model.runVoice(.play(summary: false, project: "nothing like it"))
    check("voice: unknown project is a spoken note", model.speaker.items.first?.sid == "_note"
          && model.speaker.items.first?.lines.first?.hasPrefix("No session called") == true)

    model.runVoice(.pause)
    check("voice: pause", model.speaker.state == .paused || model.speaker.state == .idle)
    model.runVoice(.play(summary: false, project: nil))
    model.runVoice(.pause)
    check("voice: pause while playing", model.speaker.state == .paused)
    model.runVoice(.resume)
    check("voice: resume", model.speaker.state == .playing)
    model.runVoice(.stop)
    check("voice: stop", model.speaker.state == .idle)

    model.runVoice(.play(summary: true, project: nil))
    check("voice: summary with none stored and the toggle off is only a note",
          model.speaker.items.first?.sid == "_note" && model.speaker.items.first?.lines.first?.contains("settings") == true)
    model.runVoice(.play(summary: true, project: "demo"))
    wait(0.3)
    check("voice: a short reply is read in full instead of summarized", model.speaker.items.first?.mode == .full
          && model.speaker.items.first?.sid == sid)
    check("voice: Claude not started with the toggle off", !claudeStarted)

    if let s2 = session2 {
        model.summarizer.storeImported("The migration is done.", for: s2)
        model.runVoice(.play(summary: true, project: nil))
        await nap(0.4)
        check("voice: cached session summary plays", model.speaker.items.first?.mode == .session)
        check("voice: cached summary needs no Claude", !claudeStarted)
    }

    model.runVoice(.listSessions)
    check("voice: lists the sessions", model.speaker.items.first?.lines.first?.hasPrefix("2 sessions") == true)
    model.runVoice(.status)    // newest session (api-server) has no notes
    check("voice: status without notes says so", model.speaker.items.first?.lines.first?.hasPrefix("No progress") == true)
    model.runVoice(.progress(on: false))
    check("voice: progress off removes the hook flag", !FileManager.default.fileExists(atPath: Paths.progressFlag.path))
    model.runVoice(.progress(on: true))
    check("voice: progress on creates it", FileManager.default.fileExists(atPath: Paths.progressFlag.path))
    model.runVoice(.stop)
    wait(0.5)

    check("Claude was never started by any of the above", !claudeStarted)
    check("nothing is summarizing", model.summarizer.working.isEmpty)

    // positive control: the explicit Haiku summary does start it, so the check above means something
    if let s = session {
        _ = await model.summarizer.summary(for: s, .quick)
        check("control: an explicit quick summary does start Claude", claudeStarted)
    }

    // With "voiceSummary" on, saying "summarized" is the explicit request: it starts Claude once
    // (the stub fails, so the user hears that no summary could be made).
    try? FileManager.default.removeItem(at: marker)
    try? FileManager.default.removeItem(at: Summarizer.dir.appendingPathComponent("\(sid2).session.json"))
    check("marker cleared before the voice summary", !claudeStarted)
    UserDefaults.standard.set(true, forKey: "voiceSummary")
    model.runVoice(.play(summary: true, project: nil))
    check("voice: says it is summarizing", model.speaker.items.first?.lines.first == "Summarizing.")
    await nap(2)
    check("voice: 'summarized' with the toggle on starts Claude", claudeStarted)
    check("voice: a failed summary is reported", model.speaker.items.first?.lines.first == "I could not make a summary.")


    // MARK: auto-summarize (the one automatic Claude call, off by default)

    UserDefaults.standard.set("en-US", forKey: "summaryLang")
    UserDefaults.standard.set(true, forKey: "autoAll")
    UserDefaults.standard.set(false, forKey: "readProgress")
    UserDefaults.standard.set(false, forKey: "voiceSummary")
    AppModel.autoSummaryPatience = 1.5
    let longText = Array(repeating: "The migration finished and every table was copied without a single error.", count: 10).joined(separator: " ")
    let shortText = "The build is green and all tests pass."
    func reply(_ sid: String, _ project: String, _ text: String) {
        write(Paths.replies.appendingPathComponent("\(sid).json"), #"{"sid":"\#(sid)","project":"\#(project)","title":"T"}"#)
        write(Paths.replies.appendingPathComponent("\(sid).md"), text)
        write(Paths.replies.appendingPathComponent("\(sid).txt"), text)
    }
    @MainActor func resetRuns() {
        try? FileManager.default.removeItem(at: marker)
        try? FileManager.default.removeItem(at: counter)
        model.speaker.play([])
    }
    @MainActor func lastItem(_ sid: String) -> PlayItem? { model.speaker.items.last { $0.sid == sid } }

    resetRuns()
    await pump(1.2)
    reply("_sumA", "alpha", longText)
    await pump(2.2)
    check("autoSummarize off: a long reply is read in full", lastItem("_sumA")?.mode == .full)
    check("autoSummarize off: Claude not started", !claudeStarted)

    UserDefaults.standard.set(true, forKey: "autoSummarize")
    resetRuns()
    await pump(1.2)
    reply("_sumB", "beta", shortText)
    await pump(2.2)
    check("autoSummarize on: a short reply is read in full", lastItem("_sumB")?.mode == .full)
    check("autoSummarize on: ...without starting Claude", !claudeStarted)

    FileManager.default.createFile(atPath: okMode.path, contents: Data())
    resetRuns()
    await pump(1.2)
    reply("_sumC", "gamma", longText)
    await pump(2.2)
    await pump(1)
    check("autoSummarize on: a long reply starts Claude exactly once", claudeRuns == 1)
    check("autoSummarize on: ...and reads the summary", lastItem("_sumC")?.mode == .quick
          && lastItem("_sumC")?.lines.joined(separator: " ").contains("migration") == true)
    check("autoSummarize on: ...which can be answered by voice", lastItem("_sumC")?.offersReply == true)

    try? FileManager.default.removeItem(at: okMode)
    resetRuns()
    await pump(1.2)
    reply("_sumD", "delta", longText)
    await pump(2.2)
    await pump(1)
    check("autoSummarize on: a failing Claude falls back to the full reply", lastItem("_sumD")?.mode == .full && claudeRuns >= 1)

    FileManager.default.createFile(atPath: okMode.path, contents: Data())
    FileManager.default.createFile(atPath: slowMode.path, contents: Data())
    resetRuns()
    await pump(1.2)
    reply("_sumE", "epsilon", longText)
    await pump(2.2)
    await pump(1)
    check("autoSummarize on: too slow, the full reply is read instead", lastItem("_sumE")?.mode == .full)
    await pump(3.5)
    check("autoSummarize on: ...and the late summary is not read afterwards",
          model.speaker.items.filter { $0.sid == "_sumE" }.count == 1)
    try? FileManager.default.removeItem(at: slowMode)
    try? FileManager.default.removeItem(at: okMode)

    // MARK: talk back (fake microphone; real timers and speech)

    UserDefaults.standard.set(false, forKey: "autoSummarize")
    let mic = FakeMic()
    model.useReplyMic(mic)
    UserDefaults.standard.set(true, forKey: "talkBack")
    model.syncTalkbackFlag()
    check("talk back on: the hook's flag file exists", FileManager.default.fileExists(atPath: Paths.talkbackFlag.path))

    func arm(_ sid: String) {
        let json = #"{"sid":"\#(sid)","token":"1.2","pid":\#(getpid()),"claude":\#(getpid()),"started":1}"#
        write(Paths.waiting.appendingPathComponent("\(sid).json"), json)
    }
    func disarm(_ sid: String) { try? FileManager.default.removeItem(at: Paths.waiting.appendingPathComponent("\(sid).json")) }
    let inFile = Paths.replyIn.appendingPathComponent("talk1.txt")

    // not armed -> no window
    resetRuns()
    await pump(1.2)
    reply("talk1", "web app", shortText)
    await pump(8)
    check("reply read, session not waiting: no window", mic.kinds.isEmpty)

    // armed -> window after the reply is read to the end
    arm("talk1")
    await pump(1.2)
    reply("talk1", "web app", "The build is green. Should I deploy it?")
    var tries = 0
    while mic.kinds.isEmpty, tries < 40 { await pump(0.5); tries += 1 }
    check("reply read to the end, session waiting: the answer window opens", mic.kinds == [.dictation])
    check("...for that session", model.replies.activeSid == "talk1")

    // a reply of another session during the window waits its turn
    await pump(1.2)
    reply("other1", "other thing", "Another session finished meanwhile.")
    await pump(2.2)
    check("another session's reply is held while an answer is taken", !model.speaker.items.contains { $0.sid == "other1" })

    mic.onText?("yes ship it")
    tries = 0
    while model.speaker.items.first?.sid != "_reply", tries < 40 { await pump(0.25); tries += 1 }
    check("the answer is read back", model.speaker.items.first?.lines.first == "Sending: yes ship it. Say send, or cancel.")
    tries = 0
    while mic.kinds.count < 2, tries < 40 { await pump(0.5); tries += 1 }
    check("after the read-back it listens for send", mic.kinds == [.dictation, .confirm])
    check("nothing delivered yet", !FileManager.default.fileExists(atPath: inFile.path))
    mic.onText?("send")
    check("send: the answer is handed to the session", (try? String(contentsOf: inFile, encoding: .utf8)) == "yes ship it")
    try? FileManager.default.removeItem(at: inFile)        // what `talk wait` does when it takes it
    tries = 0
    while !model.speaker.items.contains(where: { $0.sid == "other1" }), tries < 40 { await pump(0.5); tries += 1 }
    check("then the held reply is read", model.speaker.items.contains { $0.sid == "other1" })
    check("and Claude was never started by any of this", !claudeStarted)

    // "Hey Claude, reply"
    model.speaker.play([])
    mic.kinds = []
    model.runVoice(.reply(project: nil))
    check("voice 'reply' opens the window for the waiting session", mic.kinds == [.dictation] && model.replies.activeSid == "talk1")
    model.runVoice(.stop)
    check("any other command ends it", !model.replies.isBusy)
    disarm("talk1")
    mic.kinds = []
    model.runVoice(.reply(project: nil))
    check("voice 'reply' with nobody waiting says so", mic.kinds.isEmpty
          && model.speaker.items.first?.lines.first?.contains("isn't listening") == true)
    UserDefaults.standard.set(false, forKey: "talkBack")
    model.syncTalkbackFlag()
    check("talk back off: the flag file is removed", !FileManager.default.fileExists(atPath: Paths.talkbackFlag.path))
    model.runVoice(.reply(project: nil))
    check("voice 'reply' with talk back off says so", model.speaker.items.first?.lines.first?.contains("off") == true)

    // "progress on" also makes sure the session is read aloud
    UserDefaults.standard.set(false, forKey: "autoAll")
    UserDefaults.standard.removeObject(forKey: "autoSids")
    model.runVoice(.progress(on: true))
    check("progress on by voice: the session being followed is auto-read",
          (UserDefaults.standard.string(forKey: "autoSids") ?? "").isEmpty == false
          && model.speaker.items.first?.lines.first?.contains("out loud") == true)
    model.runVoice(.stop)

    UserDefaults.standard.removeObject(forKey: "summaryLang")
    UserDefaults.standard.removeObject(forKey: "talkBack")
    UserDefaults.standard.removeObject(forKey: "autoSids")
    UserDefaults.standard.removeObject(forKey: "autoSummarize")

    UserDefaults.standard.removeObject(forKey: "voiceSummary")
    UserDefaults.standard.removeObject(forKey: "autoAll")
    UserDefaults.standard.removeObject(forKey: "readProgress")
    try? FileManager.default.removeItem(at: tmp)
    print(failed ? "\nFAILURES" : "\nall passed")
    exit(failed ? 1 : 0)
}
dispatchMain()
