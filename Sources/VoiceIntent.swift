import Foundation

/// What the user asked for by voice ("Hey Claude, play last response summarized").
/// Pure value types and string matching only, so the whole grammar is testable without a microphone.
enum VoiceIntent: Equatable {
    /// The newest reply (or the newest one of `project`), in full or as a summary.
    case play(summary: Bool, project: String?)
    case pause, resume, stop, restart, next, previous
    case back(Int)
    case forward(Int)
    /// Turn reading of progress updates on or off.
    case progress(on: Bool)
    /// Read the latest saved progress updates once.
    case status
    case listSessions
}

/// Turns what the speech recognizer heard into a `VoiceIntent`. English only; the phrase lists
/// below are the whole vocabulary.
enum VoiceGrammar {
    static let wakePrefixes: Set<String> = ["hey", "hay", "hi", "okay", "ok", "yo"]
    /// What on-device recognition tends to write for "Claude".
    static let wakeNames: Set<String> = ["claude", "claud", "cloud", "clawed", "clod", "clawd", "clode"]
    /// One-word forms. "iCloud" is what on-device recognition often writes for "Hey Claude".
    private static let wakeJoined: Set<String> = ["heyclaude", "okayclaude", "heycloud", "icloud", "iclaude"]

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    /// Lowercase words without punctuation or apostrophes ("What's" -> "whats"), number words as digits.
    static func normalize(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") {
            if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else if ch != "'" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { numberWords[$0] ?? $0 }
    }

    /// What follows "hey": the usual mis-hearings, or anything that starts like "cl…" ("clark", "clyde",
    /// "class"). Loose on purpose: it only counts after "hey", and a command must still follow.
    private static func soundsLikeClaude(_ word: String) -> Bool {
        wakeNames.contains(word) || (word.hasPrefix("cl") && word.count <= 8)
    }

    /// Index just after the last wake phrase ("hey claude", or "claude" opening the utterance).
    static func wakeEnd(in w: [String]) -> Int? {
        var end: Int?
        for i in w.indices {
            if wakeJoined.contains(w[i]) {
                end = i + 1
            } else if i + 1 < w.count, wakePrefixes.contains(w[i]), soundsLikeClaude(w[i + 1]) {
                end = i + 2
            }
        }
        if end == nil, let first = w.first, wakeNames.contains(first) { end = 1 }
        return end
    }

    static func parse(_ text: String) -> VoiceIntent? { parse(words: normalize(text)) }

    /// `w` is already normalized and has the wake phrase removed.
    static func parse(words w: [String]) -> VoiceIntent? {
        guard !w.isEmpty else { return nil }
        let set = Set(w)
        let line = " " + w.joined(separator: " ") + " "
        func has(_ words: String...) -> Bool { words.contains { set.contains($0) } }
        func said(_ phrases: String...) -> Bool { phrases.contains { line.contains(" \($0) ") } }

        // Which sessions are there?
        if has("sessions"), has("which", "what", "list", "how", "many", "show", "whats") { return .listSessions }

        // Progress updates: switch reading on/off, or read the latest ones once.
        let question = has("what", "whats", "how", "hows", "any")
        if has("progress"), !question, has("on", "off", "start", "stop", "enable", "disable", "begin") {
            let off = has("off", "stop", "disable"), on = has("on", "start", "enable", "begin")
            if off != on { return .progress(on: on) }
            return nil
        }
        if has("progress", "status", "update", "updates") || (has("going") && question),
           question || has("read", "play", "say", "tell", "give", "latest", "current") {
            return .status
        }

        if said("from the beginning", "from the start", "from the top", "start over") || has("restart") {
            return .restart
        }

        // The reply itself.
        let verb = has("play", "read", "hear", "tell", "give", "say")
        let summaryWord = has("summary", "summarized", "summarised", "summarize", "summarise", "summarizing")
        let shortWord = summaryWord || has("short", "shorter", "shortened", "brief", "briefly", "tldr", "condensed")
        let noun = has("response", "reply", "message", "answer", "result", "output")
        let ordinal = has("last", "latest", "recent", "newest")
        let switching = said("switch to")
        let playsReply = (noun && (verb || ordinal || shortWord))
            || (verb && summaryWord)
            || (summaryWord && w.count <= 4)
            || (verb && said("from") && !noun && w.count > 2)
            || switching
        if playsReply {
            return .play(summary: shortWord && !switching, project: project(in: w))
        }

        // Transport. Short utterances only: a long sentence that happens to contain "stop" is chatter.
        guard w.count <= 6 else { return nil }
        if has("stop", "quiet", "silence") { return .stop }
        if has("pause") { return .pause }
        if has("resume", "continue", "unpause", "carry") || said("keep going", "go on")
            || (has("play") && w.count <= 2) { return .resume }
        if has("again", "repeat") { return .restart }
        if has("forward", "ahead") { return .forward(count(in: w, after: ["forward", "ahead"])) }
        if has("skip") {
            return w.contains { Int($0) != nil } ? .forward(count(in: w, after: ["skip"])) : .next
        }
        if has("next") { return .next }
        if has("previous", "prev") { return .previous }
        if has("back", "rewind") { return .back(count(in: w, after: ["back", "rewind"])) }
        return nil
    }

