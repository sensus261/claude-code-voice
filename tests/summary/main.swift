// Summarizer test: swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer}.swift tests/summary/main.swift
// Run like a Finder-launched app: env -i HOME=$HOME USER=$USER LOGNAME=$USER TMPDIR=$TMPDIR PATH=/usr/bin:/bin ./build/sumtest [quick-sid]
// Only the low-cost (Haiku) summary can be made by the app. Session summaries come from /summarize-for-voice.
import Foundation

Task { @MainActor in
    print("claude: \(ClaudeCLI.path ?? "NOT FOUND"), language: \(Languages.selected.name)")
    let store = Store()
    for s in store.sessions { print("\(s.displayProject): \(s.words) words, context \(s.context.map(tokenCount) ?? "?")") }
    let args = Array(CommandLine.arguments.dropFirst())
    let sum = Summarizer()
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.replies.path)) ?? [])

    for (i, mode) in [ReadMode.quick].enumerated() where i < args.count {
        guard let s = store.sessions.first(where: { $0.id == args[i] }) else { continue }
        let t = Date()
        let text = await sum.summary(for: s, mode)
        print(String(format: "\n%@ on %@: %.1fs, %d words, error: %@", mode.rawValue, s.displayProject,
                     Date().timeIntervalSince(t), text?.split(separator: " ").count ?? 0, sum.lastError ?? "none"))
        print(text ?? "-")
    }
    // A session summary is never generated here: with nothing stored, asking returns nil without a Claude call.
    if let s = store.sessions.first {
        let none = await sum.summary(for: s, .session)
        print("session summary without import -> \(none == nil ? "nil (no call), ok" : "UNEXPECTED")")
    }
    let after = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.replies.path)) ?? [])
    print("\nreply files unchanged (no hook loop, no new session): \(before == after)")
    exit(0)
}
dispatchMain()
