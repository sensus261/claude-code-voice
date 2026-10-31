import AppKit
import Foundation

/// Spoken summaries, made only on explicit request, both through the user's Claude
/// subscription (claude.ai login of the `claude` CLI):
///  - quick:   `claude -p --model haiku` on the reply text alone (low cost)
///  - session: `claude -p --resume <sid> --fork-session` so the session's own model
///             summarizes with full context, reusing its prompt cache
/// Cached per reply in ~/.claude/tts/state/summaries/<sid>.<mode>.json.
@MainActor
final class Summarizer: ObservableObject {
    @Published private(set) var working: Set<String> = []   // "sid|mode"
    @Published private(set) var lastError: String?

    private var tasks: [String: Task<String?, Never>] = [:]
    static let dir = Paths.base.appendingPathComponent("summaries")
    /// Bump when the prompts change, so older cached summaries are made again.
    static let promptVersion = 3

    func isWorking(_ sid: String, _ mode: ReadMode) -> Bool { working.contains("\(sid)|\(mode.rawValue)") }

    func cached(_ s: Session, _ mode: ReadMode) -> String? { entry(s, mode)?["text"] as? String }

    /// Details saved with a session summary (tokens re-read), for display.
    func cachedInfo(_ s: Session, _ mode: ReadMode) -> [String: Any]? { entry(s, mode) }

    private func entry(_ s: Session, _ mode: ReadMode) -> [String: Any]? {
        guard mode != .full,
              let data = try? Data(contentsOf: file(s.id, mode)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = obj["source"] as? Double, abs(source - s.modified.timeIntervalSince1970) < 0.001,
              obj["lang"] as? String == Languages.selected.code,
              obj["v"] as? Int == Self.promptVersion,
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return obj
    }

    /// Summary of the session's current reply in the selected language; nil on failure.
    func summary(for s: Session, _ mode: ReadMode) async -> String? {
        guard mode != .full else { return nil }
        if let c = cached(s, mode) { return c }
        let lang = Languages.selected
        let key = "\(s.id)|\(mode.rawValue)"
        if let t = tasks[key] { return await t.value }

        let source = Self.source(for: s)
        let info = mode == .session ? SessionInfo.of(s) : nil
        if mode == .session && info == nil {
            lastError = "this session's log was not found"
            return nil
        }
        working.insert(key)
        let t = Task<String?, Never> {
            var result = await Task.detached(priority: .userInitiated) { () -> Result<ClaudeCLI.Output, SummaryError> in
                mode == .quick ? ClaudeCLI.quick(source, lang: lang) : ClaudeCLI.session(info!, reply: source, lang: lang)
            }.value
            // One cheap repair pass if the text is too long or not fully in the language.
            if case .success(let out) = result {
                let problems = SpeechCheck.problems(out.text, lang: lang, limit: summaryWordLimit(source))
                if !problems.isEmpty,
                   case .success(let fixed) = await Task.detached(priority: .userInitiated, operation: {
                       ClaudeCLI.repair(out.text, lang: lang, problems: problems)
                   }).value {
                    result = .success(ClaudeCLI.Output(text: fixed.text, cacheRead: out.cacheRead, cacheWrite: out.cacheWrite))
                }
            }
            self.tasks[key] = nil
            self.working.remove(key)
            switch result {
            case .success(let out):
                self.lastError = nil
                self.save(out, for: s, mode, lang)
                return out.text
            case .failure(let e):
                self.lastError = e.message
                return nil
            }
        }
        tasks[key] = t
        return await t.value
    }

    func clearError() { lastError = nil }

    private func file(_ sid: String, _ mode: ReadMode) -> URL {
        Self.dir.appendingPathComponent("\(sid).\(mode.rawValue).json")
    }

    private func save(_ out: ClaudeCLI.Output, for s: Session, _ mode: ReadMode, _ lang: Languages.Lang) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["source": s.modified.timeIntervalSince1970, "lang": lang.code,
                                  "v": Self.promptVersion, "text": out.text]
        if let r = out.cacheRead { obj["cacheRead"] = r }
        if let w = out.cacheWrite { obj["cacheWrite"] = w }
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: file(s.id, mode), options: .atomic)
        }
    }

    /// Raw markdown when the hook saved it, else the cleaned text.
    static func source(for s: Session) -> String {
        let md = Paths.replies.appendingPathComponent("\(s.id).md")
        if let raw = try? String(contentsOf: md, encoding: .utf8), !raw.isEmpty { return raw }
        return s.text
    }
}

