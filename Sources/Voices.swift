import AVFoundation
import Foundation
import NaturalLanguage

/// Languages offered for summaries (Romanian by default).
enum Languages {
    struct Lang: Hashable { let code: String; let name: String; let native: String; let sample: String }

    static let all: [Lang] = [
        Lang(code: "ro-RO", name: "Romanian", native: "Română", sample: "Așa voi citi răspunsurile în limba română."),
        Lang(code: "en-US", name: "English", native: "English", sample: "This is how I will read replies in English."),
        Lang(code: "fr-FR", name: "French", native: "Français", sample: "Voici comment je vais lire les réponses en français."),
        Lang(code: "de-DE", name: "German", native: "Deutsch", sample: "So werde ich die Antworten auf Deutsch vorlesen."),
        Lang(code: "es-ES", name: "Spanish", native: "Español", sample: "Así leeré las respuestas en español."),
        Lang(code: "it-IT", name: "Italian", native: "Italiano", sample: "Così leggerò le risposte in italiano."),
        Lang(code: "pt-PT", name: "Portuguese", native: "Português", sample: "É assim que vou ler as respostas em português."),
        Lang(code: "nl-NL", name: "Dutch", native: "Nederlands", sample: "Zo lees ik de antwoorden voor in het Nederlands."),
        Lang(code: "pl-PL", name: "Polish", native: "Polski", sample: "Tak będę czytać odpowiedzi po polsku."),
        Lang(code: "hu-HU", name: "Hungarian", native: "Magyar", sample: "Így fogom felolvasni a válaszokat magyarul."),
    ]

    static var selected: Lang {
        let code = UserDefaults.standard.string(forKey: "summaryLang") ?? "ro-RO"
        return all.first { $0.code == code } ?? all[0]
    }

    static func lang(_ code: String) -> Lang { all.first { $0.code == code } ?? all[0] }
}

enum Settings {
    static var rate: Float {
        let r = UserDefaults.standard.double(forKey: "rate")
        return r == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(r)
    }

    /// The speed slider as a multiplier (1 = normal), for engines that are not Apple's.
    static var speed: Double { Double(rate) / Double(AVSpeechUtteranceDefaultSpeechRate) }
}

/// Where a voice comes from.
enum Engine: String {
    case apple, edge, piper

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .edge: return "Microsoft"
        case .piper: return "Piper"
        }
    }
}

/// A voice from any engine, as listed in Settings. `id` is what Settings stores:
/// an Apple voice identifier, "edge:<ShortName>" or "piper:<model name>".
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let engine: Engine
    let label: String
    let language: String    // BCP-47, like "ro-RO"
    let rank: Int           // higher sorts first; the automatic choice skips online voices
    var online: Bool { engine == .edge }
}

/// A voice made by Piper or edge-tts outside the app.
struct ExternalVoice: Hashable {
    let engine: Engine
    let name: String        // edge-tts ShortName, or the Piper model's path
    let language: String
}

/// What to speak a sentence with.
enum VoiceRef {
    case apple(AVSpeechSynthesisVoice?)
    case external(ExternalVoice)
}

enum Voices {
    /// Installed Apple voices, best quality first, novelty voices removed.
    static let apple: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        .sorted {
            $0.quality.rawValue != $1.quality.rawValue
                ? $0.quality.rawValue > $1.quality.rawValue
                : $0.name < $1.name
        }

    /// Evan (Enhanced) if installed, else the best US English voice.
    static let preferred: AVSpeechSynthesisVoice? =
        apple.first { $0.name.hasPrefix("Evan") && $0.quality != .default }
        ?? apple.first { $0.language == "en-US" && $0.quality != .default }
        ?? AVSpeechSynthesisVoice(language: "en-US")

    // MARK: listing

