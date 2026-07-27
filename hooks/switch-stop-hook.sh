#!/bin/bash
# /switch Stop hook.
#
# Runs at the end of every turn in every session; inert unless THIS session's
# wrapper loop armed a switch request (/switch wrote the file with the loop's
# pid). Then it terminates the now-idle claude so the wrapper loop relaunches
# the target profile with -c. Transcripts are fully flushed before Stop hooks
# run, so the termination cannot truncate the conversation. Never deletes the
# request file: the wrapper consumes it.
#
# Register in ~/.claude/settings.json under hooks.Stop:
#   { "hooks": [ { "type": "command", "command": "bash ~/.claude/switch-stop-hook.sh" } ] }
req="$HOME/.claude-profiles/switch-request"
[ -n "$CLAUDE_PROFILE_LOOP" ] || exit 0
[ -f "$req" ] || exit 0
read -r _tag rpid < "$req"
[ "$rpid" = "$CLAUDE_PROFILE_LOOP" ] || exit 0
# Preserve the dying session's model and effort: the hook's stdin JSON
# carries the transcript path; its recent entries record the exact model id
# (message.model) and effort (top-level). Stamped as lines 2-3 so the wrapper
# relaunches with --model/--effort; the saved defaults in settings.json only
# know the last SAVED values, not this session's.
_stdin=$(cat 2>/dev/null)
_tp=$(printf '%s' "$_stdin" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$_tp" ] && [ -f "$_tp" ]; then
  _model=$(tail -n 200 "$_tp" | jq -r '.message.model // empty' 2>/dev/null | grep '^claude-' | tail -1)
  _effort=$(tail -n 200 "$_tp" | jq -r 'select(.type=="assistant") | .effort // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$' | tail -1)
  [ -n "$_model" ] && printf '%s %s\n%s\n%s\n' "$_tag" "$rpid" "$_model" "$_effort" > "$req"
fi
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
