import AVFoundation
import Foundation

/// How a reply is read: the real text, Haiku's summary, or the session's own summary.
enum ReadMode: String, CaseIterable {
    case full, quick, session
}

/// One reply queued for playback, already split into sentences.
struct PlayItem {
    let sid: String
    let lines: [String]
    var mode: ReadMode = .full
    var voiceID: String?        // nil = main voice
    var headerLines = 0         // spoken "From <project>." lines before the reply
}

/// A sentence in the playlist. `id` is its position in the whole playlist.
struct Line: Identifiable {
    let id: Int
    let item: Int
    let text: String
}

/// Plays a playlist of sentences, one utterance per sentence, so it always
/// knows the exact sentence and word being spoken (back/next/skip are exact).
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum State { case idle, playing, paused }

    @Published private(set) var items: [PlayItem] = []
    @Published private(set) var lines: [Line] = []
    @Published private(set) var index = 0          // == lines.count when finished
    @Published private(set) var state: State = .idle
    @Published private(set) var word: NSRange?     // word being spoken in lines[index]

    /// Called when playback reaches the first sentence of a reply.
    var onItemStart: ((String) -> Void)?

    /// Bumped by play() and stop(), so late async work can tell it was superseded.
    private(set) var generation = 0

    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var startedItem: Int?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: queries

    /// Reply shown in the player: the one playing, else the last one.
    var displayItem: Int? {
        if lines.indices.contains(index) { return lines[index].item }
        return items.isEmpty ? nil : items.count - 1
    }

    var currentSid: String? {
        guard state != .idle, lines.indices.contains(index) else { return nil }
        return items[lines[index].item].sid
    }

    func lines(ofItem item: Int) -> [Line] { lines.filter { $0.item == item } }

    // MARK: playlist

    /// Replace the playlist and start playing (optionally from a later sentence).
    func play(_ new: [PlayItem], from start: Int = 0) {
        generation += 1
        stopSynth()
        items = []
        lines = []
        startedItem = nil
        new.forEach(append)
        speak(at: start)
    }

    /// Append without interrupting; starts it if nothing is playing.
    func enqueue(_ item: PlayItem) {
        guard !item.lines.isEmpty else { return }
        append(item)
        if state == .idle {
            speak(at: lines.firstIndex { $0.item == items.count - 1 } ?? lines.count)
        }
    }

    private func append(_ item: PlayItem) {
        guard !item.lines.isEmpty else { return }
        let n = items.count
        let base = lines.count
        items.append(item)
        lines += item.lines.enumerated().map { Line(id: base + $0.offset, item: n, text: $0.element) }
    }

    // MARK: transport

    func speak(at i: Int) {
        stopSynth()
        guard lines.indices.contains(i) else {
            index = lines.count
            state = .idle
            word = nil
            return
        }
        let startsItem = startedItem != lines[i].item   // first time we speak this reply
        startedItem = lines[i].item
        index = i
        word = nil
        let u = AVSpeechUtterance(string: lines[i].text)
        u.voice = Voices.voice(id: items[lines[i].item].voiceID)
        u.rate = Settings.rate
        current = u
        synth.speak(u)
        state = .playing
        if startsItem { onItemStart?(items[lines[i].item].sid) }
    }

    func togglePause() {
        switch state {
        case .playing:
            synth.pauseSpeaking(at: .word)
            state = .paused
        case .paused:
            synth.continueSpeaking()
            state = .playing
        case .idle:
            if lines.indices.contains(index) {
                speak(at: index)                     // resume after stop
            } else if let it = displayItem {
                speak(at: lines.firstIndex { $0.item == it } ?? 0)   // replay last reply
            }
        }
    }

    func stop() {
        generation += 1
        stopSynth()
        state = .idle
        word = nil
    }

    func back(_ n: Int = 1) { speak(at: max(0, min(index, lines.count) - n)) }

    func next(_ n: Int = 1) { speak(at: index + n) }

    /// Start the current (or last) reply from its first sentence.
    func restart() {
        guard let it = displayItem else { return }
        speak(at: lines.firstIndex { $0.item == it } ?? 0)
    }

    /// Jump to the first sentence of the next reply.
    func skip() {
        guard lines.indices.contains(index) else { return }
        let it = lines[index].item
        speak(at: lines.firstIndex { $0.item > it } ?? lines.count)
    }

    func test() {
        play([PlayItem(sid: "_test", lines: ["This is how I will read Claude's replies."])])
    }

    private func stopSynth() {
        current = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    // MARK: AVSpeechSynthesizerDelegate (any thread -> main)

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.current else { return }  // ignore stopped/stale utterances
            self.speak(at: self.index + 1)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange,
                           utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.current else { return }
            self.word = r
        }
    }
}

