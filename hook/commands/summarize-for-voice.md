---
description: Spoken summary of your last reply, read aloud by the Claude Voice app
argument-hint: "[language]  (default: the app's summary language)"
allowed-tools: Bash(~/.claude/tts/voicectl summary-prep:*)
disable-model-invocation: true
---
!`~/.claude/tts/voicectl summary-prep --sid ${CLAUDE_SESSION_ID}`

Write the spoken version of YOUR MOST RECENT REPLY before this command, for text-to-speech. I am away from the screen and want the gist fast.

Work only from what you already know. Do not use any tool, do not re-read files, do not re-check or re-analyse anything.

If the arguments below name a language, write in it. Otherwise use the language given above, or the language of that reply if none is given.
Arguments: $ARGUMENTS

Rules:
- Write entirely in that language, the way a native speaker would say it aloud. Translate technical terms into natural words of the language. Never attach the language's endings to an English word (no "issue-ul", "commit-ul", "PR-ul"), and leave no English terms or abbreviations in. Leave out file names, paths and code identifiers; say what they are instead. Product and company names may stay. Keep exact numbers.
- Hard length limit: one fifth of that reply's length, at least 25 and at most 100 words. Keep the outcome, anything that failed or is at risk, and anything I must do or decide. Drop explanations, reasoning, alternatives and lists of details.
- Plain spoken sentences only: no markdown, lists, headings, emoji, symbols, code or URLs.
- Start with the outcome: what was done, found or decided. First person ("I fixed...").
- Never soften a failure, guess, or add anything that was not in that reply. If it asked me something or needs my decision, end with it.
- Output ONLY the spoken text: no preamble, no closing remark.
