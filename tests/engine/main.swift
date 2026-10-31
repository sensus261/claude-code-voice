// Engine test: swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store}.swift tests/engine/main.swift
import AVFoundation
import Foundation

UserDefaults.standard.register(defaults: ["rate": 0.62])   // in-memory only

func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func show(_ sp: Speaker, _ label: String) {
    print("\(label): state=\(sp.state) index=\(sp.index)/\(sp.lines.count) word=\(sp.word.map { "\($0.location)" } ?? "-")")
}

print("voices: \(Voices.apple.count), preferred: \(Voices.preferred.map(Voices.label) ?? "nil") [\(Voices.preferred?.language ?? "")]")
print("split: \(Sentences.split("Fix done. Run tests next.\nSee auth.ts e.g. here. 3 files changed!"))")

let sp = Speaker()
var started: [String] = []
sp.onItemStart = { started.append($0) }
var words = 0
let watcher = sp.$word.sink { if $0 != nil { words += 1 } }

sp.play([
    PlayItem(sid: "A", lines: ["Alpha one is here.", "Alpha two is here.", "Alpha three is here.", "Alpha four is here."]),
    PlayItem(sid: "B", lines: ["Beta one.", "Beta two."]),
])
wait(2.5); show(sp, "after 2.5s (index should be > 0)")
sp.togglePause(); let p = sp.index; wait(1.2); show(sp, "paused"); print("  paused index held: \(p == sp.index)")
sp.togglePause(); wait(0.6); show(sp, "resumed")
sp.back(2); wait(0.3); show(sp, "back 2")
sp.skip(); wait(0.3); show(sp, "skip (expect index 4)")
sp.enqueue(PlayItem(sid: "C", lines: ["Gamma queued."])); show(sp, "enqueued C (expect 7 lines, still playing)")
sp.restart(); wait(0.3); show(sp, "restart (expect 4)")
wait(6); show(sp, "end (expect idle 7/7)")
print("items started: \(started)  word callbacks: \(words)")
watcher.cancel()
