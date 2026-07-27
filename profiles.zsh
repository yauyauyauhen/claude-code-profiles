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

claude-doctor() {
  local t
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