/// What the session's transcript says: where it runs, its model, context size, last activity.
struct SessionInfo {
    let sid: String
    let transcript: URL
    let cwd: String
    let model: String?
    let contextTokens: Int
    let lastActivity: Date

    /// Cache lifetime on a subscription is about an hour.
    var cacheLikelyWarm: Bool { Date().timeIntervalSince(lastActivity) < 55 * 60 }

    static func of(_ s: Session) -> SessionInfo? {
        guard let t = Transcript.url(for: s.id) else { return nil }
        let mod = (try? t.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        var cwd = ""
        if let h = try? FileHandle(forReadingFrom: t) {           // launch folder: first entry with a cwd
            let head = String(decoding: h.readData(ofLength: 256 * 1024), as: UTF8.self)
            try? h.close()
            for line in head.split(separator: "\n") {
                if let o = Transcript.json(line), let c = o["cwd"] as? String { cwd = c; break }
            }
        }
        guard !cwd.isEmpty else { return nil }
        let usage = Transcript.lastUsage(t)
        return SessionInfo(sid: s.id, transcript: t, cwd: cwd, model: usage?.model,
                           contextTokens: usage?.tokens ?? 0, lastActivity: mod)
    }
}

struct SummaryError: Error {
    let message: String
}

enum ClaudeCLI {
    struct Output {
        let text: String
        var cacheRead: Int?
        var cacheWrite: Int?
    }

    static let path: String? = {
        let home = NSHomeDirectory()
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                  "\(home)/.claude/local/claude"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // GUI apps get a minimal PATH: ask a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return found.hasPrefix("/") ? found : nil
    }()

    /// Shared by both summary kinds: the text-to-speech voice only speaks one language well.
    static let languageRule = """
        Write entirely in the given language, the way a native speaker would say it aloud. Translate \
        technical terms into natural words of that language (in Romanian, for example: "tichetul" or \
        "sarcina" for issue, "modificarea" for commit, "documentul de cerințe" for PRD, "cererea de \
        integrare" for pull request). Never use an English word with the language's endings attached \
        (never "issue-ul", "commit-ul", "PR-ul", "deploy-ul"), and never leave English terms or \
        abbreviations in. Leave out file names, paths and code identifiers; say what they are instead. \
        Product and company names may stay, in sentences that need no endings on them. Keep the exact \
        numbers.
        """

    // MARK: low cost (Haiku, reply text only)

    static let quickPrompt = """
        You write the spoken version of a coding assistant's reply. Text-to-speech reads it to the \
        developer, who is away from the screen and wants the gist fast.

        Rules:
        - \(ClaudeCLI.languageRule)
        - Stay within the word limit given with the reply. It is a hard limit. Pick only what matters \
        most: the outcome, anything that failed or is at risk, and anything the developer must do or \
        decide. Drop explanations, reasoning, alternatives and lists of details.
        - Plain spoken sentences only: no markdown, lists, headings, emoji, symbols, code, URLs, paths \
        or file names. Describe code and files by what they do.
        - Start with the outcome: what was done, found or decided.
        - Never soften a failure, guess, or add anything not in the reply.
        - If the reply asks a question or needs a decision, end with it.
        - First person, as the assistant ("I fixed...").
        - Output only the spoken text.
        """

    // No hooks (no loop through the Stop hook), no memory/CLAUDE.md/connectors, no thinking.
    static let quickSettings = #"{"disableAllHooks":true,"alwaysThinkingEnabled":false,"autoMemoryEnabled":false,"disableClaudeAiConnectors":true,"claudeMdExcludes":["**/CLAUDE.md","**/CLAUDE.local.md"]}"#

