// Summarizer test: swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer}.swift tests/summary/main.swift
// Run like a Finder-launched app: env -i HOME=$HOME USER=$USER LOGNAME=$USER TMPDIR=$TMPDIR PATH=/usr/bin:/bin ./build/sumtest [quick-sid] [session-sid]
import Foundation

Task { @MainActor in
    print("claude: \(ClaudeCLI.path ?? "NOT FOUND"), language: \(Languages.selected.name)")
    let store = Store()
    for s in store.sessions {
        if let i = SessionInfo.of(s) {
            print("\(s.displayProject): \(i.contextTokens / 1000)k tokens, model \(i.model ?? "?"), cwd \(i.cwd), warm \(i.cacheLikelyWarm)")
        } else {
            print("\(s.displayProject): no session info")
        }
    }
    let args = Array(CommandLine.arguments.dropFirst())
    let sum = Summarizer()
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.replies.path)) ?? [])

    for (i, mode) in [ReadMode.quick, ReadMode.session].enumerated() where i < args.count {
        guard let s = store.sessions.first(where: { $0.id == args[i] }) else { continue }
        let t = Date()
        let text = await sum.summary(for: s, mode)
        let info = sum.cachedInfo(s, mode)
        print(String(format: "\n%@ on %@: %.1fs, %d words, error: %@, cacheRead: %@", mode.rawValue, s.displayProject,
                     Date().timeIntervalSince(t), text?.split(separator: " ").count ?? 0, sum.lastError ?? "none",
                     "\(info?["cacheRead"] ?? "-")"))
        print(text ?? "-")
    }
    let after = Set((try? FileManager.default.contentsOfDirectory(atPath: Paths.replies.path)) ?? [])
    print("\nreply files unchanged (no hook loop, no new session): \(before == after)")
    exit(0)
}
dispatchMain()
