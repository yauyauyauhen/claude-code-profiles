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

# Launch loop. Besides one plain run, this powers /switch: the slash command
# arms ~/.claude-profiles/switch-request ("<tag> <this shell's pid>"), the
# Stop hook terminates the idle claude, and this loop relaunches the target
# profile with -c (same conversation, other account), carrying the dying
# session's model and effort (hook-stamped lines 2-3 of the request file).
# Keyed on the request file + pid match only, never on exit codes: SIGTERM
# exits 143 and that IS the normal switch path.
_claude_profile_launch() {
  local tag=$1; shift
  local req=$HOME/.claude-profiles/switch-request rtag rpid rmodel reffort
  while true; do
    _claude_profile_heal "$tag"
    rm -f "$req"
    CLAUDE_PROFILE_LOOP=$$ CLAUDE_CONFIG_DIR="$HOME/.claude-$tag" command claude "$@"
    [ -f "$req" ] || break
    { read -r rtag rpid; read -r rmodel; read -r reffort; } < "$req" 2>/dev/null; rm -f "$req"
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
    set -- --dangerously-skip-permissions -c
    [ -n "$rmodel" ] && set -- "$@" --model "$rmodel"
    [ -n "$reffort" ] && set -- "$@" --effort "$reffort"
    rmodel="" reffort=""
  done
  # Reaching here = claude exited and the PANE SURVIVED, i.e. a deliberate
  # exit — clean this tty's registry records so the session is never
  # "restored" later. On a terminal quit the shell dies inside the loop
  # above and this never runs: those records survive as restore orphans.
  # (SessionEnd can't do this job — it fires on quits too.)
  local _rt=$(tty 2>/dev/null); _rt=${_rt##*/dev/}
  if [ -n "$_rt" ]; then
    local _rf
    for _rf in "$HOME/.claude-profiles/live"/*(N); do
      [ "$(sed -n 4p "$_rf" 2>/dev/null)" = "$_rt" ] && rm -f "$_rf"
    done
  fi
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

# --- session restore: auto-claim orphaned sessions after a terminal relaunch ---
# SessionStart/End hooks maintain ~/.claude-profiles/live/<session-id> records
# (cwd, tag, terminal pid; UserPromptSubmit refreshes mtime). When the terminal
# relaunches and restores its window/split layout, each fresh shell claims one
# orphan matching its cwd ATOMICALLY (mv into claimed/) and resumes it by exact
# session id, carrying the dying session's model and effort.
#
# The safety rule is the recorded TERMINAL PID: only sessions whose terminal
# process is gone are claimable. A window closed deliberately while the
# terminal keeps running can never be resurrected — which makes the design
# correct whether or not SessionEnd fires on window close (untested; the
# hook's own record is the belt, this is the suspenders).
# Further guards: only in the terminal's first CLAUDE_AUTOCLAIM_WINDOW seconds
# (default 180) so deliberate new tabs later never trigger it, records fresher
# than 24h, transcript must still exist, and one session per pane.
# Same-directory panes may swap which chat lands where; content is always
# exact. Launches through the wrappers WITHOUT touching the claude-skip
# marker: restoration is not an account switch.
_claude_session_autoclaim() {
  setopt local_options null_glob
  local live=$HOME/.claude-profiles/live
  [ -d "$live" ] || return 0
  # This pane's own terminal: walk up to the terminal app process.
  local pid=$$ comm tpid=0
  for _ in 1 2 3 4 5 6 7 8; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" != "1" ] || break
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    case "$comm" in
      (*ghostty*|*Ghostty*|*iTerm*|*Terminal*|*kitty*|*WezTerm*|*Alacritty*) tpid=$pid; break ;;
    esac
  done
  (( tpid )) || return 0
  local gsecs gstart
  gstart=$(ps -o etime= -p "$tpid" 2>/dev/null | tr -d ' ')
  local -a _gp
  _gp=(${(s.:.)${gstart//-/:}})
  case ${#_gp} in
    1) gsecs=${_gp[1]} ;;
    2) gsecs=$(( ${_gp[1]#0}*60 + ${_gp[2]#0} )) ;;
    *) gsecs=999999 ;;
  esac
  (( gsecs < ${CLAUDE_AUTOCLAIM_WINDOW:-180} )) || return 0
  local f id rcwd rtag rterm rtty claimed=$HOME/.claude-profiles/claimed
  mkdir -p "$claimed"
  # Seating heuristic: macOS assigns tty numbers roughly in pane-creation
  # order and Ghostty recreates panes in a stable order, so relative tty
  # order tends to survive a relaunch. Claiming the orphan whose OLD tty
  # number is closest to this pane's NEW one usually restores the original
  # pane<->chat seating. (Exact seating is impossible: Ghostty answers no
  # title queries, so a pane can never read its own restored marker.)
  local mytty best bestd rnum d
  mytty=$(tty 2>/dev/null); mytty=${mytty//[^0-9]/}; [ -n "$mytty" ] || mytty=0
  while true; do
    best=""; bestd=999999
    for f in "$live"/*(N); do
      [ -f "$f" ] || continue
      [ -n "$(find "$f" -mmin -1440 2>/dev/null)" ] || continue
      { read -r rcwd; read -r rtag; read -r rterm; read -r rtty } < "$f" 2>/dev/null
      [ "$rcwd" = "$PWD" ] || continue
      # Terminal still alive => that session was closed on purpose, not lost.
      # (pid recycling across a relaunch could make a dead terminal's pid
      # match the new one — treat "same pid as ours" as alive, everything
      # else by kill -0.)
      [ "$rterm" = "$tpid" ] && continue
      [ -n "$rterm" ] && [ "$rterm" != "0" ] && kill -0 "$rterm" 2>/dev/null && continue
      rnum=${rtty//[^0-9]/}; [ -n "$rnum" ] || rnum=99999
      d=$(( rnum > mytty ? rnum - mytty : mytty - rnum ))
      (( d < bestd )) && { bestd=$d; best=$f; }
    done
    [ -n "$best" ] || return 0
    f=$best
    { read -r rcwd; read -r rtag; read -r rterm; read -r rtty } < "$f" 2>/dev/null
    id=${f:t}
    local -a tr
    tr=( "$HOME"/.claude/projects/*/"$id".jsonl(N) )
    (( ${#tr} )) || { rm -f "$f"; continue; }
    mv "$f" "$claimed/$id" 2>/dev/null || continue
    local model effort
    model=$(tail -n 200 "${tr[1]}" | jq -r '.message.model // empty' 2>/dev/null | grep '^claude-' | tail -1)
    effort=$(tail -n 200 "${tr[1]}" | jq -r 'select(.type=="assistant") | .effort // empty' 2>/dev/null | grep -E '^(low|medium|high|xhigh|max)$' | tail -1)
    local -a args
    args=(--dangerously-skip-permissions --resume "$id")
    [ -n "$model" ] && args+=(--model "$model")
    [ -n "$effort" ] && args+=(--effort "$effort")
    echo "→ restoring session ${id:0:8}… (${rtag}${model:+ · $model}${effort:+ · $effort})"
    if [ -n "$CLAUDE_AUTOCLAIM_DRYRUN" ]; then
      echo "DRYRUN tag=$rtag args: ${args[*]}"
      return 0
    fi
    if [ "$rtag" = "base" ]; then
      command claude "${args[@]}"
    else
      _claude_profile_launch "$rtag" "${args[@]}"
    fi
    return 0
  done
  return 0
}

claude-doctor() {
  local t
  _claude_transcript_timefix
  _claude_transcript_dedupe
  find "$HOME/.claude-profiles/claimed" -type f -mtime +7 -delete 2>/dev/null
  find "$HOME/.claude-profiles/live" -type f -mmin +1440 -delete 2>/dev/null
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
