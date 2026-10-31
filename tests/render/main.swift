// Off-screen UI snapshot (no Screen Recording permission needed).
// swiftc -swift-version 5 Sources/{Speaker,Store,Markdown,Summarizer,Views,Model}.swift tests/render/main.swift
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.dropFirst().first ?? "."
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
    let model = AppModel.shared
    model.speaker.onItemStart = nil            // don't mark real sessions heard

    func snapshot(_ name: String) {
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(model.store)
            .environmentObject(model.speaker)
            .environmentObject(model.summarizer)
            .environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
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
    snapshot("full")
    model.speaker.stop()
}
