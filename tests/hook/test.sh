#!/bin/bash
# Tests hook/talk (Stop, PostToolUse progress, UserPromptSubmit) and hook/voicectl against a
# fixture transcript, in a throwaway HOME. No Claude, no app needed.  Run: bash tests/hook/test.sh
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
STATE="$HOME/.claude/tts/state"
TALK="$ROOT/hook/talk"
SID="sess-1"
T="$TMP/transcript.jsonl"
fail=0

ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

payload() { jq -nc --arg s "$SID" --arg t "$T" --arg c "/work/proj" --arg p "${1:-}" --arg m "${2:-}" \
  '{session_id: $s, transcript_path: $t, cwd: $c} + (if $p != "" then {prompt: $p} else {} end)
   + (if $m != "" then {last_assistant_message: $m} else {} end)'; }

line_user()   { jq -nc --arg t "$1" '{type:"user", message:{role:"user", content:$t}}'; }
line_result() { jq -nc '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"x", content:"ok"}]}}'; }
line_think()  { jq -nc --arg id "$1" '{type:"assistant", message:{id:$id, role:"assistant", content:[{type:"thinking", thinking:"hmm"}], stop_reason:"tool_use"}}'; }
line_text()   { jq -nc --arg id "$1" --arg t "$2" --arg r "${3:-tool_use}" '{type:"assistant", message:{id:$id, role:"assistant", content:[{type:"text", text:$t}], stop_reason:$r}}'; }
line_tool()   { jq -nc --arg id "$1" '{type:"assistant", message:{id:$id, role:"assistant", content:[{type:"tool_use", id:"tu", name:"Read", input:{}}], stop_reason:"tool_use"}}'; }
line_side()   { jq -nc '{type:"assistant", isSidechain:true, message:{id:"s", role:"assistant", content:[{type:"text", text:"sidechain chatter"}]}}'; }

notes() { ls "$STATE/progress/$SID" 2>/dev/null | grep -c '\.txt$'; }
cmds()  { ls "$STATE/commands" 2>/dev/null | grep -c '\.cmd$'; }
lastcmd() { cat "$STATE/commands/$(ls "$STATE/commands" | grep '\.cmd$' | sort | tail -1)"; }

echo "progress"
{ line_user "fix the bug"; line_think m1; line_text m1 "I will look at the files."; line_tool m1; line_result; } > "$T"
payload | "$TALK" progress
check "off by default: no notes"            '[ "$(notes)" = 0 ]'
mkdir -p "$STATE" && touch "$STATE/progress-enabled"
payload | "$TALK" progress
check "first tool call: 1 note"             '[ "$(notes)" = 1 ]'
check "note text"                           'grep -q "I will look at the files." "$STATE/progress/$SID/"*.txt'
payload | "$TALK" progress
check "same call again: no duplicate"       '[ "$(notes)" = 1 ]'
{ line_side; line_text m2 "Found the bug in the parser."; line_tool m2; line_result; } >> "$T"
payload | "$TALK" progress
check "second tool call: 2 notes"           '[ "$(notes)" = 2 ]'
check "sidechain text ignored"              '! grep -rq "sidechain chatter" "$STATE/progress/$SID"'
line_text m3 "All done. Fixed." end_turn >> "$T"
payload | "$TALK" progress
check "final reply is not progress"         '[ "$(notes)" = 2 ]'
check "meta written for the app"            '[ "$(jq -r .project "$STATE/replies/$SID.json")" = proj ]'

echo "stop"
payload "" "All done. Fixed." | "$TALK" hook
check "reply saved"                         'grep -q "All done" "$STATE/replies/$SID.txt"'
check "mark cleared at Stop"                '[ ! -f "$STATE/progress/$SID.mark" ]'
check "notes kept after Stop"               '[ "$(notes)" = 2 ]'

echo "next turn wipes old notes"
{ line_user "now the tests"; line_text n1 "Running the tests now."; line_tool n1; line_result; } >> "$T"
payload | "$TALK" progress
check "only the new turn's note"            '[ "$(notes)" = 1 ] && grep -q "Running the tests" "$STATE/progress/$SID/"*.txt'

echo "summary hand-off"
before=$(cat "$STATE/replies/$SID.txt")
out=$("$ROOT/hook/voicectl" summary-prep --sid "$SID")
check "summary-prep marks the session"      '[ -f "$STATE/pending-summary/$SID" ]'
payload "" "I fixed the parser bug and the tests pass." | "$TALK" hook
check "summary goes to inbox"               'grep -q "parser bug" "$STATE/inbox/summary-$SID.txt"'
check "summary command queued"              '[ "$(lastcmd)" = "summary $SID" ]'
check "saved reply untouched"               '[ "$(cat "$STATE/replies/$SID.txt")" = "$before" ]'
check "flag consumed"                       '[ ! -f "$STATE/pending-summary/$SID" ]'
"$ROOT/hook/voicectl" summary-prep --sid "$SID" >/dev/null
payload "just a normal question" | "$TALK" prompt
check "a normal prompt clears a stale summary marker" '[ ! -f "$STATE/pending-summary/$SID" ]'
"$ROOT/hook/voicectl" summary-prep --sid "$SID" >/dev/null
payload "/summarize-for-voice" | "$TALK" prompt
check "the summary command itself keeps its marker"  '[ -f "$STATE/pending-summary/$SID" ]'
rm -f "$STATE/pending-summary/$SID"
payload "" "A normal reply again." | "$TALK" hook
check "next reply is a normal reply"        'grep -q "normal reply" "$STATE/replies/$SID.txt"'

echo "prompt hook / voicectl"
rm -rf "$STATE/commands"
r=$(payload "/voice back 3" | "$TALK" prompt)
check "/voice back 3 blocks the prompt"     '[ "$(jq -r .decision <<<"$r")" = block ]'
check "does not store the prompt"           '[ "$(jq -r .hookSpecificOutput.suppressOriginalPrompt <<<"$r")" = true ]'
check "command written with session"        '[ "$(lastcmd)" = "back 3 --sid $SID" ]'
r=$(payload "voice pause" | "$TALK" prompt)
check "plain 'voice pause' works"           '[ "$(jq -r .decision <<<"$r")" = block ] && [ "$(lastcmd)" = "pause --sid $SID" ]'
n=$(cmds)
r=$(payload "voice recognition is a cool feature" | "$TALK" prompt)
check "ordinary sentence passes through"    '[ -z "$r" ] && [ "$(cmds)" = "$n" ]'
r=$(payload "voice" | "$TALK" prompt)
check "bare 'voice' passes through"         '[ -z "$r" ]'
r=$(payload "/voice sing" | "$TALK" prompt)
check "/voice nonsense is blocked, no cmd"  '[ "$(jq -r .decision <<<"$r")" = block ] && [ "$(cmds)" = "$n" ]'
r=$(payload "/voice start" | "$TALK" prompt)
check "start = play"                        '[ "$(lastcmd)" = "play full --sid $SID" ]'
payload "/voice go back 3" | "$TALK" prompt >/dev/null
check "'go back' is not a command (no cmd)" '[ "$(lastcmd)" = "play full --sid $SID" ]'
"$ROOT/hook/voicectl" fwd 12 >/dev/null; check "fwd 12"  '[ "$(lastcmd)" = "fwd 12" ]'
"$ROOT/hook/voicectl" auto on >/dev/null; check "auto on" '[ "$(lastcmd)" = "auto on" ]'
"$ROOT/hook/voicectl" speed 1.25 >/dev/null; check "speed" '[ "$(lastcmd)" = "speed 1.25" ]'
"$ROOT/hook/voicectl" "back" "2" >/dev/null; check "separate args" '[ "$(lastcmd)" = "back 2" ]'
"$ROOT/hook/voicectl" back x >/dev/null; check "bad number rejected" '[ "$(lastcmd)" = "back 2" ]'
r=$("$ROOT/hook/voicectl" status); check "status without app" 'grep -q "has not reported" <<<"$r"'
echo '{"state":"playing","reply":"proj","line":3,"lines":9,"autoAll":true,"readProgress":false,"rate":1.2,"summaryLanguage":"Romanian"}' > "$STATE/status.json"
r=$("$ROOT/hook/voicectl" status); check "status text" 'grep -q "playing" <<<"$r" && grep -q "auto on" <<<"$r"'
r=$("$ROOT/hook/voicectl" summary-prep --sid "$SID"); check "language hint" 'grep -q Romanian <<<"$r"'

echo
[ $fail = 0 ] && echo "all passed" || echo "FAILURES"
exit $fail
