// Off-screen UI snapshot (no Screen Recording permission needed).
// swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Views,Model}.swift tests/render/main.swift
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.dropFirst().first ?? "."
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
    let model = AppModel.shared
    model.speaker.onItemStart = nil            // don't mark real sessions heard

    @MainActor func snapshot<V: View>(_ name: String, width: CGFloat = 420, height: CGFloat = 640, _ view: V) {
        let host = NSHostingView(rootView: view
            .environmentObject(model.store)
            .environmentObject(model.speaker)
            .environmentObject(model.summarizer)
            .environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .aqua)   // dark text vanishes on this capture's white backing
        win.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print(url.path)
    }

    // Newest session selected; play its full text paused at sentence 3 to show the highlight.
    if let s = model.store.sessions.first {
        model.speaker.play([model.fullItem(s)])
        model.speaker.stop()
        model.speaker.speak(at: 2)
        model.speaker.togglePause()
    }
    snapshot("full", ContentView())
    model.speaker.stop()

    // Settings, once the Piper and Microsoft voices have been looked up.
    let end = Date().addingTimeInterval(20)
    while VoiceCatalog.shared.scanning || (VoiceCatalog.shared.python[.edge] != nil && VoiceCatalog.shared.edge.isEmpty),
          Date() < end {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    snapshot("settings", width: 420, height: 680, SettingsView())
}