/// Languages offered for summaries (Romanian by default).
enum Languages {
    struct Lang: Hashable { let code: String; let name: String; let native: String }

    static let all: [Lang] = [
        Lang(code: "ro-RO", name: "Romanian", native: "Română"),
        Lang(code: "en-US", name: "English", native: "English"),
        Lang(code: "fr-FR", name: "French", native: "Français"),
        Lang(code: "de-DE", name: "German", native: "Deutsch"),
        Lang(code: "es-ES", name: "Spanish", native: "Español"),
        Lang(code: "it-IT", name: "Italian", native: "Italiano"),
        Lang(code: "pt-PT", name: "Portuguese", native: "Português"),
        Lang(code: "nl-NL", name: "Dutch", native: "Nederlands"),
        Lang(code: "pl-PL", name: "Polish", native: "Polski"),
        Lang(code: "hu-HU", name: "Hungarian", native: "Magyar"),
    ]

    static var selected: Lang {
        let code = UserDefaults.standard.string(forKey: "summaryLang") ?? "ro-RO"
        return all.first { $0.code == code } ?? all[0]
    }
}

enum Settings {
    static var rate: Float {
        let r = UserDefaults.standard.double(forKey: "rate")
        return r == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(r)
    }
}

enum Voices {
    /// Installed voices, best quality first, novelty voices removed.
    static let all: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        .sorted {
            $0.quality.rawValue != $1.quality.rawValue
                ? $0.quality.rawValue > $1.quality.rawValue
                : $0.name < $1.name
        }

    /// Evan (Enhanced) if installed, else the best US English voice.
    static let preferred: AVSpeechSynthesisVoice? =
        all.first { $0.name.hasPrefix("Evan") && $0.quality != .default }
        ?? all.first { $0.language == "en-US" && $0.quality != .default }
        ?? AVSpeechSynthesisVoice(language: "en-US")

    private static var cache: (id: String, voice: AVSpeechSynthesisVoice?)?

    static var selected: AVSpeechSynthesisVoice? {
        let id = UserDefaults.standard.string(forKey: "voiceID") ?? ""
        if id.isEmpty { return preferred }
        if let c = cache, c.id == id { return c.voice }
        let v = AVSpeechSynthesisVoice(identifier: id) ?? preferred
        cache = (id, v)
        return v
    }

    /// A specific voice by identifier, or the main voice for nil/unknown ids.
    static func voice(id: String?) -> AVSpeechSynthesisVoice? {
        guard let id, !id.isEmpty else { return selected }
        return AVSpeechSynthesisVoice(identifier: id) ?? selected
    }

    /// Best installed voice for a language code like "ro-RO" (matches on "ro").
    static func best(for lang: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(lang.prefix(2))
        return all.first { $0.language == lang } ?? all.first { $0.language.hasPrefix(prefix) }
    }

    /// Voice used for summaries: the one picked in Settings, else the best for the language.
    static func summaryVoiceID() -> String? {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "summaryVoiceID"), !id.isEmpty { return id }
        return best(for: Languages.selected.code)?.identifier
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        if v.name.contains("(") { return v.name }   // macOS names already say "(Enhanced)"
        switch v.quality {
        case .premium: return "\(v.name) (Premium)"
        case .enhanced: return "\(v.name) (Enhanced)"
        default: return v.name
        }
    }
}
