# Internals: the undocumented behavior this setup relies on

Everything below was verified empirically against Claude Code v2.1.220 on macOS (the /switch-path facts additionally re-verified on v2.1.227). None of it is documented; any of it can change in a future version. This page exists so you can re-verify quickly when something breaks, and so the knowledge is searchable for anyone hitting the same questions.

## Credentials are keychain-namespaced per config dir

With `CLAUDE_CONFIG_DIR` unset, the OAuth credential lives in the macOS keychain under service name `Claude Code-credentials` (account: your unix username). With `CLAUDE_CONFIG_DIR` set, the service name gets a suffix:

```
Claude Code-credentials-<first 8 hex chars of sha256(config dir path)>
```

The hash input is the config dir path as given. This is what makes parallel logins possible at all: each profile's token has its own slot, and logging into one cannot overwrite another. The statusline uses the same derivation to read the running profile's own token:

```sh
svc="Claude Code-credentials"
[ -n "$CLAUDE_CONFIG_DIR" ] && svc="$svc-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
security find-generic-password -s "$svc" -w
```

Adopting an existing login into a new profile (skipping one browser dance) is `security find-generic-password ... -w` from the old slot piped into `security add-generic-password -U -a "$USER" -s "<new service>" -w ...`.

## `.claude.json` moves inside the config dir

With `CLAUDE_CONFIG_DIR` set, the state file that normally lives at `~/.claude.json` lives at `$CLAUDE_CONFIG_DIR/.claude.json`. It holds identity (the logged-in account), per-project trust approvals, and MCP registrations, mixed together. Seeding a new profile with a copy of an existing `.claude.json` preserves trust and MCP; a subsequent `/login` rewrites only the account section.

## Stop hooks fire after the transcript is flushed

The session transcript (`projects/<cwd-slug>/<session>.jsonl`) is fully written before Stop hooks run. Verified by killing the process from inside a Stop hook and parsing the transcript afterwards: complete every time, final assistant message present. This is the fact that makes /switch safe: terminating the idle process at Stop time cannot truncate the conversation.

A Stop hook receives JSON on stdin with, among others: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `last_assistant_message`, `stop_hook_active`. A live captured payload carried NO top-level `effort` field despite the docs listing one; the hooks read `.effort.level` opportunistically and fall back to grepping the transcript tail for the last assistant entry's effort.

## The transcript records model and effort per message

Each assistant entry in the transcript carries the model id at `.message.model` (e.g. `claude-opus-5`) and the effort level at the entry's top level (`.effort`, one of low/medium/high/xhigh/max). Tailing the transcript for the last values tells you what the session was actually running, which can differ from the saved defaults in `settings.json` (the `/model` and `/effort` commands save defaults; a session launched with explicit flags, or predating the last save, diverges). /switch uses this to relaunch with `--model` and `--effort` matching the dying session exactly.

## `--continue` and `--resume` resolve purely through the projects dir

`claude -c` picks the most recent conversation for the current working directory by scanning `projects/<cwd-slug>/`. It does not consult account state: a conversation started under one account resumes cleanly under another (with a cold prompt cache on the new account). Sessions currently open in some process are excluded from the `/resume` picker, which is why a conversation you can see running is not offered for resume until you close it.

`claude --resume <session-id>` is also cwd-slug-scoped: it HARD-FAILS from a directory whose project slug (`s/[^a-zA-Z0-9]/-/g` applied to the path) does not own the transcript file. And a session's `cwd` is often a subdirectory of the transcript-owning dir (a plain `cd` in a Bash tool call moves the cwd without re-homing the transcript). The switch hooks therefore walk UP from the payload cwd to the ancestor whose slug owns the transcript, and stamp cwd + session id only as a validated pair; the wrapper cd's there before `--resume`, so the pair succeeds or fails together. Also worth knowing: `-c` in a directory with no history silently starts a FRESH conversation with exit 0 — no warning — which is why every degraded path returns to the launch dir (which has history in practice) and announces itself.

## Entering a git worktree re-homes the transcript

A session that enters a git worktree mid-conversation gets its transcript MOVED under the worktree's project slug (`projects/<worktree-path-slug>/`), while the shell that launched it still sits in the original directory. Anything that resolves conversations by launch-dir (`-c` from the wrapper's cwd) then finds the WRONG conversation. This is why the switch request carries the validated cwd + session-id pair.

