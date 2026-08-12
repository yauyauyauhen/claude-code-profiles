#!/bin/bash
# /switch UserPromptSubmit hook: the quota-proof layer.
#
# Handles a typed /switch prompt entirely client-side, BEFORE any API call,
# so it works even when the account is hard-limited: at a session limit the
# slash-command path needs a model turn it can't get, so without this hook
# /switch would do nothing right when you need it most. It also makes every
# normal /switch free: the prompt never reaches the model, zero tokens.
#
# RAW FORM ONLY. UserPromptSubmit delivers the raw typed text for slash
# commands ("/switch work"); the expanded command body never arrives as a
# prompt (verified on v2.1.220-v2.1.227). Only a prompt that IS the command
# matches; everything else passes through untouched. Do not be tempted to
# match expanded-command markers: trusting mode/tag parsed out of arbitrary
# prompt text means any paste or background-task notification QUOTING the
# switch command file could arm a switch and kill the session.
#
# On an armed switch: stamp the SAME 5-line request file the Stop hook
# (switch-stop-hook.sh) writes, emit {"decision":"block"} so nothing reaches
# the model, then SIGTERM this session's claude; the wrapper loop relaunches
# the target profile with --resume <session-id>. list/invalid/no-loop are
# answered client-side too.
#
# commands/switch.md + the Stop hook stay unchanged as the fallback path when
# this hook is absent or disabled, and for worktree-isolated sessions, where
# the harness does not deliver slash commands to UserPromptSubmit at all
# (observed on v2.1.227; see docs/internals.md).
#
# Known residual (accepted): a nested `claude` spawned inside a session (e.g.
# `claude -p` from a Bash tool call) inherits CLAUDE_PROFILE_LOOP, and the
# kill walk resolves to the loop's direct child, the OUTER session. An exact
# /switch prompt fed to a nested run therefore switches the outer session.
# Headless tests must override CLAUDE_PROFILE_LOOP.
#
# Non-switch prompts MUST produce no output at all: plain stdout on exit 0 is
# injected into the model's context. Any unexpected failure -> exit 0
# silently (worst case: /switch falls through to the model-driven path).
#
# Register in ~/.claude/settings.json under hooks.UserPromptSubmit:
#   { "hooks": [ { "type": "command", "command": "bash ~/.claude/switch-prompt-hook.sh", "timeout": 10 } ] }

command -v jq >/dev/null 2>&1 || exit 0
_stdin=$(cat 2>/dev/null) || exit 0
prompt=$(printf '%s' "$_stdin" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$prompt" ] || exit 0

# Only a prompt that IS the command and nothing more; a prompt merely
# mentioning /switch (or multiline text starting with it) passes through.
stripped=$(printf '%s' "$prompt" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
case "$stripped" in
  "/switch") ;;
  "/switch "*) ;;
  *) exit 0 ;;
esac
set -f
# shellcheck disable=SC2086
set -- $stripped
set +f
[ "$#" -le 2 ] || exit 0
tag=${2-}

tags=$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$HOME/.claude/profiles.conf" 2>/dev/null | xargs)
[ -n "$tags" ] || exit 0
cur=$(cat "$HOME/.claude-profiles/current" 2>/dev/null || echo none)

block() {
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$1" | jq -Rs .)"
}

if [ -z "$tag" ]; then
  block "Profiles: $tags | current: $cur. /switch <tag> restarts this exact conversation on that account (client-side, no tokens; works even at a session limit). Caveat: the target account pays a full uncached read of the conversation so far."
  exit 0
fi
case " $tags " in
  *" $tag "*) ;;
  *) block "'$tag' isn't a known profile. Valid: $tags."; exit 0 ;;
esac
if [ -z "$CLAUDE_PROFILE_LOOP" ]; then
  block "This session wasn't started through a profile wrapper (claude-<tag> / claude-skip), so the automatic restart can't work here. Exit and run claude-$tag -c yourself from this session's working directory (-c is cwd-keyed)."
  exit 0
fi

# ---- armed: stamp the full 5-line request file (same protocol + validation
# as switch-stop-hook.sh: line 1 "tag pid", line 2 model, line 3 effort,
# line 4 cwd, line 5 session id), then kill this session's claude.
req="$HOME/.claude-profiles/switch-request"
_tp=$(printf '%s' "$_stdin" | jq -r '.transcript_path // empty' 2>/dev/null)
_cwd=$(printf '%s' "$_stdin" | jq -r '.cwd // empty' 2>/dev/null)
_sid=$(printf '%s' "$_stdin" | jq -r '.session_id // empty' 2>/dev/null)
_model=""
_effort=$(printf '%s' "$_stdin" | jq -r '.effort.level // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$')
if [ -n "$_tp" ] && [ -f "$_tp" ]; then
  _model=$(tail -n 200 "$_tp" | jq -r '.message.model // empty' 2>/dev/null | grep '^claude-' | tail -1)
  [ -n "$_effort" ] || _effort=$(tail -n 200 "$_tp" | jq -r 'select(.type=="assistant") | .effort // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$' | tail -1)
fi
# Resume pair (lines 4-5) stamped ONLY as a validated pair, else both blank
# (-c fallback). Same two traps as the Stop hook: cwd may be a subdirectory
# that owns no transcript (walk up to the ancestor whose project slug owns
# the transcript file); a corrupted/multiline value must not shift the line
# protocol.
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
# The kill is gated on the write actually landing: killing claude with no
# request file on disk would terminate the session with NO relaunch.
mkdir -p "$HOME/.claude-profiles" 2>/dev/null
if ! printf '%s %s\n%s\n%s\n%s\n%s\n' "$tag" "$CLAUDE_PROFILE_LOOP" "$_model" "$_effort" "$_cwd" "$_sid" > "$req" 2>/dev/null; then
  block "Couldn't write the switch request file ($req); switch aborted, nothing armed. Exit and run claude-$tag -c yourself."
  exit 0
fi

# Walk up from ourselves to the process whose PARENT is the wrapper shell:
# that process is this session's claude. Kill only on a positive match.
pid=$$
claude_pid=""
for _ in 1 2 3 4 5 6; do
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$ppid" ] || break
  if [ "$ppid" = "$CLAUDE_PROFILE_LOOP" ]; then claude_pid=$pid; break; fi
  [ "$ppid" = "1" ] && break
  pid=$ppid
done
if [ -n "$claude_pid" ]; then
  block "Switching to $tag: restarting on that account (client-side, no tokens needed)."
  kill -TERM "$claude_pid"
else
  # Disarm rather than leave a live-pid request: an armed file would make the
  # Stop hook complete the switch at the end of some LATER turn, an
  # unannounced kill long after the user moved on. Predictable beats clever.
  rm -f "$req"
  block "Couldn't locate this session's claude process; switch aborted, nothing armed. Exit and run claude-$tag -c yourself from this session's working directory."
fi
exit 0
