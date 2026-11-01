import Foundation

/// What the user said when asked "send or cancel?".
enum ReplyConfirm: Equatable {
    case send, cancel, redo
}

/// The tiny vocabulary of the answer flow. English only, short utterances only: a long sentence is
/// the user talking to someone else, not an answer to "send or cancel?".
enum ReplyGrammar {
    private static let cancelWords: Set<String> = [
        "cancel", "no", "nope", "nah", "discard", "dont", "don't", "stop", "negative",
    ]
    private static let cancelPhrases = ["never mind", "nevermind", "forget it", "scratch that", "do not send", "dont send"]
    private static let redoWords: Set<String> = ["redo", "again", "retry", "rerecord", "restart"]
    private static let redoPhrases = ["try again", "start over", "say again", "do over", "once more"]
    private static let sendWords: Set<String> = [
        "send", "yes", "yeah", "yep", "yup", "confirm", "confirmed", "ok", "okay", "sure", "correct", "affirmative",
    ]
    private static let sendPhrases = ["go ahead", "do it", "send it", "that's right", "thats right", "sounds good"]

    /// The answer to "Say send or cancel": nil when it is none of them (keep listening).
    static func confirm(_ text: String) -> ReplyConfirm? {
        let w = VoiceGrammar.normalize(text)
        guard !w.isEmpty, w.count <= 4 else { return nil }
        let line = " " + w.joined(separator: " ") + " "
        let set = Set(w)
        // Cancel beats send: "no, don't send it".
        if !set.isDisjoint(with: cancelWords) || cancelPhrases.contains(where: { line.contains(" \($0) ") }) { return .cancel }
        if !set.isDisjoint(with: redoWords) || redoPhrases.contains(where: { line.contains(" \($0) ") }) { return .redo }
        if !set.isDisjoint(with: sendWords) || sendPhrases.contains(where: { line.contains(" \($0) ") }) { return .send }
        return nil
    }

    /// While dictating, only these whole utterances abort the answer: "no" or "stop" can be the answer itself.
    static func isAbort(_ text: String) -> Bool {
        let line = " " + VoiceGrammar.normalize(text).joined(separator: " ") + " "
        return ["cancel that", "cancel reply", "cancel the reply", "never mind", "nevermind", "forget it", "scratch that"]
            .contains { line.trimmingCharacters(in: .whitespaces) == $0 }
    }
}

/// The exchange that carries the user's spoken answer to a Claude Code session, as pure logic:
///
///     listening ──words──▶ capturing ──silence──▶ reading back ──spoken──▶ confirming ──"send"──▶ deliver
///         │ window over        │ "cancel that"        │                        │ "cancel"/silence
///         ▼                    ▼                      │                        ▼
///       ended                ended                    └───── abort ─────▶    ended
///
/// It owns no clock and no microphone: the caller feeds it what was heard (`hear`), calls `tick` a few
/// times a second, and does what the returned effects say. That keeps every rule testable without audio.
/// Nothing is ever delivered without an explicit "send"; silence cancels.
struct ReplyFlow {
    struct Config {
        /// How long the microphone waits for the user to start talking.
        var window: TimeInterval = 30
        /// The answer is complete when the transcript has not changed for this long.
        var endSilence: TimeInterval = 2
        /// An answer is cut off here, whatever is still being said.
        var hardCap: TimeInterval = 60
        /// How long "send or cancel?" waits before it means cancel.
        var confirmWindow: TimeInterval = 10
        /// The read-back should be over by now; if it never says so, the exchange is dropped.
        var readBackLimit: TimeInterval = 45
    }

    enum Outcome: Equatable {
        case sent, cancelled, timedOut, aborted
    }

    enum Effect: Equatable {
        /// The window just opened: play the "speak now" sound.
        case chime
        /// Capture free text; report partial transcripts through `hear`.
        case beginDictation
        /// Capture "send / cancel / redo"; report partial transcripts through `hear`.
        case beginConfirm
        /// Speak this. For the read-back, call `speechFinished` once it has been spoken.
        case say(String)
        case deliver(sid: String, text: String)
        case ended(Outcome)
    }

