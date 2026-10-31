import CryptoKit
import Foundation

/// Makes speech with engines that run outside the app: Piper (offline) and Microsoft neural
/// voices through edge-tts (online). One long-lived Python worker per engine turns a sentence
/// into an audio file, several at a time. Files are cached by engine, voice, speed and text, so
/// replays and prefetched sentences start at once. Completions run on the main thread.
final class ExternalTTS {
    static let shared = ExternalTTS()

    static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.claude-voice")
    private static let audioDir = cacheDir.appendingPathComponent("speech")
    private static let script = cacheDir.appendingPathComponent("tts_worker.py")

    struct Failure: Error { let message: String }
    typealias Done = (Result<URL, Failure>) -> Void

    private let q = DispatchQueue(label: "claude-voice.tts")
    private var workers: [Engine: Worker] = [:]      // q only
    private var waiting: [String: [Done]] = [:]      // q only: audio being made -> who wants it
    private var failingUntil: [Engine: Date] = [:]   // main only

    private init() {
        signal(SIGPIPE, SIG_IGN)   // a worker that died must not take the app with it
        q.async { Self.setUp() }
    }

    /// Audio for one sentence. `done` nil = prefetch only.
    func audio(_ text: String, voice: ExternalVoice, speed: Double, done: Done? = nil) {
        guard let python = VoiceCatalog.shared.python[voice.engine] else {
            done?(.failure(Failure(message: "not installed")))
            return
        }
        let (req, key, ext) = Self.request(text, voice, speed)
        let file = Self.audioDir.appendingPathComponent("\(key).\(ext)")
        q.async {
            if FileManager.default.fileExists(atPath: file.path) {
                if let done { DispatchQueue.main.async { done(.success(file)) } }
                return
            }
            if self.waiting[key] != nil {                 // already being made
                if let done { self.waiting[key]?.append(done) }
                return
            }
            self.waiting[key] = done.map { [$0] } ?? []
            let part = file.appendingPathExtension("part")
            var r = req
            r["out"] = part.path
            self.worker(voice.engine, python).send(r, timeout: voice.engine == .edge ? 30 : 60) { result in
                let outcome: Result<URL, Failure>
                switch result {
                case .success:
                    do {
                        try FileManager.default.moveItem(at: part, to: file)
                        outcome = .success(file)
                    } catch {
                        outcome = .failure(Failure(message: "no audio was written"))
                    }
                case .failure(let f):
                    try? FileManager.default.removeItem(at: part)
                    outcome = .failure(f)
                }
                let callers = self.waiting.removeValue(forKey: key) ?? []
                DispatchQueue.main.async {
                    if case .failure = outcome { self.failingUntil[voice.engine] = Date().addingTimeInterval(60) }
                    callers.forEach { $0(outcome) }
                }
            }
        }
    }

    /// After a failure an engine is skipped for a minute, so playback is not stuck waiting on it.
    func isFailing(_ e: Engine) -> Bool { (failingUntil[e] ?? .distantPast) > Date() }

    func clearFailures() { failingUntil = [:] }

    /// Every Microsoft voice (name, locale, gender), or nil when offline.
    func listEdgeVoices(done: @escaping ([[String: String]]?) -> Void) {
        guard let python = VoiceCatalog.shared.python[.edge] else { done(nil); return }
        q.async {
            self.worker(.edge, python).send(["op": "edge_list"], timeout: 30) { r in
                let list = (try? r.get())?["voices"] as? [[String: Any]]
                let out = list?.map { $0.compactMapValues { $0 as? String } }
                DispatchQueue.main.async { done(out) }
            }
        }
    }

    // MARK: private

    private func worker(_ e: Engine, _ python: String) -> Worker {
        if let w = workers[e], w.alive, w.python == python { return w }
        let w = Worker(python: python, script: Self.script, q: q)
        workers[e] = w
        return w
    }

    private static func request(_ text: String, _ v: ExternalVoice, _ speed: Double)
        -> (req: [String: Any], key: String, ext: String) {
        switch v.engine {
        case .edge:
            let pct = max(-50, min(100, Int(((speed - 1) * 100).rounded())))
            let rate = (pct >= 0 ? "+" : "") + "\(pct)%"
            return (["op": "edge", "voice": v.name, "text": text, "rate": rate],
                    key("edge|\(v.name)|\(rate)|\(text)"), "mp3")
        case .piper, .apple:
            let scale = (100 / max(0.3, speed)).rounded() / 100   // phoneme length: < 1 is faster
            return (["op": "piper", "model": v.name, "text": text, "length_scale": scale],
                    key("piper|\(v.name)|\(scale)|\(text)"), "wav")
        }
    }

