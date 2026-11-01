import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Speech

/// Hands the microphone's audio to the recognizer from the audio thread, which must not touch
/// main-actor state.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var peak: Float = 0
    private var buffers = 0

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request = r
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var rms: Float = 0
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            rms = (sum / Float(buffer.frameLength)).squareRoot()
        }
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, rms)
        buffers += 1
        request?.append(buffer)
    }

    /// Loudest buffer and number of buffers since the last call.
    func take() -> (level: Float, buffers: Int) {
        lock.lock(); defer { lock.unlock() }
        defer { peak = 0; buffers = 0 }
        return (peak, buffers)
    }
}

/// Opt-in diagnostics: `defaults write local.claude-voice voiceDebug -bool true` writes what the
/// microphone and the recognizer do to <state>/voice.log (including what was heard). Off by default.
enum VoiceLog {
    static var on: Bool { UserDefaults.standard.bool(forKey: "voiceDebug") }
    static let file = Paths.base.appendingPathComponent("voice.log")
    private static let queue = DispatchQueue(label: "voice-log")

    static func write(_ line: @autoclosure () -> String) {
        guard on else { return }
        let text = line()
        queue.async {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            let entry = "\(f.string(from: Date())) \(text)\n"
            let fm = FileManager.default
            try? fm.createDirectory(at: Paths.base, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 200_000 {
                try? fm.removeItem(at: file)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(entry.utf8))
                try? h.close()
            } else {
                try? entry.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Listens on the default microphone (the headset's, when it is the system input) for spoken commands:
/// "Hey Claude, play last response". Recognition is Apple's, on this Mac (`requiresOnDeviceRecognition`).
/// What counts as a command is decided by `WakeGate` and `VoiceGrammar` (VoiceIntent.swift); the result
/// goes to `AppModel.runVoice`.
///
/// The audio engine stays open while the feature is on; only the recognition request is replaced,
/// after every command and after a few seconds of quiet, so each request holds about one utterance.
@MainActor
final class VoiceListener: ObservableObject {
    static let shared = VoiceListener()

    enum Status: Equatable {
        case off
        case starting
        case listening
        case armed                      // "Hey Claude" heard, waiting for the command
        case answering                  // capturing the user's spoken answer to a session (talk back)
        case denied(String)
        case unavailable(String)
    }

    @Published private(set) var status: Status = .off
    /// The last thing the recognizer wrote down, for the Settings line.
    @Published private(set) var lastHeard = ""
    /// What the app understood from it.
    @Published private(set) var lastResult = ""
    /// The microphone macOS is using right now (to see whether it is the headset).
    @Published private(set) var inputDevice = ""
    /// Loudness of the microphone signal, 0...1 (is the mic delivering sound at all?).
    @Published private(set) var level: Float = 0
    /// The last problem: the recognizer failing, or no audio arriving. Cleared when text is heard.
    @Published private(set) var problem = ""

    /// A line for the Settings window and menu.
    var statusText: String {
        switch status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .armed: return "Listening for the command…"
        case .answering: return "Listening for your answer…"
        case .denied(let why), .unavailable(let why): return why
        }
    }

    private let engine = AVAudioEngine()
    private let sink = AudioSink()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var gate = WakeGate()
    private var ticker: Timer?
    private var configObserver: NSObjectProtocol?
    private var running = false
    private var wanted = false
    private var generation = 0          // bumped per recognition; late callbacks of old ones are ignored
    private var transcript = ""
    private var lastChange = Date()
    private var startedAt = Date()
    private var ticks = 0
    private var pausedForWake = false  // we paused playback when "Hey Claude" was heard
    private var silentTicks = 0         // ticks in a row with no audio from the microphone
    // Talk back: while `capture` is set, everything heard goes to `captureHandler` and no wake phrase is needed.
    private var capture: ReplyCaptureKind?
    private var captureHandler: ((String) -> Void)?
    private var captureBase = ""        // what earlier requests of this capture heard (a request lasts < 1 min)
    private var captureSound = false    // some sound, not digital silence, reached the microphone

    /// Quiet seconds after which an unclaimed transcript is dropped and recognition starts fresh.
    private static let quiet: TimeInterval = 3
    /// Even with no speech at all, start fresh this often (the recognizer gives up after a while).
    private static let refresh: TimeInterval = 50

    private init() {
        // No `queue: .main`: a setting changed from a main-actor task (a spoken "progress on") would post
        // this synchronously to the main queue it is running on and wait for itself.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: nil) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    // MARK: settings

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "voiceControl") }
    static var requireWake: Bool { UserDefaults.standard.object(forKey: "voiceWakeWord") as? Bool ?? true }

    /// Start or stop to match the "voiceControl" switch, and pick up "voiceWakeWord".
    func sync() {
        gate.requireWake = Self.requireWake
        let on = Self.enabled
        guard on != wanted else { return }
        wanted = on
        if on { start() } else { stop() }
    }

    // MARK: start / stop

    private func start() {
        guard !running, status != .starting else { return }
        status = .starting
        Task {
            VoiceLog.write("start: authorizing")
            if let problem = await Self.authorize() {
                VoiceLog.write("start: \(problem)")
                status = problem
                return
            }
            // Switched off while the permission prompts were open.
            guard wanted else { status = .off; return }
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable else {
                status = .unavailable("Speech recognition is not available right now.")
                return
            }
            guard rec.supportsOnDeviceRecognition else {
                status = .unavailable("English dictation is not installed. Turn it on in System Settings → Keyboard → Dictation, then switch voice commands off and on.")
                return
            }
            recognizer = rec
            VoiceLog.write("start: recognizer ok, on-device \(rec.supportsOnDeviceRecognition)")
            begin()
        }
    }

    /// nil when both permissions are granted (asking if needed), else the status to show.
    private static func authorize() async -> Status? {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return .denied("Speech recognition is not allowed. Allow Claude Voice in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return .denied("Microphone access is not allowed. Allow Claude Voice in System Settings → Privacy & Security → Microphone.")
        }
        return nil
    }

    private func begin() {
        guard startEngine() else { return }
        running = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioRouteChanged() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        newRecognition()
    }

    private func stop() {
        wanted = false
        running = false
        ticker?.invalidate()
        ticker = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        generation += 1
        task?.cancel()
        task = nil
        sink.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        gate.reset()
        transcript = ""
        level = 0
        problem = ""
        pausedForWake = false
        status = .off
    }

    /// (Re)installs the microphone tap with the input's current format.
    private func startEngine() -> Bool {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        updateInputDevice()
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = .unavailable("No microphone input. Connect the headset or pick an input in System Settings → Sound.")
            return false
        }
        VoiceLog.write("engine: input \"\(inputDevice)\" \(format.sampleRate) Hz, \(format.channelCount) ch")
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            status = .unavailable("Could not open the microphone: \(error.localizedDescription)")
            return false
        }
    }

    /// The headset connected, disconnected or changed profile (Bluetooth switches to the call profile
    /// when its microphone opens): the engine has stopped, so take the new format and go on.
    private func audioRouteChanged() {
        guard running else { return }
        VoiceLog.write("engine: configuration changed")
        if startEngine() {
            newRecognition()
        } else {
            retryEngineSoon()
        }
    }

    private func retryEngineSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard running else { return }
            if startEngine() { newRecognition() } else { retryEngineSoon() }
        }
    }

    // MARK: recognition

    /// Words the recognizer should expect: the wake phrase, the commands, and the project names.
    private func hints() -> [String] {
        var out = ["Hey Claude", "play last response", "play last response summarized", "summarized",
                   "summary", "pause", "resume", "stop", "progress", "which sessions", "switch to",
                   "from the beginning"]
        for s in AppModel.shared.store.visible.prefix(10) where !s.project.isEmpty {
            out.append(s.project.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
        }
        return out
    }

    private func newRecognition() {
        task?.cancel()
        task = nil
        generation += 1
        let gen = generation
        gate.reset()
        transcript = ""
        lastChange = Date()
        startedAt = Date()
        guard running, let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = capture == .dictation
        request.taskHint = .dictation
        switch capture {
        case .dictation?: request.contextualStrings = []
        case .confirm?: request.contextualStrings = ["send", "cancel", "redo", "yes", "no", "send it", "try again"]
        case nil: request.contextualStrings = hints()
        }
        sink.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || error != nil
            let failure = error.map { e -> String in
                let ns = e as NSError
                return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            }
            Task { @MainActor in self?.heard(text, finished: finished, failure: failure, generation: gen) }
        }
        VoiceLog.write("recognition #\(gen) started")
        status = .listening
    }

    private func heard(_ text: String?, finished: Bool, failure: String?, generation gen: Int) {
        guard gen == generation, running else { return }
        if let text, text != transcript {
            transcript = text
            lastChange = Date()
            lastHeard = text
            if !text.isEmpty, !problem.isEmpty { problem = "" }
            VoiceLog.write("heard: \"\(text)\"")
            if capture != nil {
                captureHandler?((captureBase + " " + text).trimmingCharacters(in: .whitespaces))
            } else if !isEcho(text) {
                handle(gate.hear(text, now: Date()))
            }
        }
        if let failure {
            VoiceLog.write("recognizer error: \(failure)")
            // "No speech detected" is routine while nobody talks; anything else is worth showing.
            if failure.contains("Siri and Dictation are disabled") || failure.contains("kLSRErrorDomain 201") {
                problem = "Dictation is turned off, so nothing can be heard. Turn it on in System Settings → Keyboard → Dictation."
            } else if !failure.contains("No speech") && !failure.contains("1110") {
                problem = "Recognizer: \(failure)"
            }
        }
        guard finished, gen == generation else { return }
        if capture != nil, !transcript.isEmpty {       // keep what was said; the next request adds to it
            captureBase = (captureBase + " " + transcript).trimmingCharacters(in: .whitespaces)
            transcript = ""
        }
        // The recognizer ended this request (its limit, or an error such as "no speech detected").
        // Start another, but not in a tight loop if it keeps failing.
        generation += 1
        let next = generation
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if running, next == generation { newRecognition() }
        }
    }

    /// True when the transcript is just our own voice coming back through the microphone.
    private func isEcho(_ text: String) -> Bool {
        let speaker = AppModel.shared.speaker
        guard speaker.state == .playing, !speaker.lines.isEmpty else { return false }
        let lo = max(0, speaker.index - 2), hi = min(speaker.lines.count - 1, speaker.index + 2)
        guard lo <= hi else { return false }
        let spoken = speaker.lines[lo...hi].map(\.text)
        return EchoFilter.isEcho(text, spoken: spoken) || EchoFilter.isTailEcho(text, spoken: spoken)
    }

    private func tick() {
        guard running else { return }
        ticks += 1
        if ticks % 10 == 0 { updateInputDevice() }
        let audio = sink.take()
        level = min(1, audio.level.squareRoot() * 2.5)
        if audio.buffers == 0 {
            silentTicks += 1
            if silentTicks == 10 {
                problem = "No audio is reaching the app from the microphone."
                VoiceLog.write("no audio buffers for 3 s")
            }
        } else {
            if silentTicks >= 10, problem.hasPrefix("No audio") { problem = "" }
            silentTicks = 0
        }
        if ticks % 10 == 0 { VoiceLog.write("level \(String(format: "%.3f", audio.level)) buffers \(audio.buffers)") }
        if capture != nil {
            // The answer flow (ReplyFlow) owns the timing. A request only lasts a minute or so: carry what
            // it heard over to the next one.
            if audio.level > 0.0003 { captureSound = true }
            status = .answering
            if Date().timeIntervalSince(startedAt) > 45 {
                captureBase = (captureBase + " " + transcript).trimmingCharacters(in: .whitespaces)
                newRecognition()
            }
            return
        }
        handle(gate.tick(now: Date()))
        guard running else { return }
        status = gate.isArmed ? .armed : .listening
        guard !gate.isArmed else { return }
        let silent = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty, silent > Self.quiet {
            newRecognition()     // chatter or a half-heard phrase: drop it, so it cannot join the next one
        } else if transcript.isEmpty, Date().timeIntervalSince(startedAt) > Self.refresh {
            newRecognition()
        }
    }

    private func handle(_ action: WakeGate.Action) {
        if action != .none { VoiceLog.write("gate: \(action)") }
        switch action {
        case .none:
            break
        case .wake(let alone):
            // "Hey Claude" while something is being read: stop talking over the user.
            let speaker = AppModel.shared.speaker
            if speaker.state == .playing {
                speaker.pause()
                pausedForWake = true
            }
            if alone {
                NSSound(named: "Tink")?.play()
                status = .armed
            }
        case .execute(let intent):
            lastResult = Self.describe(intent)
            let quiet: Bool
            switch intent {
            case .stop, .pause: quiet = true
            default: quiet = false
            }
            if !quiet { NSSound(named: "Pop")?.play() }
            pausedForWake = false      // the command decides what happens to the paused reply
            AppModel.shared.runVoice(intent)
            newRecognition()
        case .notUnderstood:
            lastResult = "not understood"
            NSSound(named: "Basso")?.play()
            resumeIfPausedForWake()
            newRecognition()
        case .expired:
            resumeIfPausedForWake()
            newRecognition()
        }
    }

    /// Nothing usable followed "Hey Claude": carry on reading what it interrupted.
    private func resumeIfPausedForWake() {
        guard pausedForWake else { return }
        pausedForWake = false
        let speaker = AppModel.shared.speaker
        if speaker.state == .paused { speaker.resume() }
    }

    static func describe(_ i: VoiceIntent) -> String {
        switch i {
        case .play(let summary, let project):
            return "play" + (summary ? " summary" : "") + (project.map { " from \($0)" } ?? "")
        case .back(let n): return "back \(n)"
        case .forward(let n): return "forward \(n)"
        case .progress(let on): return "progress \(on ? "on" : "off")"
        case .listSessions: return "list sessions"
        case .reply(let project): return "reply" + (project.map { " to \($0)" } ?? "")
        default: return String(describing: i)
        }
    }

    // MARK: talk back (ReplyMic)

    /// True when the microphone is open and recognizing, so an answer can be heard.
    var isReady: Bool { running && recognizer != nil }

    /// Hear a free answer (`.dictation`) or "send / cancel / redo" (`.confirm`) instead of commands.
    /// `onText` gets everything heard in this capture so far, again each time it grows.
    func beginCapture(_ kind: ReplyCaptureKind, onText: @escaping (String) -> Void) {
        capture = kind
        captureHandler = onText
        captureBase = ""
        captureSound = false
        pausedForWake = false
        VoiceLog.write("capture: begin \(kind)")
        if running { newRecognition() }
    }

    /// Back to spoken commands.
    func endCapture() {
        guard capture != nil else { return }
        VoiceLog.write("capture: end")
        capture = nil
        captureHandler = nil
        captureBase = ""
        if running { newRecognition() }
        status = running ? .listening : status
    }

    /// Whether any sound (not digital silence) came from the microphone during this capture: a muted
    /// headset delivers none.
    var heardSound: Bool { captureSound }

    // MARK: input device

    private func updateInputDevice() {
        let name = Self.defaultInputName()
        if name != inputDevice { inputDevice = name }
    }

    /// Name of the system's default input device ("AirPods Pro", "MacBook Pro Microphone").
    static func defaultInputName() -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return "" }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &nameSize, &name) == noErr,
              let name else { return "" }
        return name.takeRetainedValue() as String
    }
}

extension VoiceListener: ReplyMic {}
