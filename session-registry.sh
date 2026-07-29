#!/bin/bash
# Session registry for restore-after-relaunch (design: ~/.claude/profiles-plan.md).
# ~/.claude-profiles/live/<session-id>: line 1 cwd, line 2 profile tag, line 3
# the pid of the TERMINAL APP this session runs under. SessionStart writes it,
# SessionEnd removes it, UserPromptSubmit refreshes mtime.
#
# The terminal pid is what makes restore safe without knowing whether
# SessionEnd fires on window close: _claude_session_autoclaim only claims
# records whose terminal pid is NOT the currently running terminal, i.e. only
# sessions whose terminal is actually gone. A window you closed deliberately
# during this terminal's lifetime can never be resurrected while it lives.
dir="$HOME/.claude-profiles/live"
input=$(cat 2>/dev/null)
id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$id" ] || exit 0

term_pid() {
  local pid=$$ comm
  for _ in 1 2 3 4 5 6 7 8; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" != "1" ] || { echo 0; return; }
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$comm" in
      *ghostty*|*Ghostty*|*iTerm*|*Terminal*|*kitty*|*WezTerm*|*Alacritty*|*Cursor*|*Code*)
        echo "$pid"; return ;;
    esac
  done
  echo 0
}

case "$1" in
  start)
    mkdir -p "$dir"
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
    tag=base
    [ -n "$CLAUDE_CONFIG_DIR" ] && tag=${CLAUDE_CONFIG_DIR##*/.claude-}
    printf '%s\n%s\n%s\n' "$cwd" "$tag" "$(term_pid)" > "$dir/$id"
    ;;
  end)
    rm -f "$dir/$id"
    ;;
  touch)
    [ -f "$dir/$id" ] && touch "$dir/$id"
    ;;
esac
exit 0
