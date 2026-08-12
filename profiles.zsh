# Claude Code multi-account profiles.
#
# Each account lives in its own config dir (~/.claude-<tag>) selected via
# CLAUDE_CONFIG_DIR, permanently logged in. Shared configuration (settings,
# skills, commands, sessions...) stays in ~/.claude (the "backbone") and
# reaches every profile through symlinks, so a change made anywhere applies
# everywhere. Accounts are declared in ~/.claude/profiles.conf.
#
# Entrances:
#   claude-<tag>   switch: records <tag> as current, launches that profile
#   claude-skip    continue: launches whatever profile is current
#   claude         (untouched) the backbone itself, permission prompts on
#
# /switch <tag> inside a wrapped session carries the LIVE conversation to
# another account: see ~/.claude/switch-stop-hook.sh and the /switch command
# (~/.claude/commands/switch.md).

_CLAUDE_PROFILES_CONF="$HOME/.claude/profiles.conf"

typeset -ga CLAUDE_PROFILES
CLAUDE_PROFILES=($(awk '!/^[[:space:]]*#/ && NF {print $1}' "$_CLAUDE_PROFILES_CONF" 2>/dev/null))
(( ${#CLAUDE_PROFILES} )) || echo "claude profiles: no accounts in $_CLAUDE_PROFILES_CONF (copy profiles.conf.example there) — wrappers not defined" >&2

# Backbone entries every profile shares via symlink. Everything NOT listed
# here stays per-profile (notably .claude.json — identity, project trust,
# MCP registrations — and credentials, caches, per-session state).
typeset -ga _CLAUDE_SHARED
_CLAUDE_SHARED=(settings.json statusline-command.sh keybindings.json commands skills agents plugins projects history.jsonl)

# Self-heal: shared entries must be symlinks into ~/.claude. Claude Code
# saves some files via temp-write+rename, which replaces a link with a real
# file and silently forks that profile. Heal adopts the fork (newer content
# wins; the losing version is kept as *.conflict-<ts> so nothing is silently
# lost), re-links, and creates links for newly appeared shared files. Runs on
# every wrapper launch; `claude-doctor` is the same pass, verbose.
_claude_profile_heal() {
  # NB: separate `local` lines — in one combined statement the shell expands
  # $tag BEFORE the assignment takes effect and heal targets a phantom dir.
  local tag=$1 name src dst ts
  local base=$HOME/.claude
  local prof=$HOME/.claude-$tag
  [ -d "$prof" ] || mkdir -p "$prof"
  for name in $_CLAUDE_SHARED; do
    src=$base/$name dst=$prof/$name
    [ -e "$src" ] || [ -L "$dst" ] || continue
    if [ -L "$dst" ]; then
      [ "$(readlink "$dst")" = "$src" ] || { ln -sfn "$src" "$dst"; echo "claude-$tag: repointed $name"; }
      continue
    fi
    if [ ! -e "$dst" ]; then ln -s "$src" "$dst"; continue; fi
    ts=$(date +%Y%m%d-%H%M%S)
    if [ -f "$dst" ] && [ -f "$src" ]; then
      if cmp -s "$dst" "$src"; then
        echo "claude-$tag: relinked $name (fork was identical)"
      elif [ "$dst" -nt "$src" ]; then
        cp -p "$src" "$base/$name.conflict-$ts"
        cp -p "$dst" "$src"
        echo "claude-$tag: $name forked, profile copy adopted into backbone (old backbone kept as $name.conflict-$ts)"
      else
        cp -p "$dst" "$prof/$name.conflict-$ts"
        echo "claude-$tag: $name forked, backbone kept (fork saved as $name.conflict-$ts)"
      fi
      rm -f "$dst"; ln -s "$src" "$dst"
    else
      mv "$dst" "$prof/$name.forked-$ts"; ln -s "$src" "$dst"
      echo "claude-$tag: $name was a real dir, preserved as $name.forked-$ts, relinked"
    fi
  done
  # A missing per-profile .claude.json is seeded from the backbone copy so
  # the new profile inherits project trust and MCP registrations; logging in
  # afterwards rewrites only the account section.
  if [ ! -f "$prof/.claude.json" ] && [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$prof/.claude.json" && chmod 600 "$prof/.claude.json"
    echo "claude-$tag: seeded .claude.json from backbone"
  fi
}

# Launch loop. Besides one plain run, this powers /switch: the command (or the
# quota-proof prompt hook) arms ~/.claude-profiles/switch-request ("<tag>
# <this shell's pid>"), a hook terminates the idle claude, and this loop
# relaunches the target profile in the session's own directory with
# --resume <session-id> (hook-stamped; -c fallback): same conversation, other
# account, even when the session moved into a git worktree mid-conversation.
# Keyed on the request file + pid match only, never on exit codes: SIGTERM
# exits 143 and that IS the normal switch path.
_claude_profile_launch() {
  local tag=$1; shift
  local req=$HOME/.claude-profiles/switch-request rtag rpid rmodel reffort rcwd rsid
  local origdir=$PWD
  {
  while true; do
    _claude_profile_heal "$tag"
    rm -f "$req"
    CLAUDE_PROFILE_LOOP=$$ CLAUDE_CONFIG_DIR="$HOME/.claude-$tag" command claude "$@"
    [ -f "$req" ] || break
    # Lines 2-5 are read with IFS= so a path's leading/trailing spaces survive.
    { read -r rtag rpid; IFS= read -r rmodel; IFS= read -r reffort; IFS= read -r rcwd; IFS= read -r rsid; } < "$req" 2>/dev/null; rm -f "$req"
    [ "$rpid" = "$$" ] || break
    case "$rtag" in
      (*[!a-zA-Z0-9_-]*|"") echo "claude profiles: malformed switch tag, staying put"; break ;;
    esac
    case " $CLAUDE_PROFILES " in
      *" $rtag "*) ;;
      *) echo "claude profiles: unknown switch tag '$rtag', staying put"; break ;;
    esac
    stty sane 2>/dev/null   # the TUI was SIGTERMed; make sure the terminal is usable
    echo "$rtag" > "$HOME/.claude-profiles/current"
    echo "-> switching to $rtag, resuming this conversation${rmodel:+ on $rmodel}"
    tag=$rtag
    # Relaunch WHERE the conversation actually lives: the hook stamps line 4
    # (the ancestor of the session's cwd whose project slug owns the
    # transcript; entering a worktree mid-conversation re-homes it away from
    # the launch dir) + line 5 (session id) as a validated PAIR, or neither.
    # cd + --resume succeed or fail TOGETHER: `--resume <id>` hard-fails from
    # a dir that doesn't own the transcript. Every degraded path returns to
    # the LAUNCH dir for `-c` and says so out loud: the current cwd may be a
    # PRIOR switch's worktree, and a silent `-c` in a history-less dir starts
    # a fresh blank conversation with exit 0.
    if [ -n "$rcwd" ] && [ -n "$rsid" ] && cd -- "$rcwd" 2>/dev/null; then
      set -- --dangerously-skip-permissions --resume "$rsid"
    else
      echo "claude profiles: no validated session pair${rcwd:+ (dir $rcwd unavailable)}, resuming most-recent in $origdir"
      cd -- "$origdir" 2>/dev/null
      set -- --dangerously-skip-permissions -c
    fi
    # Carry the dying session's exact model + effort (hook-stamped lines 2-3):
    # the saved defaults in settings.json may be something else entirely.
    [ -n "$rmodel" ] && set -- "$@" --model "$rmodel"
    [ -n "$reffort" ] && set -- "$@" --effort "$reffort"
    rmodel="" reffort="" rcwd="" rsid=""
  done
  } always {
    # A switch may have cd'd us into another directory; restore even on abort.
    # (zsh `always` runs for interactive shells incl. SIGINT; under
    # non-interactive zsh SIGINT can skip it — fine while this file is only
    # ever sourced into interactive shells.)
    cd -- "$origdir" 2>/dev/null || cd ~
  }
}

# claude-<tag> = explicit switch (records itself as current, then launches).
# claude-skip = continue (launches the recorded account, never changes it).
# All wrappers skip permission prompts; bare `claude` stays untouched.
for _t in $CLAUDE_PROFILES; do
  eval "claude-$_t() { mkdir -p \"\$HOME/.claude-profiles\"; echo $_t > \"\$HOME/.claude-profiles/current\"; _claude_profile_launch $_t --dangerously-skip-permissions \"\$@\"; }"
done
unset _t

claude-skip() {
  local tag
  tag=$(cat "$HOME/.claude-profiles/current" 2>/dev/null)
  [ -n "$tag" ] || tag=${CLAUDE_PROFILES[1]}
  [ -n "$tag" ] || { echo "claude profiles: no profiles configured"; return 1; }
  _claude_profile_launch "$tag" --dangerously-skip-permissions "$@"
}

# Claude Code migrations occasionally rewrite old transcript metadata in
# bulk, refreshing mtimes without new content; /resume then sorts long-dead
# sessions to the top as "1 minute ago". Repair: backdate any file whose
# mtime is >10min newer than its newest content timestamp back to that
# content time. Scans the last 24h of mtimes; active sessions are protected
# by the 10-minute guard.
_claude_transcript_timefix() {
  local f ts epoch mt fixed=0
  while IFS= read -r f; do
    ts=$(tail -5 "$f" | jq -r '.timestamp // empty' 2>/dev/null | tail -1)
    [ -n "$ts" ] || continue
    epoch=$(date -ju -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null) || continue
    mt=$(stat -f %m "$f")
    if [ $((mt - epoch)) -gt 600 ]; then
      touch -t "$(date -r "$epoch" '+%Y%m%d%H%M.%S')" "$f" && fixed=$((fixed+1))
    fi
  done < <(find "$HOME/.claude/projects" -name "*.jsonl" -maxdepth 2 -mmin -1440 2>/dev/null)
  echo "transcript timefix: $fixed file(s) backdated to their real last activity"
}

# Resuming a session mints a NEW session file carrying the history forward;
# the superseded generation stays behind as a duplicate /resume entry. Archive
# (never delete) older files whose content is carried by a newer sibling:
# allowed losses from the picker's view are bookkeeping lines and <=3 dangling
# unanswered user messages (they remain in the archived file); any missing
# assistant content, a live-session marker, or recent activity vetoes the move.
_claude_transcript_dedupe() {
  setopt local_options null_glob
  local dir f g id missing mcount bad dangling t archived=0
  local tmp=$(mktemp -d) archive_root=$HOME/.claude/projects-archive
  for dir in "$HOME/.claude/projects"/*/; do
    local files=("${(@f)$(find "$dir" -maxdepth 1 -name '*.jsonl' 2>/dev/null)}")
    (( ${#files} > 1 )) || continue
    for f in $files; do jq -r '.uuid // empty' "$f" 2>/dev/null | sort -u > "$tmp/${f:t}.u"; done
    for f in $files; do
      [ -f "$f" ] || continue
      # No reliable liveness signal exists (session-env markers outlive their
      # sessions; transcripts aren't held open). Archiving an idle-but-open
      # session is safe anyway: claude appends by path, so at worst it starts
      # a fresh stub file — never data loss. Guard: skip very recent writes.
      [ -n "$(find "$f" -mmin -10 2>/dev/null)" ] && continue
      for g in $files; do
        [ "$f" = "$g" ] && continue
        [ -f "$g" ] || continue
        [ "$g" -nt "$f" ] || continue
        missing=$(comm -23 "$tmp/${f:t}.u" "$tmp/${g:t}.u")
        mcount=$(printf '%s' "$missing" | grep -c .)
        (( mcount <= 6 )) || continue
        bad=0 dangling=0
        while read -r u; do
          [ -n "$u" ] || continue
          t=$(jq -r --arg u "$u" 'select(.uuid==$u) | .type' "$f" 2>/dev/null | head -1)
          case "$t" in
            assistant) bad=1 ;;
            user) dangling=$((dangling+1)) ;;
          esac
        done <<< "$missing"
        (( bad )) && continue
        (( dangling <= 3 )) || continue
        mkdir -p "$archive_root/${dir:t}"
        mv "$f" "$archive_root/${dir:t}/" || continue
        echo "  archived superseded ${f:t} (history lives in ${g:t}; $dangling dangling user line(s) kept in archive)"
        archived=$((archived+1))
        break
      done
    done
  done
  rm -rf "$tmp"
  echo "transcript dedupe: $archived superseded generation(s) moved to $archive_root"
  # Archive retention: archived generations expire after a year, matching the
  # cleanupPeriodDays=365 policy for live transcripts (mtimes are truthful
  # end-of-life times — mv preserves them and timefix repairs migration noise).
  local pruned
  pruned=$(find "$archive_root" -name '*.jsonl' -mtime +365 -print -delete 2>/dev/null | grep -c .)
  (( pruned )) && echo "archive retention: deleted $pruned archived transcript(s) older than 365 days"
  return 0
}



claude-doctor() {
  local t
  _claude_transcript_timefix
  _claude_transcript_dedupe
  for t in $CLAUDE_PROFILES; do
    echo "-- $t --"
    _claude_profile_heal "$t"
    find "$HOME/.claude-$t" -maxdepth 1 -mindepth 1 | while read -r p; do
      if [ -L "$p" ]; then echo "  link: ${p##*/} -> $(readlink "$p")"
      else echo "  real: ${p##*/}"; fi
    done
  done
  echo "marker: $(cat "$HOME/.claude-profiles/current" 2>/dev/null || echo '(none)')"
}
