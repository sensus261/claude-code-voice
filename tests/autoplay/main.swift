// Autoplay test: no Claude call is ever made by auto-read, progress reading or "play summary".
// Hermetic: its own state folder and a stub `claude` that records whether it was started.
//   swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Commands,Model,VoiceIntent}.swift tests/autoplay/main.swift -o build/autotest
//   build/autotest        (plays about a second of speech)
import Foundation

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cv-auto-\(UUID().uuidString)")
let marker = tmp.appendingPathComponent("claude-was-started")
let stub = tmp.appendingPathComponent("claude-stub")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
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
func write(_ url: URL, _ text: String) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
var claudeStarted: Bool { FileManager.default.fileExists(atPath: marker.path) }

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
    check("voice: says whose reply it is with several sessions", model.speaker.items.first?.headerLines == 1)
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

    UserDefaults.standard.removeObject(forKey: "voiceSummary")
    UserDefaults.standard.removeObject(forKey: "autoAll")
    UserDefaults.standard.removeObject(forKey: "readProgress")
    try? FileManager.default.removeItem(at: tmp)
    print(failed ? "\nFAILURES" : "\nall passed")
    exit(failed ? 1 : 0)
}
dispatchMain()