    enum Phase: Equatable {
        case idle
        case listening(sid: String, until: Date)
        case capturing(sid: String, text: String, startedAt: Date, changedAt: Date)
        case readingBack(sid: String, text: String, since: Date)
        case confirming(sid: String, text: String, until: Date)
    }

    var config = Config()
    private(set) var phase: Phase = .idle
    private var project = ""
    private var showProject = false

    var isIdle: Bool { phase == .idle }

    var sid: String? {
        switch phase {
        case .idle: return nil
        case .listening(let s, _), .capturing(let s, _, _, _), .readingBack(let s, _, _), .confirming(let s, _, _): return s
        }
    }

    /// Open the listening window for a session. Ignored while an exchange is already running.
    /// `project` is spoken in the read-back when `announce` is set (several sessions are listening).
    mutating func open(sid: String, project: String = "", announce: Bool = false, now: Date) -> [Effect] {
        guard isIdle else { return [] }
        self.project = project
        showProject = announce && !project.isEmpty
        phase = .listening(sid: sid, until: now.addingTimeInterval(config.window))
        return [.chime, .beginDictation]
    }

    /// Everything said so far in the current capture (not just the newest words).
    mutating func hear(_ transcript: String, now: Date) -> [Effect] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        switch phase {
        case .listening(let sid, _):
            guard !text.isEmpty else { return [] }
            if ReplyGrammar.isAbort(text) { return finish(.cancelled, say: "Cancelled.") }
            phase = .capturing(sid: sid, text: text, startedAt: now, changedAt: now)
            return []
        case .capturing(let sid, let old, let started, let changed):
            if ReplyGrammar.isAbort(text) { return finish(.cancelled, say: "Cancelled.") }
            let isNew = text != old && !text.isEmpty
            phase = .capturing(sid: sid, text: isNew ? text : old, startedAt: started, changedAt: isNew ? now : changed)
            return []
        case .confirming(let sid, let answer, _):
            guard let c = ReplyGrammar.confirm(text) else { return [] }
            switch c {
            case .send:
                phase = .idle
                return [.deliver(sid: sid, text: answer), .ended(.sent)]
            case .cancel:
                return finish(.cancelled, say: "Not sent.")
            case .redo:
                phase = .listening(sid: sid, until: now.addingTimeInterval(config.window))
                return [.chime, .beginDictation]
            }
        case .idle, .readingBack:
            return []
        }
    }

    mutating func tick(now: Date) -> [Effect] {
        switch phase {
        case .idle:
            return []
        case .readingBack(_, _, let since):
            // The read-back never reported that it finished (it was interrupted): give up, do not hang.
            guard now.timeIntervalSince(since) >= config.readBackLimit else { return [] }
            return finish(.aborted, say: "Not sent.")
        case .listening(_, let until):
            guard now >= until else { return [] }
            phase = .idle
            return [.ended(.timedOut)]
        case .capturing(let sid, let text, let started, let changed):
            let quiet = now.timeIntervalSince(changed) >= config.endSilence
            let capped = now.timeIntervalSince(started) >= config.hardCap
            guard quiet || capped else { return [] }
            phase = .readingBack(sid: sid, text: text, since: now)
            let to = showProject ? "To \(project). " : ""
            return [.say("\(to)Sending: \(text). Say send, or cancel.")]
        case .confirming(_, _, let until):
            guard now >= until else { return [] }
            return finish(.cancelled, say: "Not sent.")
        }
    }

    /// The read-back has been spoken: now listen for "send".
    mutating func speechFinished(now: Date) -> [Effect] {
        guard case .readingBack(let sid, let text, _) = phase else { return [] }
        phase = .confirming(sid: sid, text: text, until: now.addingTimeInterval(config.confirmWindow))
        return [.beginConfirm]
    }

    /// Something else took over (the user typed, played something, the session went away).
    mutating func abort(say: String? = nil) -> [Effect] {
        guard !isIdle else { return [] }
        phase = .idle
        return (say.map { [Effect.say($0)] } ?? []) + [.ended(.aborted)]
    }

    private mutating func finish(_ outcome: Outcome, say: String) -> [Effect] {
        phase = .idle
        return [.say(say), .ended(outcome)]
    }
}
