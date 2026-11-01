// Voice grammar and wake gate: what the recognizer hears -> what the app does. No audio, no Claude.
//   swiftc -swift-version 5 Sources/{VoiceIntent,ReplyFlow}.swift tests/intent/main.swift -o build/intenttest
//   build/intenttest
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print((ok ? "  ok   " : "  FAIL ") + name)
    if !ok { failed = true }
}

// MARK: grammar

let table: [(String, VoiceIntent?)] = [
    // the two commands this feature exists for
    ("play last response", .play(summary: false, project: nil)),
    ("Play the last response.", .play(summary: false, project: nil)),
    ("play last response summarized", .play(summary: true, project: nil)),
    ("Play the last reply summarized", .play(summary: true, project: nil)),
    ("play last response in short", .play(summary: true, project: nil)),
    ("read the latest message", .play(summary: false, project: nil)),
    ("play summary", .play(summary: true, project: nil)),
    ("summarize it", .play(summary: true, project: nil)),
    ("last response", .play(summary: false, project: nil)),
    // switching sessions
    ("play last response from claude voice", .play(summary: false, project: "claude voice")),
    ("play last response from claude voice summarized", .play(summary: true, project: "claude voice")),
    ("play the last response of the api session", .play(summary: false, project: "api")),
    ("switch to api", .play(summary: false, project: "api")),
    ("play from my website", .play(summary: false, project: "website")),
    ("play the last response for me", .play(summary: false, project: nil)),
    ("which sessions", .listSessions),
    ("what sessions are there", .listSessions),
    // transport
    ("stop", .stop), ("Stop.", .stop), ("be quiet", .stop),
    ("pause", .pause), ("resume", .resume), ("continue", .resume), ("play", .resume),
    ("next", .next), ("skip", .next), ("skip 3", .forward(3)),
    ("previous", .previous),
    ("back", .back(1)), ("back three", .back(3)), ("back 3", .back(3)), ("go back to", .back(2)),
    ("forward five", .forward(5)),
    ("from the beginning", .restart), ("start over", .restart), ("repeat", .restart), ("again", .restart),
    // progress
    ("progress on", .progress(on: true)), ("progress off", .progress(on: false)),
    ("start reading progress", .progress(on: true)),
    ("stop reading progress", .progress(on: false)),
    ("turn progress updates off", .progress(on: false)),
    ("what's the status", .status), ("what is the progress", .status), ("read progress", .status),
    ("how is it going", .status),
    // answering a session by voice; "reply" as a noun still plays
    ("reply", .reply(project: nil)), ("Reply.", .reply(project: nil)), ("respond", .reply(project: nil)),
    ("I want to reply", .reply(project: nil)), ("let me answer", .reply(project: nil)),
    ("answer back", .reply(project: nil)), ("talk back", .reply(project: nil)),
    ("reply to api", .reply(project: "api")), ("reply to claude voice", .reply(project: "claude voice")),
    ("reply to the api server", .reply(project: "api server")),
    ("play the last reply", .play(summary: false, project: nil)),
    ("read the reply from api", .play(summary: false, project: "api")),
    ("what is the reply", nil),
    ("I will reply to that email when I get back to my desk this afternoon", nil),
    // not commands
    ("", nil), ("hello there", nil), ("the weather is nice today", nil),
    ("I think we should stop by the shop later and talk about it", nil),   // "stop" in a long sentence
    ("progress", nil),
]
for (text, expected) in table {
    let got = VoiceGrammar.parse(text)
    check("parse \"\(text)\" -> \(String(describing: expected))" + (got == expected ? "" : "  (got \(String(describing: got)))"),
          got == expected)
}

// MARK: answer flow vocabulary ("send or cancel?")