## Worktree-isolated sessions: two extra rules

Verified on v2.1.227 against a live worktree-isolated session (one whose Bash calls run behind the worktree isolation guard):

- **Slash commands do not reach UserPromptSubmit hooks there.** A typed `/switch <tag>` produced no UserPromptSubmit invocation at all (verified against an independent hook's prompt log), while plain prompts in the same session, and the same slash command in non-isolated sessions on the same version, all delivered. Any client-side slash-command handling must therefore keep the command-file path as its worktree fallback.
- **The worktree Bash guard refuses compound slash-command preambles.** A `!` preamble that chains commands and redirects through a variable is rejected as "too complex to verify that it stays inside the worktree". A single plain invocation of a script (`bash ~/.claude/switch-arm.sh "<arg>"`) passes, and the script body is not inspected. This is why the arming logic lives in `switch-arm.sh` instead of inline in `commands/switch.md`.

## UserPromptSubmit sees the raw typed text, at dequeue time

For slash commands, UserPromptSubmit delivers the raw typed text (`/switch work`), never the expanded command body. Do not parse expanded-command markers out of prompt text: arbitrary prompts can QUOTE them (a paste, a background-task notification carrying subagent output), and trusting them would let quoted text arm real actions. Hooks fire when a prompt is DEQUEUED, not when it is submitted: a prompt queued mid-turn has its hook run only after the current turn completes, so a kill from inside a UserPromptSubmit hook always lands on an idle process, same as a Stop hook.

## The statusline is pull-only, and idle sessions do not render

Claude Code re-runs the statusline command on session activity (several times per turn) and not at all while idle: a session waiting for input went 255 seconds with zero invocations in our measurement, and untouched sessions in other terminals logged zero renders in 10 minutes. Consequences: nothing script-side can push an update into an idle terminal's display, and any data you want current on the next redraw has to come from a cache maintained by whichever session is active. That is exactly what the shared usage cache does.

## The usage API

`GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <oauth access token>` and header `anthropic-beta: oauth-2025-04-20` returns the account's live utilization: `five_hour` and `seven_day` objects (`utilization` percent, `resets_at` ISO timestamp) plus a `limits` array that includes per-model weekly buckets (`kind: "weekly_scoped"`) not exposed anywhere in the statusline feed. This endpoint is unofficial: treat it as a bonus that may vanish, and degrade gracefully (the statusline shows nothing rather than wrong numbers when the cache is stale or absent).

## Prompt-cache lifetime, and what anchors it

The server-side prompt cache for a subscription conversation expires about 1 hour after the last API request; while warm, the next message re-reads the history at a fraction of the cost, and once cold the full history is re-ingested (which is also the cheapest moment to `/compact`). The statusline's warmth segment estimates this from the transcript — but the file's mtime is NOT a valid anchor: resuming a session appends bookkeeping lines (file-history snapshots, summaries) with no API request behind them, which would show a re-warmed cache that doesn't exist. The last assistant entry's own `.timestamp` is written exactly when a response landed, i.e. when the cache was written; that is the anchor, with mtime only as fallback. The estimate stays approximate by design: usage overage shortens the TTL, and a CLI update or CLAUDE.md edit can invalidate a live entry, neither knowable from the outside.

## Bulk transcript-metadata rewrites scramble /resume recency

Claude Code occasionally rewrites old transcripts in place (format migrations; observed when a fresh config dir's `/resume` picker first walked a shared projects dir). Content is preserved but mtimes jump to "now", so `/resume`, which sorts by mtime, shows long-dead sessions as just-touched. The repair is mechanical because the truth survives inside each file: any transcript whose mtime is more than 10 minutes newer than its newest content timestamp gets backdated to that timestamp. `claude-doctor` runs this automatically (`_claude_transcript_timefix`).

## The one shell trap worth writing down

In zsh (and bash), `local a=$1 b=$HOME/x-$a` expands `$a` before the assignment takes effect, so `b` gets the OLD (usually empty) value. The heal function originally targeted a phantom `~/.claude-` directory because of exactly this. Separate `local` lines per dependent assignment.