    static func quick(_ source: String, lang: Languages.Lang) -> Result<Output, SummaryError> {
        let limit = summaryWordLimit(source)
        let input = "Language: \(lang.name)\nWord limit: \(limit)\n<reply>\n\(source.prefix(24_000))\n</reply>\n"
            + "Write the spoken summary now: at most \(limit) words, entirely in \(lang.name), with no English "
            + "words, abbreviations or file names.\n"
        // Pinned: Haiku 5.5 is the cheapest Haiku ($0.10/$0.50 per MTok; Haiku 4.5 is $1/$5).
        return run(["-p", "--model", "claude-haiku-5-5", "--no-session-persistence", "--tools", "",
                    "--strict-mcp-config", "--disable-slash-commands",
                    "--system-prompt", quickPrompt, "--settings", quickSettings],
                   stdin: input, cwd: Paths.base, timeout: 60, json: false)
    }

    // MARK: repair (Haiku, fixes only what SpeechCheck found)

    static let repairPrompt = """
        You fix a short text that text-to-speech will read aloud in the given language. Apply every fix \
        listed. Keep the meaning, the facts and the exact numbers, and add nothing. Write entirely in the \
        given language with natural words: no English words, abbreviations, file names or symbols (names of \
        products and companies may stay). Output only the corrected text.
        """

    static func repair(_ text: String, lang: Languages.Lang, problems: [String]) -> Result<Output, SummaryError> {
        let input = "Language: \(lang.name)\n<text>\n\(text)\n</text>\nFixes:\n- "
            + problems.joined(separator: "\n- ") + "\n"
        return run(["-p", "--model", "claude-haiku-5-5", "--no-session-persistence", "--tools", "",
                    "--strict-mcp-config", "--disable-slash-commands",
                    "--system-prompt", repairPrompt, "--settings", quickSettings],
                   stdin: input, cwd: Paths.base, timeout: 60, json: false)
    }

    // MARK: session (fork of the session itself, full context, warm cache)

