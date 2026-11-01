import AVFoundation
import Foundation

/// How a reply is read: the real text, Haiku's summary, or the summary the session wrote itself
/// (/summarize-for-voice in Claude Code).
enum ReadMode: String, CaseIterable {
    case full, quick, session
}

/// One reply queued for playback, already split into sentences.
struct PlayItem {
    let sid: String
    let lines: [String]
    var mode: ReadMode = .full
    var voiceID: String?        // nil = main voice
    var headerLines = 0         // spoken "From <project>." lines before the reply (main voice)
    var isProgress = false      // a short between-tool-calls message, not the reply (see dropQueuedProgress)
    /// After this reply is read to the end, the user may answer it by voice (talk back).
    var offersReply = false
    /// The session's reply time when this was queued: only the latest reply of a session is answered.
    var stamp: Date?
}

/// A sentence in the playlist. `id` is its position in the whole playlist, `local` in its reply.
struct Line: Identifiable {
    let id: Int
    let item: Int
    let local: Int
    let text: String
}

/// Plays a playlist of sentences, one utterance (or audio file) per sentence, so it always
/// knows the exact sentence and word being spoken (back/next/skip are exact).
/// Apple voices speak through AVSpeechSynthesizer; Piper and Microsoft voices come from
/// ExternalTTS as audio files, with the next sentences made ahead of time.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum State { case idle, playing, paused }

    @Published private(set) var items: [PlayItem] = []
    @Published private(set) var lines: [Line] = []
    @Published private(set) var index = 0          // == lines.count when finished
    @Published private(set) var state: State = .idle
    @Published private(set) var word: NSRange?     // word being spoken in lines[index]
    /// Last problem with a Piper or Microsoft voice (playback went on with an Apple voice).
    @Published var engineError: String?

    /// Called when playback reaches the first sentence of a reply.
    var onItemStart: ((String) -> Void)?

    /// Called when the whole playlist has been read to its end (not on stop, skip or next), with the
    /// item that was read last.
    var onFinish: ((PlayItem) -> Void)?

    /// Bumped by play() and stop(), so late async work can tell it was superseded.
    private(set) var generation = 0

    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?        // Apple voice speaking
    private var player: AVAudioPlayer?             // external audio for lines[index]
    private var wordTimer: Timer?
    private var timings: WordTimings?
    private var token = 0                          // bumped on every sentence change
    private var startedItem: Int?

    /// Sentences made ahead for Piper and Microsoft voices.
    static let prefetch = 4

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
        } else {
            prefetch(after: index)
        }
    }

    private func append(_ item: PlayItem) {
        guard !item.lines.isEmpty else { return }
        let n = items.count
        let base = lines.count
        items.append(item)
        lines += item.lines.enumerated().map {
            Line(id: base + $0.offset, item: n, local: $0.offset, text: $0.element)
        }
    }

    // MARK: transport

    func speak(at i: Int, natural: Bool = false) {
        stopSynth()
        guard lines.indices.contains(i) else {
            index = lines.count
            state = .idle
            word = nil
            if natural, let last = items.last { onFinish?(last) }
            return
        }
        let startsItem = startedItem != lines[i].item   // first time we speak this reply
        startedItem = lines[i].item
        index = i
        word = nil
        state = .playing
        switch Voices.resolve(voiceID(i)) {
        case .apple(let v): speakApple(i, v)
        case .external(let v): speakExternal(i, v)
        }
        prefetch(after: i)
        if startsItem { onItemStart?(items[lines[i].item].sid) }
    }

    /// Explicit versions of togglePause, for commands from Claude Code (idempotent).
    func pause() { if state == .playing { togglePause() } }

    func resume() { if state != .playing { togglePause() } }

    func togglePause() {
        switch state {
        case .playing:
            if current != nil { synth.pauseSpeaking(at: .word) } else { player?.pause() }
            state = .paused
        case .paused:
            if current != nil {
                synth.continueSpeaking()
                state = .playing
            } else if let p = player {
                p.play()
                state = .playing
            } else {
                speak(at: index)                     // its audio never arrived: ask again
            }
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

    /// Jump to the first sentence of the previous reply.
    func prev() {
        guard let it = displayItem, it > 0 else { return restart() }
        speak(at: lines.firstIndex { $0.item == it - 1 } ?? 0)
    }

    /// A reply is final: progress messages of that session that have not started playing are stale.
    /// They are removed from the playlist (the app still has them recorded).
    func dropQueuedProgress(sid: String) {
        guard lines.indices.contains(index) else { return }
        let cur = lines[index].item
        let doomed = items.indices.filter { $0 > cur && items[$0].isProgress && items[$0].sid == sid }
        guard !doomed.isEmpty else { return }
        let kept = items.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        var rebuilt: [Line] = []
        for (n, item) in kept.enumerated() {
            for (i, text) in item.lines.enumerated() {
                rebuilt.append(Line(id: rebuilt.count, item: n, local: i, text: text))
            }
        }
        items = kept
        lines = rebuilt              // everything up to the current item is unchanged: index stays valid
        if let s = startedItem, s > cur { startedItem = cur }
    }

    /// Jump to the first sentence of the next reply.
    func skip() {
        guard lines.indices.contains(index) else { return }
        let it = lines[index].item
        speak(at: lines.firstIndex { $0.item > it } ?? lines.count)
    }

    /// Say a sample with a voice (nil = the main voice).
    func test(voiceID: String? = nil, text: String = "This is how I will read Claude's replies.") {
        play([PlayItem(sid: "_test", lines: [text], voiceID: voiceID)])
    }

    // MARK: engines

    /// The reply's voice, except for the "From <project>." header, which uses the main voice.
    private func voiceID(_ i: Int) -> String? {
        let l = lines[i]
        let item = items[l.item]
        return l.local < item.headerLines ? nil : item.voiceID
    }

    private func speakApple(_ i: Int, _ v: AVSpeechSynthesisVoice?) {
        let u = AVSpeechUtterance(string: lines[i].text)
        u.voice = v
        u.rate = Settings.rate
        current = u
        synth.speak(u)
    }

    private func speakExternal(_ i: Int, _ v: ExternalVoice) {
        let t = token
        let text = lines[i].text
        ExternalTTS.shared.audio(text, voice: v, speed: Settings.speed) { [weak self] r in
            guard let self, t == self.token else { return }   // moved on meanwhile
            switch r {
            case .success(let url):
                if self.playFile(url, text) { return }
                try? FileManager.default.removeItem(at: url)
                self.fallBack(i, v, "could not play its audio")
            case .failure(let f):
                self.fallBack(i, v, f.message)
            }
        }
    }

    /// Say the sentence with the best Apple voice for its language instead.
    private func fallBack(_ i: Int, _ v: ExternalVoice, _ why: String) {
        engineError = "\(v.engine.title) voice: \(why). Using an Apple voice for now."
        guard state == .playing else { return }   // paused: resuming asks again
        speakApple(i, Voices.bestApple(for: v.language) ?? Voices.mainApple)
    }

    private func playFile(_ url: URL, _ text: String) -> Bool {
        guard let p = try? AVAudioPlayer(contentsOf: url), p.duration > 0 else { return false }
        p.delegate = self
        p.prepareToPlay()
        player = p
        timings = WordTimings(text)
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if state == .playing { p.play() }
        return true
    }

    /// Estimates the spoken word from the playback position (external engines give no word events).
    private func tick() {
        guard let p = player, p.isPlaying, let t = timings else { return }
        let w = t.word(at: p.currentTime / p.duration)
        if w != word { word = w }
    }

    private func prefetch(after i: Int) {
        guard i + 1 < lines.count else { return }
        let speed = Settings.speed
        for j in (i + 1)...min(i + Self.prefetch, lines.count - 1) {
            if case .external(let v) = Voices.resolve(voiceID(j)) {
                ExternalTTS.shared.audio(lines[j].text, voice: v, speed: speed)
            }
        }
    }

    private func stopSynth() {
        token += 1
        current = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        wordTimer?.invalidate()
        wordTimer = nil
        timings = nil
    }

    // MARK: AVSpeechSynthesizerDelegate (any thread -> main)

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.current else { return }  // ignore stopped/stale utterances
            self.speak(at: self.index + 1, natural: true)
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange,
                           utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard u === self.current else { return }
            self.word = r
        }
    }

    // MARK: AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard p === self.player else { return }
            self.speak(at: self.index + 1, natural: true)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(p, successfully: false)
    }
}

/// Where each word of a sentence starts, as a fraction of its audio, weighted by word length.
struct WordTimings {
    private let ranges: [NSRange]
    private let starts: [Double]

    private static let words = try! NSRegularExpression(pattern: #"\S+"#)

    init(_ text: String) {
        ranges = Self.words.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
        let weights = ranges.map { Double($0.length) + 2 }   // + the pause after each word
        let total = max(1, weights.reduce(0, +))
        var acc = 0.0
        starts = weights.map { w in defer { acc += w }; return acc / total }
    }

    func word(at fraction: Double) -> NSRange? {
        guard let k = starts.lastIndex(where: { $0 <= fraction }) else { return ranges.first }
        return ranges[k]
    }
}
