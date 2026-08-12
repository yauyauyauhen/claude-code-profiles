---
description: Carry this conversation to another Claude account profile
argument-hint: "[tag]"
allowed-tools: Bash
---

## Switch state (already executed mechanically — do NOT redo any of it)

!`bash ~/.claude/switch-arm.sh "$ARGUMENTS"`

## Respond according to the MODE line above — nothing else

- **MODE=armed**: the switch is armed. Reply with EXACTLY one line, `Switching to <tag> — the session will restart itself on that account.`, substituting the bare tag word (no brackets or quotes around it), and end your turn immediately. No tool calls, no extra prose. (When the turn ends, a Stop hook terminates this idle process and the wrapper loop relaunches the target profile in this session's own directory with `--resume <session-id>` — same conversation, worktree sessions included — carrying this session's model and effort.)
- **MODE=list**: tell the user the available tags, which is current, and that `/switch <tag>` restarts this exact conversation on that account. One-sentence caveat: the target account pays a full uncached read of the conversation so far, so switching late in a long session is expensive.
- **MODE=invalid**: say the tag isn't a known profile and list the valid ones.
- **MODE=no-loop**: this session wasn't started through a profile wrapper (`claude-<tag>` / `claude-skip`), so the automatic restart can't work here. Tell the user to exit and run `claude-<tag> -c` themselves, from this session's working directory (`-c` is cwd-keyed).
