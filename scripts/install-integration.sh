#!/bin/bash
# Installs the Claude Code side of Claude Voice (safe to run again):
#   ~/.claude/tts/talk        hooks: Stop (replies), PostToolUse (progress), UserPromptSubmit (/voice)
#   ~/.claude/tts/voicectl    command line control of the app
#   ~/.claude/commands/       /voice and /summarize-for-voice
# and registers the three hooks in ~/.claude/settings.json, keeping every other hook as it is.
# The original settings.json is saved once as settings.json.bak-claude-voice.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

TTS="$HOME/.claude/tts"
CMDS="$HOME/.claude/commands"
SETTINGS="$HOME/.claude/settings.json"

install -d "$TTS" "$CMDS"
install -m 755 hook/talk "$TTS/talk"
install -m 755 hook/voicectl "$TTS/voicectl"
for f in hook/commands/*.md; do
  dest="$CMDS/$(basename "$f")"
  if [ -f "$dest" ] && ! cmp -s "$f" "$dest"; then cp "$dest" "$dest.bak"; echo "kept a copy of your old $(basename "$dest") as $(basename "$dest").bak"; fi
  install -m 644 "$f" "$dest"
done

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.bak-claude-voice" ] || cp "$SETTINGS" "$SETTINGS.bak-claude-voice"

tmp=$(mktemp)
jq --arg talk "$TTS/talk" '
  def ensure($event; $cmd; $matcher; $extra):
    .hooks[$event] = (
      (.hooks[$event] // []) as $groups
      | if any($groups[]?.hooks[]?; .command == $cmd) then $groups
        else $groups + [ {hooks: [({type: "command", command: $cmd} + $extra)]}
                         + (if $matcher != null then {matcher: $matcher} else {} end) ] end);
  (.hooks //= {})
  | ensure("Stop"; $talk + " hook"; null; {timeout: 10})
  | ensure("UserPromptSubmit"; $talk + " prompt"; null; {timeout: 10})
  | ensure("PostToolUse"; $talk + " progress"; "*"; {async: true})
' "$SETTINGS" > "$tmp"
jq -e . "$tmp" >/dev/null   # must still be valid JSON
mv "$tmp" "$SETTINGS"

cat <<EOF
Installed.
  hooks      Stop, UserPromptSubmit, PostToolUse  ->  $TTS/talk
  control    $TTS/voicectl  (try: $TTS/voicectl status)
  commands   /voice   /summarize-for-voice   (restart Claude Code sessions to pick up hooks and commands)
Turn on "Also read progress updates" in the app's Settings to read the messages between tasks.
EOF