    /// "back 3" -> 3. A recognizer writing "back to" for "back two" counts as 2. Default 1.
    private static func count(in w: [String], after keys: Set<String>) -> Int {
        guard let i = w.firstIndex(where: keys.contains) else { return 1 }
        for token in w[(i + 1)...] {
            if let n = Int(token) { return max(1, min(999, n)) }
            if token == "to" || token == "too" { return 2 }
        }
        return 1
    }

    private static let projectFillers: Set<String> = [
        "the", "my", "a", "session", "project", "please", "me", "us", "you", "it", "this", "that", "now",
        "last", "latest", "newest", "recent", "current", "one", "to",
    ]
    private static let summaryMarkers: Set<String> = [
        "summary", "summarized", "summarised", "summarize", "summarise", "short", "shorter", "shortened",
        "brief", "briefly", "tldr", "condensed", "please",
    ]

    /// "play last response from claude voice summarized" -> "claude voice";
    /// "switch to api" -> "api". nil when no project is named.
    static func project(in w: [String]) -> String? {
        var start: Int?
        if let s = w.firstIndex(of: "switch"), s + 1 < w.count, w[s + 1] == "to" {
            start = s + 2
        } else if let m = w.indices.first(where: { $0 >= 1 && ["from", "of", "for"].contains(w[$0]) }) {
            start = m + 1
        }
        guard let start, start < w.count else { return nil }
        var tail: [String] = []
        for token in w[start...] {
            if summaryMarkers.contains(token) { break }
            tail.append(token)
        }
        let name = tail.filter { !projectFillers.contains($0) }
        return name.isEmpty ? nil : name.joined(separator: " ")
    }
}

/// Decides when a growing transcript becomes a command. Speech recognition reports partial text
/// without saying when the speaker is done, so a command runs once the text after the wake phrase
/// has stopped changing for `settle` seconds.
///
/// The caller feeds every partial result to `hear` and calls `tick` about three times a second.
/// After `execute`, `notUnderstood` or `expired` it must start a fresh recognition and call `reset()`.
struct WakeGate {
    enum Action: Equatable {
        case none
        /// The wake phrase was just heard (once per recognition). `alone`: nothing followed it yet, so
        /// the command is still to come. The listener pauses playback so the user can be heard.
        case wake(alone: Bool)
        case execute(VoiceIntent)
        case notUnderstood            // said to us, but no known command
        case expired                  // armed by a lone wake phrase, then nothing came
    }

    var requireWake: Bool
    var settle: TimeInterval
    var armWindow: TimeInterval
    /// Without a wake phrase, longer utterances are conversation, not commands.
    var maxWordsWithoutWake = 10

    private(set) var armedUntil: Date?
    private var rest: [String]?       // words that count as the command, nil = not addressed to us
    private var woke = false
    private var chimed = false
    private var changedAt = Date.distantPast

    init(requireWake: Bool = true, settle: TimeInterval = 1.0, armWindow: TimeInterval = 6) {
        self.requireWake = requireWake
        self.settle = settle
        self.armWindow = armWindow
    }

    var isArmed: Bool { armedUntil != nil }

    mutating func reset() {
        armedUntil = nil
        rest = nil
        woke = false
        chimed = false
        changedAt = .distantPast
    }

    mutating func hear(_ transcript: String, now: Date) -> Action {
        let w = VoiceGrammar.normalize(transcript)
        var words: [String]?
        let end = VoiceGrammar.wakeEnd(in: w)
        woke = end != nil
        if let end {
            words = Array(w[end...])
        } else if armedUntil != nil || !requireWake {
            words = w
        }
        if words != rest { changedAt = now }
        rest = words

        guard let words else { return .none }
        if woke, words.isEmpty, armedUntil == nil { armedUntil = now.addingTimeInterval(armWindow) }
        if woke, !chimed {
            chimed = true
            return .wake(alone: words.isEmpty)
        }
        return .none
    }

    mutating func tick(now: Date) -> Action {
        if let words = rest, !words.isEmpty {
            guard now.timeIntervalSince(changedAt) >= settle else { return .none }
            let addressed = woke || armedUntil != nil
            if !addressed, words.count > maxWordsWithoutWake { return .none }
            if let intent = VoiceGrammar.parse(words: words) {
                reset()
                return .execute(intent)
            }
            guard addressed else { return .none }   // chatter: ignore, the caller restarts on silence
            reset()
            return .notUnderstood
        }
        if let until = armedUntil, now >= until {
            reset()
            return .expired
        }
        return .none
    }
}

/// Our own voice leaking into the microphone must not count as a command.
enum EchoFilter {
    /// True when the last words said (2 to 4 of them) are a stretch of the text being read aloud:
    /// a reply that contains "hey Claude" must not pause itself.
    static func isTailEcho(_ transcript: String, spoken: [String]) -> Bool {
        let t = VoiceGrammar.normalize(transcript)
        guard t.count >= 2 else { return false }
        let tail = t.suffix(4)
        let said = " " + spoken.flatMap(VoiceGrammar.normalize).joined(separator: " ") + " "
        return said.contains(" " + tail.joined(separator: " ") + " ")
    }

    /// True when `transcript` (3+ words) is a stretch of the text being read aloud.
    static func isEcho(_ transcript: String, spoken: [String]) -> Bool {
        let t = VoiceGrammar.normalize(transcript)
        guard t.count >= 3 else { return false }
        let said = " " + spoken.flatMap(VoiceGrammar.normalize).joined(separator: " ") + " "
        return said.contains(" " + t.joined(separator: " ") + " ")
    }
}