    /// Every voice for a language prefix like "ro" (nil = all languages), best first.
    static func options(language prefix: String? = nil) -> [VoiceOption] {
        let c = VoiceCatalog.shared
        let all = apple.map(option) + c.piper + c.edge
        let list = prefix.map { p in all.filter { $0.language.hasPrefix(p) } } ?? all
        return list.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.label < $1.label }
    }

    static func option(_ v: AVSpeechSynthesisVoice) -> VoiceOption {
        let rank: Int
        switch v.quality {
        case .premium: rank = 30
        case .enhanced: rank = 10
        default: rank = 0
        }
        return VoiceOption(id: v.identifier, engine: .apple, label: label(v), language: v.language, rank: rank)
    }

    /// The listed voice with this id, or a placeholder for one that is gone.
    static func option(id: String) -> VoiceOption {
        if let o = options().first(where: { $0.id == id }) { return o }
        let engine: Engine = id.hasPrefix("edge:") ? .edge : id.hasPrefix("piper:") ? .piper : .apple
        let name = engine == .apple ? id : String(id.drop { $0 != ":" }.dropFirst())
        return VoiceOption(id: id, engine: engine, label: "\(name) (not installed)",
                           language: language(of: id) ?? "", rank: -1)
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        if v.name.contains("(") { return v.name }   // macOS names already say "(Enhanced)"
        switch v.quality {
        case .premium: return "\(v.name) (Premium)"
        case .enhanced: return "\(v.name) (Enhanced)"
        default: return v.name
        }
    }

    // MARK: choosing

    /// The voice for full text, as stored in Settings.
    static var mainID: String {
        let id = UserDefaults.standard.string(forKey: "voiceID") ?? ""
        return id.isEmpty ? (preferred?.identifier ?? "") : id
    }

    /// The voice picked in Settings for a language, else the best offline voice installed for it.
    static func id(forLanguage lang: String) -> String? {
        let p = String(lang.prefix(2))
        if let id = UserDefaults.standard.string(forKey: "voice.\(p)"), !id.isEmpty { return id }
        return automatic(p)?.id
    }

    /// Best offline voice for a language prefix. Online voices are only used when picked.
    static func automatic(_ prefix: String) -> VoiceOption? {
        options(language: prefix).first { !$0.online }
    }

    /// Voice used for summaries.
    static func summaryVoiceID() -> String? { id(forLanguage: Languages.selected.code) }

    /// Voice for a full reply: the main voice, unless the reply is written in another language
    /// that has a voice ("Read each reply in its own language" in Settings).
    static func replyVoiceID(for text: String) -> String? {
        guard UserDefaults.standard.object(forKey: "matchLanguage") as? Bool ?? true,
              let lang = detectLanguage(text) else { return nil }
        let main = language(of: mainID) ?? "en"
        guard !main.hasPrefix(lang) else { return nil }
        return id(forLanguage: lang)
    }

    /// Two-letter code of the language a text is written in, when it is clear.
    static func detectLanguage(_ text: String) -> String? {
        guard text.split(whereSeparator: \.isWhitespace).count >= 8 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(4000)))
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.6 else { return nil }
        return String(lang.rawValue.prefix(2))
    }

    /// Earlier versions stored one voice for the summary language only.
    static func migrate() {
        let d = UserDefaults.standard
        guard let old = d.string(forKey: "summaryVoiceID") else { return }
        let key = "voice.\(Languages.selected.code.prefix(2))"
        if !old.isEmpty, d.string(forKey: key) == nil { d.set(old, forKey: key) }
        d.removeObject(forKey: "summaryVoiceID")
    }

    // MARK: resolving

    /// What `id` speaks with right now (nil = the main voice). A voice whose engine is not
    /// installed, or is failing, falls back to the best Apple voice for the same language.
    static func resolve(_ id: String?) -> VoiceRef {
        let id = id.flatMap { $0.isEmpty ? nil : $0 } ?? mainID
        guard let ext = external(id) else { return .apple(appleVoice(id) ?? mainApple) }
        if VoiceCatalog.shared.isReady(ext), !ExternalTTS.shared.isFailing(ext.engine) { return .external(ext) }
        return .apple(bestApple(for: ext.language) ?? mainApple)
    }

    static func external(_ id: String) -> ExternalVoice? {
        if id.hasPrefix("edge:") {
            let name = String(id.dropFirst(5))
            return ExternalVoice(engine: .edge, name: name, language: language(of: id) ?? "")
        }
        if id.hasPrefix("piper:") {
            let path = VoiceCatalog.piperDir.appendingPathComponent("\(id.dropFirst(6)).onnx").path
            return ExternalVoice(engine: .piper, name: path, language: language(of: id) ?? "")
        }
        return nil
    }

    /// BCP-47 language of a voice id ("ro-RO").
    static func language(of id: String) -> String? {
        if id.hasPrefix("edge:") {   // "ro-RO-AlinaNeural"
            let parts = id.dropFirst(5).split(separator: "-")
            return parts.count >= 3 ? "\(parts[0])-\(parts[1])" : nil
        }
        if id.hasPrefix("piper:") {  // "ro_RO-mihai-medium"
            return id.dropFirst(6).split(separator: "-").first.map { $0.replacingOccurrences(of: "_", with: "-") }
        }
        return appleVoice(id)?.language
    }

    /// The Apple voice behind the main voice (or standing in for it).
    static var mainApple: AVSpeechSynthesisVoice? {
        let id = mainID
        if external(id) == nil { return appleVoice(id) ?? preferred }
        return bestApple(for: language(of: id) ?? "en-US") ?? preferred
    }

    /// Best installed Apple voice for a language code like "ro-RO" (matches on "ro").
    static func bestApple(for lang: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(lang.prefix(2))
        return apple.first { $0.language == lang } ?? apple.first { $0.language.hasPrefix(prefix) }
    }

    private static var cache: [String: AVSpeechSynthesisVoice] = [:]

    private static func appleVoice(_ id: String) -> AVSpeechSynthesisVoice? {
        if let v = cache[id] { return v }
        let v = AVSpeechSynthesisVoice(identifier: id)
        if let v { cache[id] = v }
        return v
    }
}

