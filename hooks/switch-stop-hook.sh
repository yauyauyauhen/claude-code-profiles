#!/bin/bash
# /switch Stop hook.
#
# Runs at the end of every turn in every session; inert unless THIS session's
# wrapper loop armed a switch request (/switch wrote the file with the loop's
# pid). Then it terminates the now-idle claude so the wrapper loop relaunches
# the target profile with --resume <session-id> (or -c when no validated pair
# could be stamped). Transcripts are fully flushed before Stop hooks run, so
# the termination cannot truncate the conversation. Never deletes the request
# file: the wrapper consumes it.
#
# Register in ~/.claude/settings.json under hooks.Stop:
#   { "hooks": [ { "type": "command", "command": "bash ~/.claude/switch-stop-hook.sh" } ] }
req="$HOME/.claude-profiles/switch-request"
[ -n "$CLAUDE_PROFILE_LOOP" ] || exit 0
[ -f "$req" ] || exit 0
read -r _tag rpid < "$req"
[ "$rpid" = "$CLAUDE_PROFILE_LOOP" ] || exit 0
# Preserve the dying session's state as EXTRA LINES on the request (never
# extra fields on line one: wrapper loops in already-open terminals parse
# line one as "tag pid" and must keep working; they ignore lines they don't
# read). Line 2 model, line 3 effort, line 4 cwd, line 5 session id.
# Model: settings.json only knows the last SAVED default, not this session's.
# Cwd + session id exist because a session that enters a git worktree
# mid-conversation gets its transcript RE-HOMED under the worktree's project
# slug; the validation block below owns the stamping rules.
_stdin=$(cat 2>/dev/null)
_tp=$(printf '%s' "$_stdin" | jq -r '.transcript_path // empty' 2>/dev/null)
_cwd=$(printf '%s' "$_stdin" | jq -r '.cwd // empty' 2>/dev/null)
_sid=$(printf '%s' "$_stdin" | jq -r '.session_id // empty' 2>/dev/null)
_model=""
# Effort: top-level stdin field (.effort.level per hooks docs); transcript
# tail as fallback for older payload shapes. Validated against known levels.
_effort=$(printf '%s' "$_stdin" | jq -r '.effort.level // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$')
if [ -n "$_tp" ] && [ -f "$_tp" ]; then
  _model=$(tail -n 200 "$_tp" | jq -r '.message.model // empty' 2>/dev/null | grep '^claude-' | tail -1)
  [ -n "$_effort" ] || _effort=$(tail -n 200 "$_tp" | jq -r 'select(.type=="assistant") | .effort // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$' | tail -1)
fi
# Resume pair (lines 4-5) is stamped ONLY as a validated pair, else both
# blank (-c fallback = the old behavior). Two traps this guards against:
# (a) the session's cwd is often a SUBDIRECTORY (plain `cd` in a Bash tool
# call moves it without re-homing the transcript); `--resume` is cwd-slug-
# scoped and HARD-FAILS from a dir that owns no transcript, so we walk up
# from cwd to the ancestor whose project slug (s/[^a-zA-Z0-9]/-/g) owns the
# transcript file; (b) a corrupted/multiline value would shift the line
# protocol or inject options into the relaunch.
_nl=$'\n'
case "$_sid" in *[!0-9a-fA-F-]*|-*|"") _sid="" ;; esac
case "$_cwd" in *"$_nl"*) _cwd="" ;; esac
if [ -n "$_tp" ] && [ -f "$_tp" ] && [ -n "$_sid" ] && [ -n "$_cwd" ]; then
  _slugdir=${_tp%/*}; _slug=${_slugdir##*/}
  _d=$_cwd
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    [ "${_d//[^a-zA-Z0-9]/-}" = "$_slug" ] && break
    _d=${_d%/*}
  done
  if [ -n "$_d" ] && [ "$_d" != "/" ]; then _cwd=$_d; else _cwd="" _sid=""; fi
else
  _cwd="" _sid=""
fi
printf '%s %s\n%s\n%s\n%s\n%s\n' "$_tag" "$rpid" "$_model" "$_effort" "$_cwd" "$_sid" > "$req"
# Walk up from ourselves to the process whose PARENT is the wrapper shell:
# that process is this session's claude. Kill only on a positive match; if
# the walk dead-ends (pid 1 or a broken chain), do nothing rather than guess.
pid=$$
claude_pid=""
for _ in 1 2 3 4 5 6; do
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$ppid" ] || break
  if [ "$ppid" = "$CLAUDE_PROFILE_LOOP" ]; then claude_pid=$pid; break; fi
  [ "$ppid" = "1" ] && break
  pid=$ppid
done
[ -n "$claude_pid" ] && kill -TERM "$claude_pid"
exit 0
