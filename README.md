# claude-code-profiles

Terminal setup for Claude Code: run multiple accounts side by side, switch between them instantly (even mid-conversation), and see account, usage, and git state at a glance in the statusline.

Built for people who legitimately hold several Claude accounts, for example a personal subscription, a company one, and a seat on a client's team plan. Each account stays permanently logged in inside its own isolated profile. No more logout/login roulette that wipes your onboarding state, project trust approvals, and MCP registrations every time you need the other account.

## What you get

**Isolated profiles, one per account.** Each account lives in its own config dir (`~/.claude-<tag>`), selected per process via `CLAUDE_CONFIG_DIR`. Credentials never collide: Claude Code stores each config dir's OAuth token in its own macOS keychain entry. Profiles run in parallel; nothing one does can disturb another.

**Shared configuration that stays in sync.** Settings, statusline, slash commands, skills, agents, plugins, and session history live once in `~/.claude` and reach every profile through symlinks. Change a setting anywhere and it applies everywhere. A self-heal pass on every launch repairs links that Claude Code's own file writes occasionally replace with real copies (nothing is lost; forked versions are kept as `*.conflict-<timestamp>` files).

**Wrappers with memory.**

```
claude-work        # switch: launch the "work" profile and remember it as current
claude-skip        # continue: launch whatever profile is current
claude             # untouched: the default config dir, permission prompts on
claude-doctor      # health check: links, marker, transcript timefix,
                   # and archiving of superseded resume generations
```

**`/switch` carries a live conversation to another account.** Inside any wrapped session:

```
/switch work
```

One confirmation line, the process restarts itself, and about a second later you are in the same conversation, billing the other account, with the same model and effort level. Three layers make this robust:

- **Instant and quota-proof.** A UserPromptSubmit hook handles a typed `/switch` entirely client-side, before any API call: zero tokens spent, and it works even when the account is hard-limited (exactly when you need it most; the model-driven path would need a turn it can't get).
- **Worktree-safe resume.** The dying session's model, effort, working directory, and session id are stamped on the request file, and the wrapper relaunches with `--resume <session-id>` from the directory that actually owns the transcript. A session that entered a git worktree mid-conversation (its transcript re-homes under the worktree's project slug) resumes correctly instead of landing in the wrong conversation; when no validated pair can be stamped, it degrades to `--continue` from the launch dir and says so.
- **Fallback command path.** The `/switch` slash command + Stop hook remain as the fallback when the prompt hook is absent or disabled, and for worktree-isolated sessions, where the harness doesn't deliver slash commands to prompt hooks at all. Its arming step is a single plain script call, which the worktree Bash guard permits (a compound preamble gets refused as unverifiable).

**A statusline that answers the questions you actually have:**

```
Fable 5 · high | 6% ctx | 3:19am · warm | $0.70
work | 5h: 4% (7:30pm) | fable: 62% (Sat 3pm) | wk: 47%
✎ ↑2 | ⎇ main | myrepo
```

Row 1: model, effort, context used, prompt-cache warmth, session cost. The warmth segment shows whether the conversation's server-side prompt cache is still live and until when ("3:19am · warm"), or "cold" (the next message re-ingests the full history — also the cheap moment to `/compact`). Row 2: account tag first (so you always know who is billing), then the 5-hour window, then the weekly buckets. When the session's model carries its own weekly bucket, that bucket is promoted next to the 5-hour segment (it's usually the binding limit) with the weekly bucket following; reset clocks are shown once, repeated only when they actually differ, and always rounded UP to the next half-hour so a shown time may read late but never early. Usage renders from a small per-account cache refreshed in the background, so every terminal of the same account shows the same, current numbers instead of each session's stale view. Row 3: git state (✎ uncommitted changes, ↑N commits that exist only on this machine, ∆N commits not yet merged to main), branch, worktree, repo name; in a non-git directory it shows the folder and path instead. Every segment hides when it has nothing to say.

## Requirements

- macOS (keychain, BSD `stat`/`date`; Linux would need light porting)
- Claude Code with subscription login (verified on v2.1.220; the /switch worktree and quota paths re-verified on v2.1.227)
- `jq`
- zsh (the wrappers; the statusline and hook are plain bash)

## Setup

1. **Declare your accounts.** Copy `profiles.conf.example` to `~/.claude/profiles.conf` and edit: one `tag email` line per account.

2. **Install the files.**

```sh
cp profiles.zsh ~/.claude/profiles.zsh
cp statusline-command.sh ~/.claude/statusline-command.sh
cp switch-arm.sh ~/.claude/switch-arm.sh
cp hooks/switch-stop-hook.sh ~/.claude/switch-stop-hook.sh
cp hooks/switch-prompt-hook.sh ~/.claude/switch-prompt-hook.sh
mkdir -p ~/.claude/commands && cp commands/switch.md ~/.claude/commands/switch.md
echo 'source ~/.claude/profiles.zsh' >> ~/.zshrc
```

3. **Merge the statusline and the hooks into** `~/.claude/settings.json` (keep your existing keys; this fragment shows only what to add):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  },
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/switch-prompt-hook.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/switch-stop-hook.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "s=\"$HOME/.claude-profiles/tidy.stamp\"; n=$(date +%s); [ $((n - $(cat \"$s\" 2>/dev/null || echo 0))) -lt 3600 ] && exit 0; mkdir -p \"$HOME/.claude-profiles\"; echo $n > \"$s\"; (nohup zsh -c \"source $HOME/.claude/profiles.zsh 2>/dev/null; _claude_transcript_timefix; _claude_transcript_dedupe\" >/dev/null 2>&1 &); exit 0"
          }
        ]
      }
    ]
  }
}
```

The SessionStart entry is the zero-maintenance mode: every session start kicks off the transcript tidy (recency repair plus superseded-generation archiving) in the background, throttled to once an hour and detached, so it never delays a launch. Resume-created duplicates clean themselves up within minutes; you never run anything by hand. Archived generations are pruned after a year; if you align live-transcript retention, set "cleanupPeriodDays": 365 in the same settings file (Claude Code's own default is around 30 days). Skip that entry if you prefer running `claude-doctor` manually.

4. **Create and log in each profile, one time.** Open a fresh terminal, then for each tag:

```sh
claude-work        # first launch creates ~/.claude-work, links shared files,
                   # and seeds .claude.json from your existing setup
