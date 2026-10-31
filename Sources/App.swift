import AppKit
import SwiftUI

@main
struct ClaudeVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppModel.shared.store
    @StateObject private var speaker = AppModel.shared.speaker
    @StateObject private var summarizer = AppModel.shared.summarizer
    @StateObject private var model = AppModel.shared
    @StateObject private var voice = VoiceListener.shared

    var body: some Scene {
        Window("Claude Voice", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(speaker)
                .environmentObject(summarizer)
                .environmentObject(model)
                .environmentObject(voice)
        }
        .defaultSize(width: 400, height: 620)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
                .environmentObject(speaker)
                .environmentObject(summarizer)
                .environmentObject(voice)
        } label: {
            Image(systemName: speaker.state == .playing ? "waveform.circle.fill" : "waveform")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starts listening when "Voice commands" was left on.
        VoiceListener.shared.sync()
    }

    // Closing the window keeps the app (and menu bar icon) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
