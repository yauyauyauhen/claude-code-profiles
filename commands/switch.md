---
description: Carry this conversation to another Claude account profile
argument-hint: "[tag]"
allowed-tools: Bash
---

## Switch state (already executed mechanically — do NOT redo any of it)

!`req="$HOME/.claude-profiles/switch-request"; tags=$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOME/.claude/profiles.conf" 2>/dev/null | xargs); arg="$ARGUMENTS"; if [ -z "$arg" ]; then echo "MODE=list tags: $tags | current: $(cat "$HOME/.claude-profiles/current" 2>/dev/null || echo none)"; elif printf '%s' "$arg" | grep -q '[^a-zA-Z0-9_-]'; then echo "MODE=invalid tag: $arg | valid: $tags"; else case " $tags " in *" $arg "*) if [ -n "$CLAUDE_PROFILE_LOOP" ]; then printf '%s %s\n' "$arg" "$CLAUDE_PROFILE_LOOP" > "$req" && echo "MODE=armed tag: $arg"; else echo "MODE=no-loop tag: $arg"; fi;; *) echo "MODE=invalid tag: $arg | valid: $tags";; esac; fi`

## Respond according to the MODE line above — nothing else

- **MODE=armed**: the switch is armed. Reply with EXACTLY one line, `Switching to <tag> — the session will restart itself on that account.`, substituting the bare tag word (no brackets or quotes around it), and end your turn immediately. No tool calls, no extra prose. (When the turn ends, a Stop hook terminates this idle process and the wrapper loop relaunches the target profile with `-c`, carrying this session's model and effort.)
- **MODE=list**: tell the user the available tags, which is current, and that `/switch <tag>` restarts this exact conversation on that account. One-sentence caveat: the target account pays a full uncached read of the conversation so far, so switching late in a long session is expensive.
- **MODE=invalid**: say the tag isn't a known profile and list the valid ones.
- **MODE=no-loop**: this session wasn't started through a profile wrapper (`claude-<tag>` / `claude-skip`), so the automatic restart can't work here. Tell the user to exit and run `claude-<tag> -c` themselves.