/login             # pick the RIGHT account in the browser picker
```

Verify each profile landed on the intended account: `jq -r .oauthAccount.emailAddress ~/.claude-work/.claude.json`. The browser account picker is the only place a mistake can happen.

5. Optional: if you want your default `claude` (no wrapper) to be a specific account, just `/login` there too. The statusline labels such bare sessions `base <tag>` by reading which account the default config dir is actually logged into.

Adding an account later: add a line to `profiles.conf`, open a fresh terminal, launch `claude-<newtag>`, log in once. Done.

## Notes and caveats

- **One subscription per account.** Each profile is a separate account you or your org pays for. This tool changes where credentials are stored on your Mac, not how Anthropic meters usage: every account keeps its own limits, and nothing here pools, shares, or circumvents them.
- **Relies on observed, undocumented behavior.** The per-config-dir keychain naming, the hook payload shape, and the transcript format were verified against Claude Code v2.1.220 (details in [docs/internals.md](docs/internals.md)). A future version can change any of them; expect graceful degradation (a segment goes blank, /switch refuses) rather than data loss, but re-verify after major updates.
- **The background usage poll is optional.** It reads only your own account's meter with your own token, via an endpoint that is not officially documented. If you would rather not use it, delete the "Background refresh" block in the statusline: the usage and per-model segments simply stay absent and everything else keeps working.
- **The wrappers skip permission prompts** (`--dangerously-skip-permissions`), matching how many people run their own trusted machine. If you want prompts, edit the two lines in `profiles.zsh` that pass the flag.
- **Cross-account switches re-read the conversation.** Prompt caches are per account, so `/switch` late in a long session makes the target account pay a full uncached read of the history. Switch early, or accept the cost.
- **Worktree-isolated sessions switch via the command path.** The harness does not deliver slash commands to UserPromptSubmit hooks in worktree-isolated sessions, so the quota-proof layer can't fire there; `/switch` falls through to the command + Stop-hook path, which works but needs one model turn to complete. Hard-limited AND worktree-isolated at once: the switch arms immediately and completes at the end of the first turn that runs (switch to a non-limited model with `/model` to get one).
- **Sessions are shared across profiles** (deliberately): `~/.claude/projects` is on the shared list, so any profile can `--continue` any conversation and agent memory persists across accounts. If you want hard separation of conversation history between accounts, remove `projects` and `history.jsonl` from `_CLAUDE_SHARED` before first launch.
- `claude-doctor` (shell function) is unrelated to the built-in `claude doctor` subcommand.

## How it works

Short version: `CLAUDE_CONFIG_DIR` gives each account an isolated home including its own keychain credential slot; symlinks give all homes one shared brain; a marker file gives `claude-skip` its memory; and `/switch` is a handshake between an arming step (the prompt hook for a typed `/switch`, or the slash command's plain `switch-arm.sh` call as fallback), a kill step (the prompt hook immediately, or the Stop hook after the turn ends — either way only after the transcript is flushed, with the session's model, effort, directory, and session id stamped on the request), and the wrapper loop (relaunches the target profile with `--resume <session-id>` from the conversation's own directory, `--continue` as the degraded fallback). The long version, with everything we verified empirically, is in [docs/internals.md](docs/internals.md).

## License

MIT