/// Voices from outside macOS found on this Mac: Piper models in ~/.claude/tts/piper and
/// Microsoft neural voices (through the edge-tts tool). See scripts/install-voices.sh.
final class VoiceCatalog: ObservableObject {
    static let shared = VoiceCatalog()

    static let piperDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/tts/piper")
    private static let edgeList = ExternalTTS.cacheDir.appendingPathComponent("edge-voices.json")

    @Published private(set) var piper: [VoiceOption] = []
    @Published private(set) var edge: [VoiceOption] = []
    /// The Python interpreter that runs each installed engine.
    @Published private(set) var python: [Engine: String] = [:]
    @Published private(set) var scanning = false

    func isReady(_ v: ExternalVoice) -> Bool {
        guard python[v.engine] != nil else { return false }
        return v.engine != .piper || FileManager.default.fileExists(atPath: v.name)
    }

    /// Look for the engines and their voices again (in the background).
    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            var py: [Engine: String] = [:]
            py[.edge] = Tools.python(tool: "edge-tts", module: "edge_tts")
            py[.piper] = Tools.python(tool: "piper", module: "piper")
            let models = Self.scanPiper()
            DispatchQueue.main.async {
                self.python = py
                self.piper = models
                self.scanning = false
                if py[.edge] != nil { self.loadEdge() } else { self.edge = [] }
            }
        }
    }

    private static func scanPiper() -> [VoiceOption] {
        let files = (try? FileManager.default.contentsOfDirectory(at: piperDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "onnx" }.compactMap { f in
            let name = f.deletingPathExtension().lastPathComponent        // ro_RO-mihai-medium
            let json = f.appendingPathExtension("json")
            guard let data = try? Data(contentsOf: json),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let code = ((o["language"] as? [String: Any])?["code"] as? String)
                ?? String(name.split(separator: "-").first ?? "")
            let parts = name.split(separator: "-")
            let speaker = parts.count >= 2 ? String(parts[1]) : name
            let quality = ((o["audio"] as? [String: Any])?["quality"] as? String) ?? ""
            return VoiceOption(id: "piper:\(name)", engine: .piper,
                               label: "\(speaker.capitalized) · Piper \(quality), offline",
                               language: code.replacingOccurrences(of: "_", with: "-"), rank: 20)
        }
    }

    /// Microsoft's voice list, cached for a week.
    private func loadEdge() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: Self.edgeList.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86400,
           let data = try? Data(contentsOf: Self.edgeList),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            edge = Self.edgeOptions(list)
            return
        }
        ExternalTTS.shared.listEdgeVoices { [weak self] list in
            guard let self else { return }
            if let list {
                try? fm.createDirectory(at: ExternalTTS.cacheDir, withIntermediateDirectories: true)
                if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: Self.edgeList) }
                self.edge = Self.edgeOptions(list)
            } else {
                // Offline on first use: the Romanian and US English voices are always there.
                self.edge = Self.edgeOptions([
                    ["name": "ro-RO-AlinaNeural", "locale": "ro-RO", "gender": "Female"],
                    ["name": "ro-RO-EmilNeural", "locale": "ro-RO", "gender": "Male"],
                    ["name": "en-US-AriaNeural", "locale": "en-US", "gender": "Female"],
                    ["name": "en-US-GuyNeural", "locale": "en-US", "gender": "Male"],
                ])
            }
        }
    }

    private static func edgeOptions(_ list: [[String: String]]) -> [VoiceOption] {
        list.compactMap { v in
            guard let name = v["name"], let locale = v["locale"] else { return nil }
            var short = name.hasPrefix(locale + "-") ? String(name.dropFirst(locale.count + 1)) : name
            if short.hasSuffix("Neural") { short = String(short.dropLast(6)) }
            // "AndrewMultilingual" -> "Andrew Multilingual"
            short = short.replacingOccurrences(of: #"(?<=[a-z])(?=[A-Z])"#, with: " ", options: .regularExpression)
            return VoiceOption(id: "edge:\(name)", engine: .edge, label: "\(short) · Microsoft, online",
                               language: locale, rank: 25)
        }
    }
}

/// Finds command-line tools; apps opened from Finder get a minimal PATH.
enum Tools {
    static let path = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func find(_ name: String) -> String? {
        for dir in ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return shell("command -v \(name)")
    }

    /// The Python interpreter a Python command-line tool runs with, if it can import `module`.
    static func python(tool: String, module: String) -> String? {
        guard var path = find(tool) else { return nil }
        if path.contains("/.pyenv/shims/"), let real = shell("pyenv which \(tool)") { path = real }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let h = FileHandle(forReadingAtPath: file) else { return nil }
        let head = String(decoding: h.readData(ofLength: 512), as: UTF8.self)
        try? h.close()
        guard let r = head.range(of: #"/[^\s"']*python[0-9.]*"#, options: .regularExpression) else { return nil }
        let py = String(head[r])
        return run(py, ["-I", "-c", "import \(module)"]) ? py : nil
    }

    /// Output of a login-shell command, when it is an absolute path.
    private static func shell(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("/") ? s : nil
    }

    private static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