    static func session(_ info: SessionInfo, reply: String, lang: Languages.Lang) -> Result<Output, SummaryError> {
        let opening = reply.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
        let request = """
            Voice summary request from my text-to-speech app. Write the spoken version of your most recent \
            reply before this message (it begins: "\(opening)"). Rules: the language is \(lang.name). \
            \(languageRule) At most \(summaryWordLimit(reply)) words; full natural sentences, not terse; no \
            markdown, lists, symbols or code; start with the outcome; never add anything that is not in that \
            reply; if it asked me something or needs my decision, end with that. Do not use any tools. Output \
            only the spoken text.
            """
        // Same model and tools as the session so the request matches its prompt cache.
        var args = ["-p", "--resume", info.sid, "--fork-session", "--no-session-persistence",
                    "--settings", #"{"disableAllHooks":true}"#, "--output-format", "json"]
        if let m = info.model { args += ["--model", m] }
        args.append(request)
        return run(args, stdin: nil, cwd: URL(fileURLWithPath: info.cwd), timeout: 180, json: true)
    }

    // MARK: process

    private static func run(_ args: [String], stdin input: String?, cwd: URL, timeout: Double,
                            json: Bool) -> Result<Output, SummaryError> {
        guard let exe = path else { return .failure(.init(message: "claude command not found")) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_VOICE_SUMMARY"] = "1"    // the Stop hook ignores runs with this set
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "ANTHROPIC_API_KEY")   // always the subscription login, never API billing
        p.environment = env

        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-voice-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        p.standardOutput = outPipe
        p.standardError = try? FileHandle(forWritingTo: errURL)

        do { try p.run() } catch {
            return .failure(.init(message: "could not start claude: \(error.localizedDescription)"))
        }
        if let input {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                writer.write(Data(input.utf8))
                try? writer.close()
            }
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()

        var text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = Output(text: "")
        if json, let o = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
            if o["is_error"] as? Bool == true {
                return .failure(.init(message: (o["result"] as? String) ?? "claude reported an error"))
            }
            text = (o["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = o["usage"] as? [String: Any] {
                result.cacheRead = u["cache_read_input_tokens"] as? Int
                result.cacheWrite = u["cache_creation_input_tokens"] as? Int
            }
        }
        guard p.terminationStatus == 0, !text.isEmpty else {
            if p.terminationReason == .uncaughtSignal { return .failure(.init(message: "timed out")) }
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let first = (err + "\n" + text).split(whereSeparator: \.isNewline).first.map(String.init)
            return .failure(.init(message: first ?? "claude exited with \(p.terminationStatus)"))
        }
        return .success(Output(text: plain(text), cacheRead: result.cacheRead, cacheWrite: result.cacheWrite))
    }

    /// Strip any markdown that slipped through.
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*• ")) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Finds what the voice would stumble over: too many words, English words with native endings
/// ("issue-ul"), file names, abbreviations, and words the system dictionary of the language rejects.
@MainActor
enum SpeechCheck {
    private static let inflectedEnglish = try! NSRegularExpression(   // Romanian endings on a foreign stem
        pattern: #"\b\p{L}{3,}-(?:ul|ului|ii|iul|uri|urile|urilor|lui|le|a|ei|lor|ilor)\b"#)
    private static let fileName = try! NSRegularExpression(
        pattern: #"\b[\w-]+\.(?:md|ts|tsx|js|py|swift|json|ya?ml|sh|txt|toml|rb|go|rs|html|css)\b"#)
    private static let abbreviation = try! NSRegularExpression(pattern: #"\b[A-Z]{2,}\b"#)
    private static let word = try! NSRegularExpression(pattern: #"\p{L}+(?:-\p{L}+)*"#)

    static func problems(_ text: String, lang: Languages.Lang, limit: Int) -> [String] {
        var out: [String] = []
        let count = text.split(whereSeparator: \.isWhitespace).count
        if count > limit + max(10, limit / 4) {
            out.append("It has \(count) words. Shorten it to at most \(limit) words: keep the outcome, "
                + "failures and any question for the developer; drop details.")
        }
        guard !lang.code.hasPrefix("en") else { return out }

        var bad = Set<String>()
        var patterns = [fileName, abbreviation]
        if lang.code.hasPrefix("ro") { patterns.append(inflectedEnglish) }
        for re in patterns { bad.formUnion(matches(re, text)) }
        bad.formUnion(unknownWords(text, lang: String(lang.code.prefix(2))))
        if !bad.isEmpty {
            out.append("Replace these with natural \(lang.name) words, or rephrase without them: "
                + bad.sorted().joined(separator: ", ") + ".")
        }
        return out
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// Words the system dictionary for the language rejects. Capitalized words inside a
    /// sentence are treated as names and skipped.
    private static func unknownWords(_ text: String, lang: String) -> [String] {
        let sc = NSSpellChecker.shared
        guard sc.availableLanguages.contains(where: { $0.hasPrefix(lang) }) else { return [] }
        let auto = sc.automaticallyIdentifiesLanguages
        sc.automaticallyIdentifiesLanguages = false
        defer { sc.automaticallyIdentifiesLanguages = auto }

        let ns = text as NSString
        var out: [String] = []
        for m in word.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let w = ns.substring(with: m.range)
            guard w.count > 2 else { continue }
            var candidate = w
            if w.first?.isUppercase == true {
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                let startsSentence = before.isEmpty || ".!?:".contains(before.last!)
                guard startsSentence else { continue }               // a name mid-sentence
                candidate = w.lowercased()
            }
            let r = sc.checkSpelling(of: candidate, startingAt: 0, language: lang, wrap: false,
                                     inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location != NSNotFound { out.append(w) }
        }
        return out
    }
}

/// Shared length rule for both summary kinds: about a fifth of the reply, 25 to 100 words.
func summaryWordLimit(_ source: String) -> Int {
    min(100, max(25, source.split(whereSeparator: \.isWhitespace).count / 5))
}
