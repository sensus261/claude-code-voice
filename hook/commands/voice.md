---
description: Control Claude Voice playback (pause, resume, stop, play, back N, fwd N, next, prev, auto, progress, speed, reply, talkback, status)
argument-hint: pause | resume | stop | play [summary] | back N | fwd N | next | prev | restart | auto on/off | progress on/off | speed X | reply [cancel] | talkback on/off | status
allowed-tools: Bash(~/.claude/tts/voicectl:*)
disable-model-invocation: true
---
!`~/.claude/tts/voicectl "$ARGUMENTS" --sid ${CLAUDE_SESSION_ID}`

The voice command above has already been carried out. Reply with only the single character 🔊 (or the status line if it printed one). Do not use any tool and do not add anything else.
