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

**Sessions survive a terminal restart.** Quit your terminal for an update or a reboot; when it relaunches and restores its window and split layout, every Claude session that died with it comes back on its own — same conversations, resumed by exact session id, on the same account, model, and effort level. A SessionStart hook keeps a registry of live sessions (cwd, account tag, terminal pid, tty), and each restored pane atomically claims one orphan matching its directory. Records are deliberately NOT removed by SessionEnd — that hook fires on terminal quit too and would empty the registry at exactly the wrong moment (learned the hard way). Instead, deletion happens where quit and exit actually differ: when you end a session deliberately, the pane survives and the wrapper cleans its tty's record; when the terminal dies, the wrapper dies with it and the record survives as a restore orphan. A closed-on-purpose session is additionally protected by the terminal-pid rule: only sessions whose terminal process is gone are claimable. Restoration stays armed only for the terminal's first `CLAUDE_AUTOCLAIM_WINDOW` seconds (default 180 — do not set it much tighter: in a staggered multi-window relaunch some panes' shells start tens of seconds in, and panes that miss the window come up as plain shells). For any pane that missed its claim, `claude-restore` claims the best orphan for its directory on demand. With several panes in one directory, seating is restored by tty-order proximity (pane creation order tends to survive a relaunch), so chats usually land back in their original panes; when the order shifts they may swap — the conversations themselves are always exact either way.

**`/switch` carries a live conversation to another account.** Inside any wrapped session:

```
/switch work
```

One confirmation line, the process restarts itself, and about a second later you are in the same conversation, billing the other account, with the same model and effort level. Mechanics: the command mechanically arms a request file, a Stop hook terminates the idle process after the transcript is fully flushed, and the wrapper loop relaunches the target profile with `--continue`, passing the dying session's model and effort explicitly.

**A statusline that answers the questions you actually have:**

```
Opus 5 · high | 6% ctx | $0.70
work | 5h: 4% (7:10pm) | wk: 47% (Tue 11pm)
✎ ↑2 | ⎇ main | myrepo
```

Row 1: model, effort, context used, session cost. Row 2: account tag first (so you always know who is billing), then 5-hour and weekly usage with reset times, plus any per-model weekly buckets your account carries. Usage renders from a small per-account cache refreshed in the background, so every terminal of the same account shows the same, current numbers instead of each session's stale view. Row 3: git state (✎ uncommitted changes, ↑N commits that exist only on this machine, ∆N commits not yet merged to main), branch, worktree, repo name; in a non-git directory it shows the folder and path instead. Every segment hides when it has nothing to say.

## Requirements

- macOS (keychain, BSD `stat`/`date`; Linux would need light porting)
- Claude Code with subscription login (verified on v2.1.220)
- `jq`
- zsh (the wrappers; the statusline and hook are plain bash)

## Setup

1. **Declare your accounts.** Copy `profiles.conf.example` to `~/.claude/profiles.conf` and edit: one `tag email` line per account.

2. **Install the files.**

```sh
cp profiles.zsh ~/.claude/profiles.zsh
cp statusline-command.sh ~/.claude/statusline-command.sh
cp hooks/switch-stop-hook.sh ~/.claude/switch-stop-hook.sh
cp session-registry.sh ~/.claude/session-registry.sh
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
            "command": "bash ~/.claude/session-registry.sh start"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "s=\"$HOME/.claude-profiles/tidy.stamp\"; n=$(date +%s); [ $((n - $(cat \"$s\" 2>/dev/null || echo 0))) -lt 3600 ] && exit 0; mkdir -p \"$HOME/.claude-profiles\"; echo $n > \"$s\"; (nohup zsh -c \"source $HOME/.claude/profiles.zsh 2>/dev/null; _claude_transcript_timefix; _claude_transcript_dedupe\" >/dev/null 2>&1 &); exit 0"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/session-registry.sh end"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/session-registry.sh touch"
          }
        ]
      }
    ]
  }
}
```

The session-registry entries (`SessionStart`/`SessionEnd`/`UserPromptSubmit`) power restore-after-relaunch. The second SessionStart entry is the zero-maintenance mode: every session start kicks off the transcript tidy (recency repair plus superseded-generation archiving) in the background, throttled to once an hour and detached, so it never delays a launch. Resume-created duplicates clean themselves up within minutes; you never run anything by hand. Archived generations are pruned after a year; if you align live-transcript retention, set "cleanupPeriodDays": 365 in the same settings file (Claude Code's own default is around 30 days). Skip that entry if you prefer running `claude-doctor` manually.

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
- **Sessions are shared across profiles** (deliberately): `~/.claude/projects` is on the shared list, so any profile can `--continue` any conversation and agent memory persists across accounts. If you want hard separation of conversation history between accounts, remove `projects` and `history.jsonl` from `_CLAUDE_SHARED` before first launch.
- `claude-doctor` (shell function) is unrelated to the built-in `claude doctor` subcommand.

## How it works

Short version: `CLAUDE_CONFIG_DIR` gives each account an isolated home including its own keychain credential slot; symlinks give all homes one shared brain; a marker file gives `claude-skip` its memory; and `/switch` is a three-part handshake between a slash command (arms a request), a Stop hook (terminates the idle process only after the transcript is flushed, stamping the session's model and effort), and the wrapper loop (relaunches the target profile with `--continue`). The long version, with everything we verified empirically, is in [docs/internals.md](docs/internals.md).

## License

MIT
