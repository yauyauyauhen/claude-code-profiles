#!/bin/bash
# Session registry for restore-after-relaunch (design: ~/.claude/profiles-plan.md).
# ~/.claude-profiles/live/<session-id>: line 1 cwd, line 2 profile tag, line 3
# terminal-app pid, line 4 tty. SessionStart writes it (and clears any other
# record on the same tty — a pane owns one session); UserPromptSubmit
# refreshes mtime.
#
# SessionEnd deliberately does NOT delete records: it fires on terminal QUIT
# too (verified live 2026-07-29 — it emptied the registry at quit and the
# restore found nothing). Deletion happens where quit-vs-exit is actually
# distinguishable: the wrapper loop cleans its tty's records after claude
# returns (a pane that survives its claude = deliberate exit), the /switch
# hook cleans the superseded id, the next SessionStart on the tty replaces,
# and the tidy sweep prunes anything older than 24h. On a quit the wrapper
# dies with the shell, so records survive — exactly the orphans to restore.
dir="$HOME/.claude-profiles/live"
input=$(cat 2>/dev/null)
id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$id" ] || exit 0

case "$1" in
  start)
    mkdir -p "$dir"
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    tag=base
    [ -n "$CLAUDE_CONFIG_DIR" ] && tag=${CLAUDE_CONFIG_DIR##*/.claude-}
    # terminal pid + tty: walk up from our parent (claude)
    pid=$$ tpid=0 tty="-" comm=""
    for _ in 1 2 3 4 5 6 7 8; do
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$pid" ] && [ "$pid" != "1" ] || break
      [ "$tty" = "-" ] || [ "$tty" = "??" ] && tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
      comm=$(ps -o comm= -p "$pid" 2>/dev/null)
      case "$comm" in
        (*ghostty*|*Ghostty*|*iTerm*|*Terminal*|*kitty*|*WezTerm*|*Alacritty*) tpid=$pid; break ;;
      esac
    done
    # a pane owns one session: drop other records on this tty
    if [ -n "$tty" ] && [ "$tty" != "-" ] && [ "$tty" != "??" ]; then
      for f in "$dir"/*; do
        [ -f "$f" ] || continue
        [ "$(sed -n 4p "$f" 2>/dev/null)" = "$tty" ] && [ "$(basename "$f")" != "$id" ] && rm -f "$f"
      done
    fi
    printf '%s\n%s\n%s\n%s\n' "$cwd" "$tag" "$tpid" "${tty:--}" > "$dir/$id"
    ;;
  end)
    # No deletion (see header). Log the reason payload once per end so we can
    # later learn whether quits are distinguishable from exits after all.
    printf '%s %s\n' "$(date '+%m-%d %H:%M')" "$(printf '%s' "$input" | jq -c '{reason, session_id}' 2>/dev/null)" >> "$HOME/.claude-profiles/end-reasons.log"
    ;;
  touch)
    [ -f "$dir/$id" ] && touch "$dir/$id"
    ;;
esac
exit 0
