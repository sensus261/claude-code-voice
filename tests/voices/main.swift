// Voices test: Piper and Microsoft voices, language detection, fallbacks (plays ~25 s of audio).
// swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store}.swift tests/voices/main.swift -o build/voicetest
import AVFoundation
import Foundation

UserDefaults.standard.register(defaults: ["rate": 0.55])   // in-memory only

func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func waitFor(_ timeout: Double, _ ok: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !ok() && Date() < end { wait(0.05) }
    return ok()
}
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

let catalog = VoiceCatalog.shared
catalog.refresh()
_ = waitFor(20) { !catalog.scanning && (catalog.python[.edge] == nil || !catalog.edge.isEmpty) }
print("python: piper=\(catalog.python[.piper] ?? "-") edge=\(catalog.python[.edge] ?? "-")")
print("piper voices: \(catalog.piper.map(\.label)), edge voices: \(catalog.edge.count)")
print("Romanian: \(Voices.options(language: "ro").map { "\($0.label) [\($0.id)]" })")
print("automatic ro: \(Voices.automatic("ro")?.label ?? "none")")

check(Voices.detectLanguage("Am terminat modificările. Testele trec acum, iar aplicația pornește fără erori.") == "ro", "detects Romanian")
check(Voices.detectLanguage("I finished the changes. The tests pass now and the app starts without errors.") == "en", "detects English")
check(Voices.detectLanguage("Done.") == nil, "short text: no guess")
check(Voices.language(of: "edge:ro-RO-AlinaNeural") == "ro-RO", "edge voice language")
check(Voices.language(of: "piper:ro_RO-mihai-medium") == "ro-RO", "piper voice language")
if case .apple = Voices.resolve("piper:does-not-exist") { check(true, "missing Piper model falls back to Apple") }
else { check(false, "missing Piper model falls back to Apple") }

let sp = Speaker()
var words = 0
let watcher = sp.$word.sink { if $0 != nil { words += 1 } }
let ro = ["Bună! Aceasta este prima propoziție.", "Urmează a doua, puțin mai lungă decât prima.", "Și gata, a treia."]

for id in ["piper:ro_RO-mihai-medium", "edge:ro-RO-AlinaNeural"] {
    guard case .external(let v) = Voices.resolve(id) else {
        print("skip \(id): engine not installed")
        continue
    }
    print("-- \(v.engine.title)")
    words = 0
    sp.engineError = nil
    let t0 = Date()
    sp.play([PlayItem(sid: "T", lines: ["From the test."] + ro, voiceID: id, headerLines: 1)])
    // The header is spoken by the Apple main voice; then the external voice takes over.
    _ = waitFor(10) { sp.index >= 1 }
    let firstWords = words
    check(waitFor(15) { words > firstWords }, "\(v.engine.title) audio started \(String(format: "%.1f", Date().timeIntervalSince(t0)))s after play")
    sp.togglePause(); let held = sp.index; wait(0.8)
    check(sp.state == .paused && sp.index == held, "pause holds")
    sp.togglePause()
    check(waitFor(25) { sp.state == .idle }, "plays to the end")
    check(sp.index == 4, "index at end (\(sp.index)/4)")
    check(sp.engineError == nil, "no engine error (\(sp.engineError ?? ""))")
    print("     took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, word updates: \(words)")
}

// Cached: replaying starts at once.
if case .external = Voices.resolve("piper:ro_RO-mihai-medium") {
    let t0 = Date()
    sp.play([PlayItem(sid: "T", lines: ro, voiceID: "piper:ro_RO-mihai-medium")])
    let n = words
    _ = waitFor(5) { words > n }
    check(Date().timeIntervalSince(t0) < 0.5, "cached replay starts in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    sp.stop()
}

watcher.cancel()
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
