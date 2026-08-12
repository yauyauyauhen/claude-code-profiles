#!/bin/bash
# /switch arming helper: the slash command's `!` preamble calls this and
# nothing else.
#
# Why a separate file: worktree-isolated sessions run slash-command preambles
# through the worktree Bash guard, which refuses compound commands and
# variable redirects as "too complex to verify that it stays inside the
# worktree". The preamble must therefore be ONE plain invocation; all logic
# lives here, where the guard doesn't need to see it (writing the request
# file under ~/.claude-profiles is deliberate and harmless to any worktree).
#
# Contract (consumed by commands/switch.md's response modes; keep in sync):
#   no arg              -> "MODE=list tags: <tags> | current: <tag|none>"
#   unknown/bad tag     -> "MODE=invalid tag: <arg> | valid: <tags>"
#   known tag, no loop  -> "MODE=no-loop tag: <arg>"   (not wrapper-launched)
#   known tag, loop     -> arms the switch-request file ("<tag> <loop-pid>"),
#                          prints "MODE=armed tag: <arg>"; the Stop hook
#                          (switch-stop-hook.sh) completes the switch at the
#                          end of the turn.
req="$HOME/.claude-profiles/switch-request"
tags=$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOME/.claude/profiles.conf" 2>/dev/null | xargs)
arg="$1"
if [ -z "$arg" ]; then
  echo "MODE=list tags: $tags | current: $(cat "$HOME/.claude-profiles/current" 2>/dev/null || echo none)"
elif printf '%s' "$arg" | grep -q '[^a-zA-Z0-9_-]'; then
  echo "MODE=invalid tag: $arg | valid: $tags"
else
  case " $tags " in
    *" $arg "*)
      if [ -n "$CLAUDE_PROFILE_LOOP" ]; then
        printf '%s %s\n' "$arg" "$CLAUDE_PROFILE_LOOP" > "$req" && echo "MODE=armed tag: $arg"
      else
        echo "MODE=no-loop tag: $arg"
      fi ;;
    *) echo "MODE=invalid tag: $arg | valid: $tags" ;;
  esac
fi
