#!/bin/bash
# Installs the extra voices Claude Voice can use, besides the macOS ones:
#   - Piper: neural voices that run offline on this Mac (downloaded into ~/.claude/tts/piper)
#   - Microsoft neural voices through edge-tts: online, each sentence is sent to Microsoft
#
# Usage: scripts/install-voices.sh [piper-voice ...]
#   Default Piper voice: ro_RO-mihai-medium (Romanian). Others, like en_US-lessac-medium,
#   are listed at https://huggingface.co/rhasspy/piper-voices
#
# Both tools are installed with uv (brew install uv); remove them with "uv tool uninstall".
set -euo pipefail

if ! command -v uv >/dev/null; then
  echo "This script needs uv: brew install uv" >&2
  exit 1
fi

# A native arm64 Python managed by uv: an old Intel Python may run but Piper fails there.
PY=(--python 3.12 --python-preference only-managed)
uv tool install "${PY[@]}" edge-tts
uv tool install "${PY[@]}" piper-tts

DIR="$HOME/.claude/tts/piper"
mkdir -p "$DIR"
VOICES=("$@")
[ ${#VOICES[@]} -gt 0 ] || VOICES=(ro_RO-mihai-medium)
"$(uv tool dir)/piper-tts/bin/python" -m piper.download_voices --download-dir "$DIR" "${VOICES[@]}"

echo
echo "Done. In Claude Voice open Settings (gear icon) → More voices → Rescan, then pick a voice."
