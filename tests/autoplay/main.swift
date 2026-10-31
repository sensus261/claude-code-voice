// Autoplay test: no Claude call is ever made by auto-read, progress reading or "play summary".
// Hermetic: its own state folder and a stub `claude` that records whether it was started.
//   swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Commands,Model}.swift tests/autoplay/main.swift -o build/autotest
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
    wait(0.5)

    check("Claude was never started by any of the above", !claudeStarted)
    check("nothing is summarizing", model.summarizer.working.isEmpty)

    // positive control: the explicit Haiku summary does start it, so the check above means something
    if let s = session {
        _ = await model.summarizer.summary(for: s, .quick)
        check("control: an explicit quick summary does start Claude", claudeStarted)
    }

    UserDefaults.standard.removeObject(forKey: "autoAll")
    UserDefaults.standard.removeObject(forKey: "readProgress")
    try? FileManager.default.removeItem(at: tmp)
    print(failed ? "\nFAILURES" : "\nall passed")
    exit(failed ? 1 : 0)
}
dispatchMain()