let confirmTable: [(String, ReplyConfirm?)] = [
    ("send", .send), ("Send.", .send), ("send it", .send), ("yes", .send), ("yes please", .send),
    ("go ahead", .send), ("okay", .send), ("confirm", .send),
    ("cancel", .cancel), ("no", .cancel), ("nope", .cancel), ("never mind", .cancel), ("forget it", .cancel),
    ("no don't send it", .cancel), ("do not send", .cancel), ("stop", .cancel),
    ("redo", .redo), ("again", .redo), ("try again", .redo), ("start over", .redo),
    ("hmm", nil), ("", nil), ("what", nil),
    ("I think you should send the message to the whole team right now", nil),   // a sentence, not an answer
]
for (text, expected) in confirmTable {
    let got = ReplyGrammar.confirm(text)
    check("confirm \"\(text)\" -> \(String(describing: expected))" + (got == expected ? "" : "  (got \(String(describing: got)))"),
          got == expected)
}
check("abort: 'cancel that'", ReplyGrammar.isAbort("cancel that"))
check("abort: 'never mind.'", ReplyGrammar.isAbort("Never mind."))
check("abort: a one-word 'no' can be the answer", !ReplyGrammar.isAbort("no"))
check("abort: nor 'cancel' or 'stop'", !ReplyGrammar.isAbort("cancel") && !ReplyGrammar.isAbort("stop"))
check("abort: not inside an answer", !ReplyGrammar.isAbort("never mind the build is green"))

// MARK: wake phrase

func wake(_ text: String) -> Int? { VoiceGrammar.wakeEnd(in: VoiceGrammar.normalize(text)) }
check("wake: Hey Claude", wake("Hey Claude") == 2)
check("wake: hey cloud (mis-heard)", wake("hey cloud") == 2)
check("wake: Hey, Claude. Play", wake("Hey, Claude. Play") == 2)
check("wake: okay claude", wake("okay claude") == 2)
check("wake: heyclaude", wake("heyclaude play") == 1)
check("wake: Claude, stop", wake("Claude, stop") == 1)
check("wake: last one wins", wake("hey claude hey claude stop") == 4)
check("wake: none in plain command", wake("play last response") == nil)
check("wake: project named claude is not a wake phrase", wake("play last response from claude voice") == nil)
check("wake: hey clark (mis-heard)", wake("hey clark play") == 2)
check("wake: hey clyde (mis-heard)", wake("hey clyde stop") == 2)
check("wake: 'close' alone is not a wake name", wake("close the window") == nil)
check("wake: iCloud (what the recognizer often writes)", wake("iCloud play last response summarized") == 1)
check("wake: hey alone is not", wake("hey there") == nil)

// MARK: wake gate

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

