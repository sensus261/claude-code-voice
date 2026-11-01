import Foundation

/// What the microphone is asked to hear for the answer flow.
enum ReplyCaptureKind: Equatable {
    case dictation      // the answer itself, free text
    case confirm        // "send", "cancel" or "redo"
}

/// The microphone side of the answer flow (VoiceListener implements it; the tests use a fake).
@MainActor
protocol ReplyMic: AnyObject {
    /// True when the microphone is open and recognizing.
    var isReady: Bool { get }
    /// Whether any sound reached the microphone during the current capture (a muted headset gives none).
    var heardSound: Bool { get }
    /// Hear a free answer or "send / cancel / redo". `onText` gets all that was heard in this capture so
    /// far, again each time it grows.
    func beginCapture(_ kind: ReplyCaptureKind, onText: @escaping (String) -> Void)
    /// Back to spoken commands.
    func endCapture()
}

/// Runs the spoken answer to a Claude Code session: opens the listening window, hears the answer, reads it
/// back, and only after "send" hands it to the session's waiter hook (`talk wait`) through `reply-in/`.
/// All decisions are `ReplyFlow`'s; this class connects them to the microphone, the voice and the files,
/// and ends the exchange when the session stops waiting (the user typed in the terminal).
@MainActor
final class ReplyCoordinator {
    /// How long a delivered answer may stay unclaimed before the session counts as gone.
    static let claimLimit: TimeInterval = 5

    private(set) var flow = ReplyFlow()
    private let mic: ReplyMic
    private let clock: () -> Date

    /// Speak a sentence (the answer flow's own voice: read-back and short acknowledgements).
    var say: (String) -> Void = { _ in }
    /// The "speak now" sound.
    var chime: () -> Void = {}
    /// True while the session's waiter hook is armed.
    var waiterAlive: (String) -> Bool = { Waiters.armed($0) }
    /// Hand the answer to the session. False when it could not be saved.
    var deliver: (String, String) -> Bool = { text, sid in Waiters.deliver(text, to: sid) }
    /// True while a delivered answer has not been picked up yet.
    var pending: (String) -> Bool = { Waiters.pending($0) }
    var withdraw: (String) -> Void = { Waiters.withdraw($0) }
    /// The exchange is over and the microphone is back to commands.
    var onIdle: () -> Void = {}
    /// For the Settings line / status: what is happening.
    var onChange: () -> Void = {}

    private var delivering: (sid: String, since: Date)?
    private var timer: Timer?

    init(mic: ReplyMic, clock: @escaping () -> Date = Date.init) {
        self.mic = mic
        self.clock = clock
    }

    var isBusy: Bool { !flow.isIdle || delivering != nil }
    var micReady: Bool { mic.isReady }
    var activeSid: String? { flow.sid ?? delivering?.sid }

    var config: ReplyFlow.Config {
        get { flow.config }
        set { flow.config = newValue }
    }

    // MARK: entry points

    /// Open the listening window for `sid`. `announce`: say which project the answer goes to.
    func open(sid: String, project: String, announce: Bool) {
        guard !isBusy else { return }
        apply(flow.open(sid: sid, project: project, announce: announce, now: clock()))
    }

    /// Something else took over (a command, a new reply for the session, the user playing something).
    func abort(say text: String? = nil) {
        guard !flow.isIdle else { return }
        apply(flow.abort(say: text))
    }

    /// The read-back sentence has been spoken.
    func sayFinished() {
        apply(flow.speechFinished(now: clock()))
    }

    /// Called about three times a second while busy (the coordinator's own timer does it).
    func tick(now: Date? = nil) {
        let now = now ?? clock()
        if let d = delivering {
            if !pending(d.sid) {
                delivering = nil
                say("Sent.")
                finishedDelivery()
            } else if now.timeIntervalSince(d.since) >= Self.claimLimit {
                withdraw(d.sid)                // nobody took it: do not leave it for a later waiter
                delivering = nil
                say("That session is no longer listening.")
                finishedDelivery()
            }
            return
        }
        guard let sid = flow.sid else { return }
        if !waiterAlive(sid) {
            apply(flow.abort(say: "That session is no longer listening."))
            return
        }
        apply(flow.tick(now: now))
    }

    // MARK: effects

    private func heard(_ text: String) {
        apply(flow.hear(text, now: clock()))
    }

    private func apply(_ effects: [ReplyFlow.Effect]) {
        for e in effects {
            switch e {
            case .chime:
                chime()
            case .beginDictation:
                mic.beginCapture(.dictation) { [weak self] in self?.heard($0) }
            case .beginConfirm:
                mic.beginCapture(.confirm) { [weak self] in self?.heard($0) }
            case .say(let text):
                mic.endCapture()                  // never listen to our own voice
                say(text)
            case .deliver(let sid, let text):
                mic.endCapture()
                if deliver(text, sid) {
                    delivering = (sid, clock())
                } else {
                    say("I could not save your answer.")
                }
            case .ended(let outcome):
                mic.endCapture()
                if outcome == .timedOut, !mic.heardSound { say("I could not hear you. Is the headset muted?") }
            }
        }
        updateTimer()
        onChange()
        if !isBusy { onIdle() }
    }

    private func finishedDelivery() {
        updateTimer()
        onChange()
        if !isBusy { onIdle() }
    }

    private func updateTimer() {
        if isBusy, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !isBusy {
            timer?.invalidate()
            timer = nil
        }
    }
}
