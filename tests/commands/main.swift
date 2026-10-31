// Commands test: swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Commands}.swift tests/commands/main.swift -o build/cmdtest && build/cmdtest
// Command parsing, the command inbox (fresh / stale / ordering), Speaker pause/resume/prev, and
// dropping stale progress. Plays a fraction of a second of speech.
import AVFoundation
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + name)
    if !ok { failed = true }
}
func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

print("parsing")
check("plain", VoiceCommand(line: "pause") == VoiceCommand(action: "pause"))
check("arg + sid", VoiceCommand(line: "back 3 --sid abc") == VoiceCommand(action: "back", arg: "3", sid: "abc"))
check("play summary", VoiceCommand(line: "play summary --sid s1") == VoiceCommand(action: "play", arg: "summary", sid: "s1"))
check("summary import", VoiceCommand(line: "summary s1\n")?.arg == "s1")
check("empty is nil", VoiceCommand(line: "  \n") == nil)
check("count default", VoiceCommand(action: "back").count == 1)
check("count clamps", VoiceCommand(action: "fwd", arg: "99999").count == 999)

print("inbox")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cv-cmd-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
func drop(_ name: String, _ line: String, age: TimeInterval = 0) {
    let f = dir.appendingPathComponent(name)
    try? line.write(to: f, atomically: true, encoding: .utf8)
    if age > 0 { try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: f.path) }
}
drop("0001.cmd", "stop", age: 600)          // from before the app started: ignored
drop("0002.cmd", "back 2")
drop("0003.cmd", "fwd 5 --sid x")
drop(".tmp.99", "pause")                     // half-written file: ignored
var got: [VoiceCommand] = []
MainActor.assumeIsolated {
    let inbox = CommandInbox(dir: dir) { got.append($0) }
    wait(0.3)
    check("stale command dropped", !got.contains { $0.action == "stop" })
    check("fresh commands in order", got == [VoiceCommand(action: "back", arg: "2"), VoiceCommand(action: "fwd", arg: "5", sid: "x")])
    check("files removed", ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".cmd") }.isEmpty)
    got = []
    drop("0004.cmd", "next")
    wait(0.5)
    check("picked up while running", got == [VoiceCommand(action: "next")])
    _ = inbox
}

print("speaker")
let sp = Speaker()
func lineIDsAreSequential() -> Bool { sp.lines.enumerated().allSatisfy { $0.offset == $0.element.id } }
sp.play([
    PlayItem(sid: "A", lines: ["Alpha one.", "Alpha two."]),
    PlayItem(sid: "A", lines: ["Doing a."], isProgress: true),
    PlayItem(sid: "A", lines: ["Doing b."], isProgress: true),
    PlayItem(sid: "B", lines: ["Beta progress."], isProgress: true),
    PlayItem(sid: "C", lines: ["Gamma one."]),
])
sp.pause()
check("pause", sp.state == .paused)
sp.pause()
check("pause is idempotent", sp.state == .paused)
sp.resume()
check("resume", sp.state == .playing)
sp.resume()
check("resume is idempotent", sp.state == .playing)
sp.stop()

sp.dropQueuedProgress(sid: "A")
check("drops that session's queued progress", sp.items.map(\.sid) == ["A", "B", "C"])
check("other session's progress kept", sp.items[1].isProgress && sp.items[1].sid == "B")
check("line count rebuilt", sp.lines.count == 2 + 1 + 1)
check("line ids sequential", lineIDsAreSequential())
check("item/local consistent", sp.lines.allSatisfy { sp.items[$0.item].lines[$0.local] == $0.text })

sp.play([
    PlayItem(sid: "A", lines: ["One."]),
    PlayItem(sid: "A", lines: ["Doing a."], isProgress: true),
    PlayItem(sid: "A", lines: ["Doing b."], isProgress: true),
    PlayItem(sid: "A", lines: ["Final."]),
], from: 1)                                   // playing the first progress note
sp.stop()
sp.dropQueuedProgress(sid: "A")
check("playing note is kept, later ones dropped", sp.items.count == 3 && sp.items[1].lines == ["Doing a."])
check("index still on the playing note", sp.lines[sp.index].text == "Doing a.")

sp.play([PlayItem(sid: "A", lines: ["First."]), PlayItem(sid: "B", lines: ["Second."]), PlayItem(sid: "C", lines: ["Third."])], from: 2)
sp.prev()
check("prev = previous reply", sp.lines[sp.index].text == "Second.")
sp.prev(); sp.prev()
check("prev at the first reply stays", sp.lines[sp.index].text == "First.")
sp.stop()

print(failed ? "\nFAILURES" : "\nall passed")
exit(failed ? 1 : 0)