do {
    // wake word and command in one breath: runs after the text stops changing
    var g = WakeGate(requireWake: true, settle: 1.0)
    check("gate: partial 'hey' ignored", g.hear("Hey", now: at(0)) == .none)
    check("gate: 'hey claude' alone is a wake", g.hear("Hey Claude", now: at(0.3)) == .wake(alone: true))
    check("gate: wake reported once", g.hear("Hey Claude", now: at(0.4)) == .none)
    check("gate: armed after wake only", g.isArmed)
    _ = g.hear("Hey Claude play", now: at(1.0))
    _ = g.hear("Hey Claude play last response", now: at(1.5))
    check("gate: not yet while text is changing", g.tick(now: at(2.0)) == .none)
    check("gate: runs once settled", g.tick(now: at(2.6)) == .execute(.play(summary: false, project: nil)))
    check("gate: reset after execute", !g.isArmed && g.tick(now: at(3.0)) == .none)
}
do {
    // a command that grows while the user keeps talking
    var g = WakeGate(requireWake: true, settle: 1.0)
    _ = g.hear("hey claude play last response", now: at(0))
    _ = g.hear("hey claude play last response summarized", now: at(0.8))
    check("gate: waits for the word that follows", g.tick(now: at(1.2)) == .none)
    check("gate: summarized wins", g.tick(now: at(1.9)) == .execute(.play(summary: true, project: nil)))
}
do {
    // nothing said to us: no wake phrase, no action
    var g = WakeGate(requireWake: true, settle: 1.0)
    _ = g.hear("play last response", now: at(0))
    check("gate: needs the wake phrase", g.tick(now: at(5)) == .none)
    _ = g.hear("stop", now: at(6))
    check("gate: even for stop", g.tick(now: at(9)) == .none)
}
do {
    // wake phrase, then something that is no command
    var g = WakeGate(requireWake: true, settle: 1.0)
    _ = g.hear("hey claude what a lovely day", now: at(0))
    check("gate: not understood", g.tick(now: at(1.5)) == .notUnderstood)
}
do {
    // lone wake phrase, then silence
    var g = WakeGate(requireWake: true, settle: 1.0, armWindow: 6)
    check("gate: wake", g.hear("hey claude", now: at(0)) == .wake(alone: true))
    check("gate: still armed", g.tick(now: at(5)) == .none && g.isArmed)
    check("gate: expires", g.tick(now: at(6.5)) == .expired && !g.isArmed)
}
do {
    // lone wake phrase, then the command as a later part of the same transcript
    var g = WakeGate(requireWake: true, settle: 1.0)
    check("gate: wake first", g.hear("hey claude", now: at(0)) == .wake(alone: true))
    _ = g.hear("hey claude stop", now: at(2))
    check("gate: stop after chime", g.tick(now: at(3.2)) == .execute(.stop))
}
do {
    // wake phrase not required: a bare command works, chatter is ignored without a sound
    var g = WakeGate(requireWake: false, settle: 1.0)
    _ = g.hear("play last response summarized", now: at(0))
    check("gate/no wake: bare command", g.tick(now: at(1.2)) == .execute(.play(summary: true, project: nil)))
    _ = g.hear("so anyway I told him that we should meet tomorrow at the usual place after work", now: at(5))
    check("gate/no wake: long chatter ignored", g.tick(now: at(7)) == .none)
    g.reset()
    _ = g.hear("good morning", now: at(10))
    check("gate/no wake: short chatter is not 'not understood'", g.tick(now: at(12)) == .none)
    g.reset()
    _ = g.hear("hey claude pause", now: at(20))
    check("gate/no wake: wake phrase still accepted", g.tick(now: at(21.2)) == .execute(.pause))
}

do {
    // wake phrase and command arrive in one partial: still a wake (to pause playback), but not armed
    var g = WakeGate(requireWake: true, settle: 1.0)
    check("gate: wake with a command already after it", g.hear("hey claude stop", now: at(0)) == .wake(alone: false))
    check("gate: ...is not armed", !g.isArmed)
    check("gate: ...and the command still runs", g.tick(now: at(1.2)) == .execute(.stop))
}
do {
    // no wake phrase: nothing to pause for
    var g = WakeGate(requireWake: false, settle: 1.0)
    check("gate/no wake: a bare command is not a wake", g.hear("stop", now: at(0)) == .none)
}

do {
    // the recognizer wrote "iCloud" for "Hey Claude": the whole command must still run
    var g = WakeGate(requireWake: true, settle: 1.0)
    _ = g.hear("iCloud play last response summarized", now: at(0))
    check("gate: 'iCloud play last response summarized' runs", g.tick(now: at(1.2)) == .execute(.play(summary: true, project: nil)))
}

// MARK: echo

let spoken = ["The build failed, so I will stop the server and then play last response again."]
check("echo: our own speech", EchoFilter.isEcho("stop the server and then play", spoken: spoken))
check("echo: a real command is not", !EchoFilter.isEcho("hey claude stop", spoken: spoken))
check("echo: two words are never filtered", !EchoFilter.isEcho("stop the", spoken: spoken))
let readAloud = ["So if you say hey Claude, it pauses, and then you give the next command."]
check("tail echo: reply that contains the wake phrase", EchoFilter.isTailEcho("so if you say hey claude", spoken: readAloud))
check("tail echo: a real wake phrase while something else plays", !EchoFilter.isTailEcho("the build failed hey claude", spoken: readAloud))
check("tail echo: real wake + command", !EchoFilter.isTailEcho("hey claude play last response", spoken: readAloud))
check("tail echo: one word is never echo", !EchoFilter.isTailEcho("claude", spoken: readAloud))
check("echo: nothing spoken", !EchoFilter.isEcho("play last response", spoken: []))

print(failed ? "FAILED" : "all ok")
exit(failed ? 1 : 0)
