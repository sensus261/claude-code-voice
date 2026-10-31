# Claude Voice

A small macOS app that reads your Claude Code replies aloud, so you can listen instead of reading the terminal.

It lists every Claude Code session that has replied recently, shows each reply formatted the way Claude Code shows it, and reads it with a natural macOS voice, or with a neural voice from Piper (offline) or Microsoft (online). You can browse, pause, jump between sentences, have chosen sessions read new replies automatically, and, only when you ask, get a short spoken summary in your own language.

> Unofficial side project. Not affiliated with or endorsed by Anthropic.

## Features

- **Floating window.** Pin it above every other window, including full-screen apps. A menu bar icon keeps it running when the window is closed.
- **All your sessions in one list.** Each session's latest reply, with project name, title, age, word count, the session's context size when it wrote that reply (like "183k ctx"), and a dot for replies you have not heard yet. Hide the sessions you don't want to see, until they reply again or for good.
- **Reader that looks like Claude Code.** Click a session to see its reply rendered from markdown: headings, bold, inline code, links, lists, tables, quotes and code blocks. The sentence being read is highlighted. Click any block to start reading from there.
- **Proper playback.** Play and pause, previous and next sentence, restart the reply, skip to the next reply, stop. One continuous voice, no gaps, exact sentence positions.
- **Auto-read per session.** Turn it on for the sessions you want to hear as soon as they reply. Replies from several sessions queue up and never talk over each other.
- **Progress updates.** Optionally, the short messages Claude writes between tasks ("Now checking the parser.") are read as they appear, not only the final reply, and recorded under the reply. If one has not been spoken yet when the final reply arrives, it is skipped so the reply starts right away.
- **Control it from Claude Code.** `/voice pause`, `/voice back 3`, `/voice play` and more, typed in any session, also from your phone through Remote Control. Hook-handled commands use no model tokens. See [Control it from Claude Code](#control-it-from-claude-code).
- **Spoken summaries, only on request.** Three tabs per reply:
  - **Full**: the real reply, read in full.
  - **Summary (low cost)**: Claude Haiku 5.5 condenses the reply text (you confirm first).
  - **Summary (from Claude Code)**: you run `/summarize-for-voice` in the session; the session writes the summary itself from its own memory and the app reads it.

  Summaries are written entirely in the language you choose (Romanian by default) and read by a voice for that language.
- **Auto-read never calls Claude.** It only plays text the hooks already saved. Every Claude call is explicit.
- **Each reply in its own language.** A reply written in another language than the main voice (for example Romanian) is read by that language's voice.
- **Better voices than macOS has for some languages.** Besides the macOS voices, the app can use [Piper](https://github.com/OHF-Voice/piper1-gpl) neural voices, which run offline on your Mac, and Microsoft's neural voices through [edge-tts](https://github.com/rany2/edge-tts), which run online. For Romanian, macOS only has Ioana; these add Mihai (Piper) and Alina and Emil (Microsoft).

## How it works

```
Claude Code session ──(Stop hook)────────────▶ state/replies/<session>.{md,txt,json}
                    ──(PostToolUse hook)──────▶ state/progress/<session>/*.txt
                    ──(/voice, /summarize…)───▶ state/commands/*.cmd, state/inbox/
                                                     │
                                                     ▼
                                        Claude Voice app (watches the folders)
                                           │                     │
                     macOS speech synthesizer             claude CLI (low-cost
                     (AVSpeechSynthesizer), or            summary, on request only)
                     Python worker: Piper / edge-tts
```

1. Claude Code **hooks** (`hook/talk`) feed the app. The **Stop** hook runs after every reply in every session: it saves the reply as raw markdown, a cleaned plain-text version, and metadata (project, title, transcript path). The **PostToolUse** hook (only while "Also read progress updates" is on) saves the short text blocks Claude wrote before each tool call. The **UserPromptSubmit** hook turns `/voice …` into a command for the app without calling the model. None of them plays audio or calls a model.
2. The **app** watches that folder, parses the markdown into display blocks and spoken sentences, and plays them with `AVSpeechSynthesizer`, one utterance per sentence. Word and sentence callbacks drive the highlight.
   - With a **Piper or Microsoft voice**, a Python worker (one per engine, kept running) turns each sentence into an audio file, several at a time, and the app plays the files. The next four sentences are made ahead, and files are cached for a week, so replays start at once. The highlighted word is estimated from the playback position. If the engine is missing or fails, that sentence is read by the best macOS voice for the language and the reader shows why.
   - The reply's language is detected with Apple's NaturalLanguage framework. If it differs from the main voice's language, the voice chosen for that language is used. The "From project" line before queued replies keeps the main voice.
3. **Summaries** come in two kinds, both through your Claude subscription (never an API key: the app removes `ANTHROPIC_API_KEY` from its calls).
   - **Low cost:** the app runs `claude -p --model claude-haiku-5-5` on the reply text alone, with hooks, tools, memory, CLAUDE.md files and connectors switched off.
   - **From Claude Code:** `/summarize-for-voice` runs inside your live session, so it uses the session's prompt cache and its own memory of the reply: one short turn, no tools. The Stop hook sees that this reply is a summary, keeps it away from the saved reply, and hands it to the app, which plays it. (An earlier version had the app fork the session with `claude -p --resume --fork-session`; that does not share the live session's cache and cost far more usage, so it was removed.)
   - Every low-cost summary is checked for anything a voice would stumble over: too many words, English words with native endings (like "issue-ul"), file names, abbreviations, and words the system dictionary for the language rejects. If anything is found, one quick Haiku pass repairs it.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon. Built and tested on macOS 26.
- Xcode or the Xcode Command Line Tools (Swift 5.9 or later; tested with Swift 6.4).
- [Claude Code](https://claude.com/claude-code) installed and logged in with a claude.ai account. Only needed for summaries.
- `jq` and `perl` for the hook. Both come with recent macOS; otherwise `brew install jq`.
- Good voices. In System Settings → Accessibility → Spoken Content → System voice → Manage Voices, download an Enhanced or Premium English voice (the app prefers "Evan (Enhanced)") and one for your summary language (for Romanian, "Ioana (Enhanced)").
- Optional, for more voices: [uv](https://docs.astral.sh/uv/) (`brew install uv`), used by `scripts/install-voices.sh`.

## Install

```bash
git clone https://github.com/sensus261/claude-code-voice.git
cd claude-code-voice

# 1. Build and install the app to ~/Applications/Claude Voice.app
./build.sh

# 2. Install the Claude Code side: hooks, voicectl, /voice and /summarize-for-voice
scripts/install-integration.sh
```

The script copies `hook/talk` and `hook/voicectl` to `~/.claude/tts/`, the two command files to `~/.claude/commands/`, and adds the `Stop`, `UserPromptSubmit` and `PostToolUse` hooks to `~/.claude/settings.json` without touching your other hooks. It is safe to run again, and keeps your original settings as `settings.json.bak-claude-voice`. Needs `jq`. Restart running Claude Code sessions afterwards.

Optionally, install Piper and Microsoft voices (see [More voices](#more-voices)):

```bash
scripts/install-voices.sh                       # Piper's Romanian voice
scripts/install-voices.sh en_US-lessac-medium   # or any other Piper voice
```

Open the app from Finder (⇧⌘H → Applications → Claude Voice) or with `open ~/Applications/"Claude Voice.app"`. To keep it handy, right-click its Dock icon → Options → Keep in Dock, or add it under System Settings → General → Login Items.

A session appears in the list after it finishes its next reply.

## Control it from Claude Code

Typed in any Claude Code session (also from the phone, when you drive a session on your Mac through Remote Control), so you can start, pause and skip while wearing headphones connected to the Mac:

| Command | Does |
|---|---|
| `/voice play` (or `start`) | Read this session's latest reply. `play summary` reads its summary. |
| `/voice pause`, `resume`, `stop` | Transport |
| `/voice back 3`, `/voice fwd 2` | Move by sentences (default 1) |
| `/voice prev`, `next`, `restart` | Previous reply, next reply, start of this reply |
| `/voice auto on`, `off` | Auto-read new replies from every session |
| `/voice progress on`, `off` | Also read progress updates |
| `/voice speed 1.2` | Speaking speed (0.6 to 1.4) |
| `/voice status` | What the app is doing |
| `/summarize-for-voice [language]` | The session writes a spoken summary of its last reply; the app plays it |

How a command is handled: the `UserPromptSubmit` hook recognizes `/voice …` (and plain `voice pause`), writes a command file the app picks up within a moment, and blocks the prompt, so **the model is never called and no tokens are used**. If the hook is not installed, the `/voice` command file still works, at the cost of one small model turn. The same commands work from a terminal: `~/.claude/tts/voicectl back 3`.

`/summarize-for-voice` is one turn in your live session, working from the session's own memory of its last reply, so it reads from the prompt cache instead of processing the conversation again. It does not re-read files or re-analyze. Do not add `model:` to its command file: switching models loses the cache.

## Using it

**Session list**

| Action | Result |
|---|---|
| Click a session (or ↑ ↓) | Show its reply, without speaking |
| Double-click, Return or ▶ | Play the full reply |
| Speaker icon | Auto-read new replies from that session (full text) |
| Right-click | Play, play a summary, add to queue, auto-read, mark as heard, copy text, hide |
| ⌫ or swipe left | Hide until the session replies again |
| "N hidden" | Show hidden sessions (dimmed); right-click one to unhide it |
| Play new | Play every unheard reply, top to bottom |

**Player**

| Control | Shortcut |
|---|---|
| Play / pause | Space |
| Previous / next sentence | ← / → |
| Stop | ⌘. |
| Restart this reply, skip to the next reply | buttons |
| Read from any point | click a sentence or block |

When another session is playing, a "Now: project" button jumps to it. The reader follows playback into the next reply only if you were watching the one that was playing.

**Settings (gear icon)**: the voice for full text, whether replies in another language use that language's voice, the summary language and its voice (with a Test button), speed, auto-read for every session, and which extra voices are installed.

## More voices

macOS has only one or two voices for some languages; for Romanian there is only Ioana. `scripts/install-voices.sh` installs two more engines with uv:

| Engine | Where it runs | Voices | Notes |
|---|---|---|---|
| [Piper](https://github.com/OHF-Voice/piper1-gpl) | Offline, on your Mac | Each voice is a download of about 60 MB into `~/.claude/tts/piper`. Romanian: Mihai. [All voices](https://huggingface.co/rhasspy/piper-voices). | First sentence after launch takes about 1.5 seconds while the voice loads. |
| Microsoft neural, through [edge-tts](https://github.com/rany2/edge-tts) | Online | More than 300, in every language the app offers. Romanian: Alina, Emil. | Each sentence is sent to Microsoft's speech service, the one Microsoft Edge's Read Aloud uses. It is not an official API and could stop working. The first sentence takes 2 to 4 seconds. |

The automatic voice for a language is the best one that runs offline: a Premium macOS voice, then Piper, then an Enhanced macOS voice. Microsoft voices are only used when you pick one, because they send your text online.

After installing, open Settings → More voices → Rescan, then choose a voice under Full text or Summaries. Settings → More voices → Open Piper Folder shows where Piper voices go: any `<voice>.onnx` with its `<voice>.onnx.json` placed there is listed.

To remove them: `uv tool uninstall piper-tts edge-tts` and delete `~/.claude/tts/piper`.

## Summaries and usage

Only summaries use Claude, and only on request. Auto-read, progress reading and every `/voice` command never do.

- **Low cost** (in the app, after you confirm) sees only the reply. It takes about 5 to 10 seconds and very little of your plan's usage.
- **From Claude Code** (`/summarize-for-voice`) is one short turn in the session. While its prompt cache is warm (about an hour after the session's last activity on a subscription) it costs roughly as much as any short message there; if the cache expired, the conversation is processed again like for any message. The summary uses the session's own model. Models with thinking enabled may think briefly before answering.

Each summary is about a fifth of the reply, between 25 and 100 words, and is cached per reply. A new reply makes a new summary. Replies under 70 words are only offered in full.

## Files

Everything lives under `~/.claude/tts/state/`:

| Path | Contents |
|---|---|
| `replies/<session>.md` | the reply as raw markdown |
| `replies/<session>.txt` | the reply cleaned for speech (fallback) |
| `replies/<session>.json` | project, title, working folder, transcript path |
| `heard/<session>` | marker; its date says when you last heard that session |
| `summaries/<session>.<quick or session>.json` | cached summaries |
| `progress/<session>/<time>-<n>.txt` | progress messages of the current or last turn |
| `progress-enabled` | exists while "Also read progress updates" is on; the PostToolUse hook does nothing without it |
| `commands/<time>.cmd` | commands from Claude Code, read and deleted by the app (older than 15 s are ignored) |
| `inbox/summary-<session>.txt` | a summary written by a session, waiting for the app |
| `pending-summary/<session>` | marks that the session's next reply is a summary |
| `status.json` | what the app is doing, for `voicectl status` |

Setting `CLAUDE_VOICE_STATE` moves this whole folder (the hooks and the app both honor it; the tests use it). The hook deletes files older than seven days. App settings, including hidden sessions, are stored in the `local.claude-voice` defaults domain.

Piper voices live in `~/.claude/tts/piper`. Audio made by Piper and Microsoft voices is cached in `~/Library/Caches/local.claude-voice/speech` and deleted after seven days.

## Development

```
Sources/
  App.swift          app entry, window and menu bar scenes
  Model.swift        ties it together: playing, auto-read, progress, commands, confirmations
  Commands.swift     watches commands/ from Claude Code
  Speaker.swift      sentence playlist: AVSpeechSynthesizer or audio files
  Voices.swift       voices from every engine, language detection, settings
  ExternalTTS.swift  Piper / edge-tts worker process and audio cache
  Store.swift        watches the replies and progress folders; sentence splitting
  Markdown.swift     markdown → display blocks + spoken sentences
  Summarizer.swift   low-cost summary via the claude CLI, imported summaries, speech check
  Views.swift        SwiftUI: reader, session list, settings, menu
hook/talk            the Claude Code hooks: Stop, PostToolUse (progress), UserPromptSubmit (/voice)
hook/voicectl        command line control of the app
hook/commands/       the /voice and /summarize-for-voice command files
scripts/install-integration.sh   installs the hooks, voicectl and commands
scripts/install-voices.sh   installs Piper and edge-tts, downloads Piper voices
scripts/make_icon.swift
tests/               small runnable test programs (see below)
build.sh             builds, signs (ad hoc) and installs the app
```

Rebuild and restart:

```bash
./build.sh
osascript -e 'quit app "Claude Voice"'; while pgrep -q ClaudeVoice; do sleep 0.2; done
open ~/Applications/"Claude Voice.app"
```

Test programs. Each compiles a few source files with a small `main.swift`:

```bash
# speech engine: tracking, pause, back/next/skip, queue (plays ~10 s of audio)
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store}.swift tests/engine/main.swift -o build/enginetest && build/enginetest

# Piper and Microsoft voices, language detection, fallbacks (plays ~25 s of audio)
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store}.swift tests/voices/main.swift -o build/voicetest && build/voicetest

# markdown parser
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown}.swift tests/markdown/main.swift -o build/mdtest && build/mdtest

# low-cost summary through the real code path (uses your Claude subscription)
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer}.swift tests/summary/main.swift -o build/sumtest
build/sumtest <session-id>

# hooks and voicectl against a fixture transcript, in a throwaway HOME (no app, no Claude)
bash tests/hook/test.sh

# command inbox, pause/resume/prev, dropping stale progress (plays a moment of speech)
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Commands}.swift tests/commands/main.swift -o build/cmdtest && build/cmdtest

# auto-read, progress and commands never start Claude (stub binary + own state folder)
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Commands,Model}.swift tests/autoplay/main.swift -o build/autotest && build/autotest

# off-screen screenshots of the window and Settings
swiftc -swift-version 5 Sources/{Speaker,Voices,ExternalTTS,Store,Markdown,Summarizer,Views,Model,Commands}.swift tests/render/main.swift -o build/render
build/render <output-folder>
```

## Known limitations

- The build is signed ad hoc, so it runs on the Mac that built it. Sharing it with others needs a Developer ID signature and notarization.
- When the session list has keyboard focus, it may take the arrow keys and space for itself. Click in the reader to use the shortcuts.
- The app polls the replies folder every 1.5 seconds.
- `/voice` is intercepted by the hook only because `~/.claude/commands/voice.md` exists: an unknown slash command never reaches hooks. Plain `voice pause` (no slash) is intercepted without the file. Tested with `claude -p` on the Mac; driving a session from the phone through Remote Control has not been tested here.
- Progress detection reads Claude Code's transcript (a text block before a tool call). The transcript format is internal and could change; the logic is one `jq` filter in `hook/talk`.
- `/summarize-for-voice` is recognized by a short-lived marker set when the command starts. If you interrupt it, the marker is cleared by your next prompt (and expires after three minutes anyway).
- Summaries are condensed by a model: they can leave out details. The Full tab is always one click away.
- With Piper and Microsoft voices the highlighted word is an estimate, so it can run slightly ahead of or behind the voice.
- Piper fails if it is installed under a very long path (espeak-ng only accepts a short data folder path). The install script's default location is fine.

## Ideas

- Voice commands ("stop", "back three", "from the beginning"), toggled from the window.

## License

[MIT](LICENSE)
