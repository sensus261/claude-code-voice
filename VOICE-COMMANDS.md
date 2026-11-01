# Claude Voice: voice command cheatsheet

Headset on, mic unmuted, then say **"Hey Claude, …"** followed by the command, in one breath.
Stop talking and it runs about a second later.

**"Hey Claude" also pauses whatever is playing**, so you can be heard. Then give a new command (stop, back three, play something else). If nothing usable follows within about 6 seconds, it carries on where it left off.

## The ones you'll use most

| Say | What happens |
|---|---|
| **Hey Claude, play last response** | Reads the newest reply from any session |
| **Hey Claude, play last response summarized** | Reads a short summary of it (see note below) |
| **Hey Claude, stop** | Stops talking |
| **Hey Claude, pause** / **resume** | Pause, then carry on from the same spot |
| **Hey Claude, back three** | Jump back 3 sentences (any number; "back" alone = 1) |
| **Hey Claude, from the beginning** | Start the current reply over |

## When you run several sessions

| Say | What happens |
|---|---|
| **Hey Claude, which sessions** | Names the sessions, newest first |
| **Hey Claude, play last response from api** | Newest reply of the project whose name contains "api" |
| **Hey Claude, play last response from api summarized** | Same, as a summary |
| **Hey Claude, switch to claude voice** | Plays that project's latest reply |

A partial project name is enough. Say it the way you'd read it: "api server" matches `api-server`.

## While something long is playing

| Say | What happens |
|---|---|
| **Hey Claude, next** | Skip to the next reply in the queue |
| **Hey Claude, previous** | Back to the previous reply |
| **Hey Claude, forward two** | Skip 2 sentences ahead |

## Answering Claude

| Say | What happens |
|---|---|
| *(after a reply is read)* | A chime means: speak your answer now (unmute the headset). You have about 30 seconds to start; it ends after 2 seconds of silence |
| **send** / **yes** / **go ahead** | After "Sending: …. Say send, or cancel." this puts your words into that Claude Code session |
| **cancel** / **no** / *(say nothing for 10 s)* | "Not sent." Nothing is sent |
| **redo** / **try again** | Record the answer again |
| **cancel that** / **never mind** | While you are still dictating: drop it |
| **Hey Claude, reply** | Opens the answer window now, for the session that spoke last (or the only one waiting) |
| **Hey Claude, reply to api** | Same, for the project whose name contains "api" |

It only works for a session that is idle and waiting for you. If it is not: "This session isn't listening for replies." Turn it on in Settings → Talk back.

## Progress updates

| Say | What happens |
|---|---|
| **Hey Claude, progress on** / **progress off** | Start or stop reading Claude's between-task messages. "Progress on" also turns on auto-read for the session you are following, since only auto-read sessions are read |
| **Hey Claude, what's the status** | Reads the last few progress updates of the newest session |

"What's the status" only has something to read if progress was **on** while the task ran.

## Sounds and spoken answers

| You hear | Meaning |
|---|---|
| Soft *Tink* | "Hey Claude" heard (playback is paused). Say the command now, you have about 6 seconds. Also: the answer window opened, speak your answer |
| *Pop* | Command understood |
| Low *Basso* | Heard you, but it wasn't a known command. Try again |
| "Summarizing." | Making a summary with Haiku (about 5 seconds) |
| "There is no summary yet. Turn on summaries by voice in settings." | Switch on "“Summarized” may create a summary" in Settings |
| "No session called …" | Project name didn't match. Say "which sessions" to hear the names |
| "No replies yet." | No session has replied since the hooks were installed |
| "I could not hear you. Is the headset muted?" | The answer window closed and no sound at all came from the microphone |
| "That session is no longer listening." | You typed in the terminal (or the session ended) while an answer was being taken |

## Notes

- **Summaries:** "summarized" plays an existing summary first (one from `/summarize-for-voice`, else a cached Haiku one). Only if none exists, and only with the Settings switch on, does it ask Claude Haiku for one (a little of your Claude usage). Replies under 70 words are just read in full.
- **Wake word off:** if you switch off "Start with “Hey Claude”" in Settings, say the bare command: "play last response", "stop", "back three". Keep it short; long sentences are ignored.
- **Mic muted or boom detached:** nothing is heard. If the boom is off, macOS may use the MacBook's mic instead; Settings → Voice commands → Microphone shows which one is live.
- **Not working?** Settings → Voice commands shows **Status**, **Microphone**, and **Heard → what it was taken for**. If "Heard" is empty, the mic isn't reaching the app. If it shows the wrong words, speak more slowly or closer to the mic. "Hey cloud" and "iCloud" are accepted as "Hey Claude". If Settings shows an orange message about Dictation, turn Dictation on in System Settings → Keyboard.
- **Phone workflow:** start the session on the Mac, `/remote-control`, walk away. When the phone notifies you: unmute, "Hey Claude, play last response summarized", then answer when the chime sounds. With "Answer Claude by voice" on and auto-read on for the session, you do not need to ask: the reply (or its summary) is read and the chime follows by itself.