    private static func key(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the worker script and drops audio made more than a week ago.
    private static func setUp() {
        let fm = FileManager.default
        try? fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? Data(workerScript.utf8).write(to: script)
        let old = Date().addingTimeInterval(-7 * 86400)
        for f in (try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let used = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if used < old || f.pathExtension == "part" { try? fm.removeItem(at: f) }
        }
    }

    /// One JSON request per stdin line, one JSON reply per stdout line, matched by "id".
    /// Requests run concurrently (Microsoft voices are network-bound); Piper voices stay loaded.
    private static let workerScript = #"""
        import asyncio, json, os, sys, threading, wave

        out = os.fdopen(os.dup(1), "w")   # replies only: anything a library prints goes to stderr
        os.dup2(2, 1)
        sys.stdout = sys.stderr
        voices = {}
        piper_lock = threading.Lock()

        def piper(req):
            from piper import PiperVoice, SynthesisConfig
            with piper_lock:
                v = voices.get(req["model"])
                if v is None:
                    v = voices[req["model"]] = PiperVoice.load(req["model"])
                with wave.open(req["out"], "wb") as w:
                    v.synthesize_wav(req["text"], w, syn_config=SynthesisConfig(length_scale=req.get("length_scale")))

        async def handle(req):
            op = req.get("op")
            if op == "piper":
                await asyncio.to_thread(piper, req)
            elif op == "edge":
                import edge_tts
                await edge_tts.Communicate(req["text"], req["voice"], rate=req.get("rate", "+0%")).save(req["out"])
            elif op == "edge_list":
                import edge_tts
                return {"voices": [{"name": v["ShortName"], "locale": v["Locale"], "gender": v.get("Gender", "")}
                                   for v in await edge_tts.list_voices()]}
            elif op != "ping":
                raise ValueError("unknown op %r" % op)
            return {}

        async def run(line):
            req = {}
            try:
                req = json.loads(line)
                res = {"ok": True, **(await handle(req))}
            except Exception as e:
                res = {"error": "%s: %s" % (type(e).__name__, e)}
            res["id"] = req.get("id")
            out.write(json.dumps(res) + "\n")
            out.flush()

        async def main():
            loop = asyncio.get_running_loop()
            tasks = set()
            while True:
                line = await loop.run_in_executor(None, sys.stdin.readline)
                if not line:
                    break
                t = asyncio.create_task(run(line))
                tasks.add(t)
                t.add_done_callback(tasks.discard)
            if tasks:
                await asyncio.wait(tasks)

        asyncio.run(main())
        """#
}

/// One Python worker process. All methods run on the shared queue `q`.
private final class Worker {
    typealias Reply = (Result<[String: Any], ExternalTTS.Failure>) -> Void

    let python: String
    private let process = Process()
    private let input: FileHandle
    private let q: DispatchQueue
    private var started = false
    private var buffer = Data()
    private var errors = ""
    private var pending: [Int: Reply] = [:]
    private var nextID = 1

    var alive: Bool { started && process.isRunning }

    init(python: String, script: URL, q: DispatchQueue) {
        self.python = python
        self.q = q
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        input = inPipe.fileHandleForWriting
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Tools.path
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            q.async { self?.received(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil }
            q.async {
                guard let self else { return }
                self.errors = String((self.errors + String(decoding: data, as: UTF8.self)).suffix(2000))
            }
        }
        process.terminationHandler = { [weak self] _ in
            q.async { self?.failAll() }
        }
        started = (try? process.run()) != nil
    }

    func send(_ req: [String: Any], timeout: Double, done: @escaping Reply) {
        guard alive else {
            done(.failure(.init(message: "could not start \(python)")))
            return
        }
        let id = nextID
        nextID += 1
        var r = req
        r["id"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: r) else {
            done(.failure(.init(message: "bad request")))
            return
        }
        pending[id] = done
        do {
            try input.write(contentsOf: data + Data("\n".utf8))
        } catch {
            pending[id] = nil
            done(.failure(.init(message: "the speech worker stopped")))
            return
        }
        q.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.pending.removeValue(forKey: id)?(.failure(.init(message: "timed out")))
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = o["id"] as? Int, let done = pending.removeValue(forKey: id) else { continue }
            if let err = o["error"] as? String {
                done(.failure(.init(message: err)))
            } else {
                done(.success(o))
            }
        }
    }

    /// The worker exited: fail everything still waiting, with its last error line.
    private func failAll() {
        let last = errors.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let msg = last.isEmpty ? "the speech worker stopped" : "the speech worker stopped: \(last.prefix(200))"
        let all = pending.values
        pending = [:]
        all.forEach { $0(.failure(.init(message: msg))) }
    }
}
