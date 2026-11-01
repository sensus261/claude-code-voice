// The spoken answer to a session: ReplyFlow rules (fake clock), ReplyCoordinator wiring (fake microphone,
// fake speech) and the waiter files. No audio, no Claude, nothing leaves the temp folder.
//   swiftc -swift-version 5 Sources/{VoiceIntent,ReplyFlow,ReplyCoordinator,Store}.swift tests/reply/main.swift -o build/replytest
//   build/replytest
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + name)
    if !ok { failed = true }
}

let t0 = Date(timeIntervalSince1970: 2_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

// MARK: ReplyFlow

print("flow")
do {
    var f = ReplyFlow()
    check("opens with a chime and dictation", f.open(sid: "s1", now: at(0)) == [.chime, .beginDictation])
    check("a second open while busy is ignored", f.open(sid: "s2", now: at(1)) == [])
    check("nothing heard yet: still listening", f.hear("", now: at(1)) == [] && f.phase != .idle)
    check("first words", f.hear("run the", now: at(2)) == [])
    check("more words", f.hear("run the tests again", now: at(3.5)) == [])
    check("not done while the text is still changing", f.tick(now: at(5)) == [])
    let say = f.tick(now: at(5.6))
    check("2 s of quiet: reads it back", say == [.say("Sending: run the tests again. Say send, or cancel.")])
    check("nothing happens while the read-back plays", f.tick(now: at(8)) == [])
    check("speech finished: listens for send", f.speechFinished(now: at(9)) == [.beginConfirm])
    check("an unclear word is ignored", f.hear("hmm", now: at(10)) == [])
    check("send delivers exactly this text", f.hear("send", now: at(11)) == [.deliver(sid: "s1", text: "run the tests again"), .ended(.sent)])
    check("and the flow is idle again", f.isIdle && f.sid == nil)
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    check("window not over at 29.9 s", f.tick(now: at(29.9)) == [])
    check("window over at 30 s: timed out, nothing said", f.tick(now: at(30)) == [.ended(.timedOut)] && f.isIdle)
}
do {
    var f = ReplyFlow()
    f.config.window = 12
    _ = f.open(sid: "s1", now: at(0))
    check("the window length is a setting", f.tick(now: at(11.9)) == [] && f.tick(now: at(12)) == [.ended(.timedOut)])
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("yes", now: at(1))
    _ = f.tick(now: at(3.1))
    _ = f.speechFinished(now: at(4))
    check("silence after the read-back cancels", f.tick(now: at(13.9)) == [])
    check("...at 10 s", f.tick(now: at(14)) == [.say("Not sent."), .ended(.cancelled)] && f.isIdle)
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("delete everything", now: at(1))
    _ = f.tick(now: at(3.1))
    _ = f.speechFinished(now: at(4))
    let out = f.hear("no don't send it", now: at(5))
    check("cancel sends nothing", out == [.say("Not sent."), .ended(.cancelled)] && !out.contains { if case .deliver = $0 { true } else { false } })
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("first try", now: at(1))
    _ = f.tick(now: at(3.1))
    _ = f.speechFinished(now: at(4))
    check("redo listens again", f.hear("try again", now: at(5)) == [.chime, .beginDictation])
    _ = f.hear("second try", now: at(6))
    _ = f.tick(now: at(8.1))
    _ = f.speechFinished(now: at(9))
    check("...and delivers the new text", f.hear("send", now: at(10)) == [.deliver(sid: "s1", text: "second try"), .ended(.sent)])
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("this is wrong", now: at(1))
    check("'cancel that' while dictating drops it", f.hear("cancel that", now: at(2)) == [.say("Cancelled."), .ended(.cancelled)])
    _ = f.open(sid: "s1", now: at(3))
    check("'no' can be an answer", f.hear("no", now: at(4)) == [] && f.tick(now: at(6.1)) == [.say("Sending: no. Say send, or cancel.")])
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    var words = "go"
    for i in 1...62 { words += " on"; _ = f.hear(words, now: at(Double(i))) }   // never stops talking
    let out = f.tick(now: at(61))
    check("a long answer is cut off at 60 s", out.count == 1 && { if case .say(let t) = out[0] { return t.hasPrefix("Sending: go on") }; return false }())
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("something", now: at(1))
    check("abort: ends it, says nothing by default", f.abort() == [.ended(.aborted)] && f.isIdle)
    check("abort when idle is nothing", f.abort() == [])
    _ = f.open(sid: "s1", now: at(5))
    check("abort with a reason", f.abort(say: "That session is no longer listening.")
          == [.say("That session is no longer listening."), .ended(.aborted)])
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", now: at(0))
    _ = f.hear("ok", now: at(1))
    _ = f.tick(now: at(3.1))
    check("read-back that never finishes is dropped", f.tick(now: at(3.1 + 44)) == [] && f.tick(now: at(3.1 + 45)) == [.say("Not sent."), .ended(.aborted)])
}
do {
    var f = ReplyFlow()
    _ = f.open(sid: "s1", project: "api server", announce: true, now: at(0))
    _ = f.hear("hello", now: at(1))
    check("several sessions: the read-back names the project",
          f.tick(now: at(3.1)) == [.say("To api server. Sending: hello. Say send, or cancel.")])
}

// MARK: Waiters (files)

print("waiters")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cv-reply-\(UUID().uuidString)")
let waiting = tmp.appendingPathComponent("waiting"), replyIn = tmp.appendingPathComponent("reply-in")
try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
let me = Int(getpid())
func arm(_ sid: String, waiter: Int, claude: Int) {
    let json = #"{"sid":"\#(sid)","token":"1.2","pid":\#(waiter),"claude":\#(claude),"started":1}"#
    try? json.write(to: waiting.appendingPathComponent("\(sid).json"), atomically: true, encoding: .utf8)
}
arm("live", waiter: me, claude: me)
arm("deadwaiter", waiter: 999_999, claude: me)
arm("deadclaude", waiter: me, claude: 999_999)
try? "{ not json".write(to: waiting.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
try? "{}".write(to: waiting.appendingPathComponent(".hidden.json"), atomically: true, encoding: .utf8)
check("armed: both processes alive", Waiters.armed("live", dir: waiting))
check("not armed: its waiter process is gone", !Waiters.armed("deadwaiter", dir: waiting))
check("not armed: the claude process is gone", !Waiters.armed("deadclaude", dir: waiting))
check("not armed: no file, broken file", !Waiters.armed("nobody", dir: waiting) && !Waiters.armed("broken", dir: waiting))
check("all(): only the live one", Waiters.all(dir: waiting) == ["live"])
check("deliver writes the text", Waiters.deliver("héllo\nworld", to: "live", dir: replyIn)
      && (try? String(contentsOf: replyIn.appendingPathComponent("live.txt"), encoding: .utf8)) == "héllo\nworld")
check("pending while unclaimed", Waiters.pending("live", dir: replyIn))
check("a second deliver replaces the first", Waiters.deliver("again", to: "live", dir: replyIn)
      && (try? String(contentsOf: replyIn.appendingPathComponent("live.txt"), encoding: .utf8)) == "again")
check("no temp files left behind", ((try? FileManager.default.contentsOfDirectory(atPath: replyIn.path)) ?? []).sorted() == ["live.txt"])
Waiters.withdraw("live", dir: replyIn)
check("withdrawn", !Waiters.pending("live", dir: replyIn))
try? FileManager.default.removeItem(at: tmp)

// MARK: ReplyCoordinator

@MainActor final class FakeMic: ReplyMic {
    var isReady = true
    var heardSound = true
    var kinds: [ReplyCaptureKind] = []
    var ended = 0
    var onText: ((String) -> Void)?
    func beginCapture(_ kind: ReplyCaptureKind, onText: @escaping (String) -> Void) { kinds.append(kind); self.onText = onText }
    func endCapture() { ended += 1; onText = nil }
}

print("coordinator")
MainActor.assumeIsolated {
    var now = t0
    var said: [String] = [], delivered: [(String, String)] = []
    var chimes = 0, idles = 0, withdrawn = 0
    var alive = true, unclaimed = false, saves = true
    let mic = FakeMic()
    let c = ReplyCoordinator(mic: mic, clock: { now })
    c.say = { said.append($0) }
    c.chime = { chimes += 1 }
    c.waiterAlive = { _ in alive }
    c.deliver = { text, sid in if saves { delivered.append((sid, text)); unclaimed = true }; return saves }
    c.pending = { _ in unclaimed }
    c.withdraw = { _ in withdrawn += 1; unclaimed = false }
    c.onIdle = { idles += 1 }
    @MainActor func reset() { now = t0; said = []; delivered = []; chimes = 0; idles = 0; withdrawn = 0; alive = true; unclaimed = false
                   saves = true; mic.kinds = []; mic.ended = 0; mic.heardSound = true; c.abort(); said = []; idles = 0 }
    @MainActor func advance(_ s: Double) { now = now.addingTimeInterval(s); c.tick() }

    // happy path
    c.open(sid: "s1", project: "demo", announce: false)
    check("chime and dictation start", chimes == 1 && mic.kinds == [.dictation] && c.isBusy && c.activeSid == "s1")
    c.open(sid: "s2", project: "other", announce: false)
    check("a second open is ignored while busy", chimes == 1 && c.activeSid == "s1")
    mic.onText?("deploy it")
    advance(1); advance(2.5)
    check("it reads the answer back, after closing the microphone",
          said == ["Sending: deploy it. Say send, or cancel."] && mic.ended >= 1 && c.isBusy)
    c.sayFinished()
    check("then listens for send", mic.kinds == [.dictation, .confirm])
    mic.onText?("send")
    check("delivered to the session, once", delivered.count == 1 && delivered[0] == ("s1", "deploy it"))
    check("busy until the session takes it", c.isBusy && idles == 0)
    advance(1)
    check("still waiting for the hook to pick it up", c.isBusy && said.count == 1)
    unclaimed = false
    advance(0.5)
    check("picked up: 'Sent.' and idle", said.last == "Sent." && !c.isBusy && idles >= 1)

    // nobody takes it
    reset()
    c.open(sid: "s1", project: "demo", announce: false)
    mic.onText?("hello"); advance(2.5); c.sayFinished(); mic.onText?("yes")
    advance(4.9)
    check("unclaimed for 4.9 s: still trying", c.isBusy && withdrawn == 0)
    advance(0.2)
    check("unclaimed for 5 s: withdrawn, user told", withdrawn == 1 && said.last == "That session is no longer listening." && !c.isBusy)

    // the session stops waiting (the user typed in the terminal)
    reset()
    c.open(sid: "s1", project: "demo", announce: false)
    mic.onText?("hello")
    alive = false
    advance(0.3)
    check("waiter gone mid-answer: told, idle, nothing sent", said.last == "That session is no longer listening." && !c.isBusy && delivered.isEmpty)

    // muted headset
    reset()
    mic.heardSound = false
    c.open(sid: "s1", project: "demo", announce: false)
    advance(30)
    check("nothing heard at all: asks whether the headset is muted", said == ["I could not hear you. Is the headset muted?"] && !c.isBusy)
    reset()
    mic.heardSound = true
    c.open(sid: "s1", project: "demo", announce: false)
    advance(30)
    check("sound but no words: silent timeout", said.isEmpty && !c.isBusy)

    // something else takes over
    reset()
    c.open(sid: "s1", project: "demo", announce: false)
    mic.onText?("hello")
    c.abort()
    check("abort: idle, microphone back to commands, nothing sent", !c.isBusy && mic.ended >= 1 && delivered.isEmpty && said.isEmpty)
    c.abort()
    check("abort when idle does nothing", !c.isBusy)

    // cannot save
    reset()
    saves = false
    c.open(sid: "s1", project: "demo", announce: false)
    mic.onText?("hello"); advance(2.5); c.sayFinished(); mic.onText?("send")
    check("a failed save is reported, not hidden", said.last == "I could not save your answer." && !c.isBusy)

    // cancel at the confirmation
    reset()
    c.open(sid: "s1", project: "demo", announce: false)
    mic.onText?("hello"); advance(2.5); c.sayFinished(); mic.onText?("cancel")
    check("cancel: not sent", delivered.isEmpty && said.last == "Not sent." && !c.isBusy)
}

try? FileManager.default.removeItem(at: tmp)
print(failed ? "\nFAILURES" : "\nall passed")
exit(failed ? 1 : 0)
