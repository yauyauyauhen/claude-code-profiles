#!/bin/bash
# Claude Code statusline: three dim rows.
#   1  model · effort | ctx used | prompt-cache warmth | session cost
#   2  account tag | 5h usage | weekly buckets (session model's bucket first)
#   3  [dirty/unpushed/unmerged] | branch [· worktree] | repo   (or bare path)
# Every segment hides when it has nothing to say; a clean synced repo on a
# default session renders just "⎇ main | myrepo".
#
# Register in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
context_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
five_hour_used=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day_used=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# --- shared per-account usage cache ---
# The background usage poll (below) stores the full usage-API response per
# account. When fresh (<5 min), row 2 renders 5h/wk from it instead of the
# session-fed rate_limits: every terminal of the same account then shows the
# same account-true numbers, kept fresh by whichever session is active.
# Stale/missing cache -> session feed.
_iso2epoch() {
  date -ju -f '%Y-%m-%dT%H:%M:%S' "$(printf '%s' "$1" | sed -E 's/\.[0-9]+//; s/(\+00:00|Z)$//')" +%s 2>/dev/null
}
_usage_suffix=""
[ -n "$CLAUDE_CONFIG_DIR" ] && _usage_suffix="-${CLAUDE_CONFIG_DIR##*/.claude-}"
_tmpdir="${TMPDIR:-/tmp}"; _tmpdir="${_tmpdir%/}"
_usage_cache=${_tmpdir}/claude-usage-cache${_usage_suffix}.json
_usage_stamp=${_tmpdir}/claude-usage-cache${_usage_suffix}.stamp
if [ -f "$_usage_cache" ] && [ $(( $(date +%s) - $(stat -f %m "$_usage_cache" 2>/dev/null || echo 0) )) -lt 300 ]; then
  _crow=$(jq -r '[(.five_hour.utilization // ""), (.five_hour.resets_at // ""), (.seven_day.utilization // ""), (.seven_day.resets_at // "")] | @tsv' "$_usage_cache" 2>/dev/null)
  IFS=$'\t' read -r _c5u _c5r _c7u _c7r <<< "$_crow"
  if [ -n "$_c5u" ]; then
    five_hour_used=$_c5u
    _e=$(_iso2epoch "$_c5r"); [ -n "$_e" ] && five_hour_resets=$_e
  fi
  if [ -n "$_c7u" ]; then
    seven_day_used=$_c7u
    _e=$(_iso2epoch "$_c7r"); [ -n "$_e" ] && seven_day_resets=$_e
  fi
fi

DIM=$'\033[2m'
RESET=$'\033[0m'
SEP="${DIM} | ${RESET}"

if [ -n "$context_pct" ]; then
  context_used=$(awk -v r="$context_pct" 'BEGIN{printf "%.0f", 100 - r}')
  context_str="${context_used}% ctx"
else
  context_str="n/a ctx"
fi

if [ -n "$cost" ]; then
  cost_str=$(printf '$%.2f' "$cost")
else
  cost_str='$0.00'
fi

# --- prompt-cache warmth ---
# The server-side prompt cache for this conversation expires 1h after the
# last request (the subscription TTL). Warm renders as "3:19am · warm"
# (cached until then; the next message re-reads history at a fraction of the
# cost); expired renders as "cold" (the next message re-ingests the full
# history — also the cheap moment to /compact). Approximate on purpose:
# overage can drop the TTL, and a CLI update or CLAUDE.md edit can miss a
# live entry; neither is knowable from here. No transcript yet -> absent.
cache_str=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  # File mtime is NOT the anchor: resuming a session appends meta lines
  # (file-history snapshots, summaries) with no API request, which would show
  # a re-warmed cache that doesn't exist. Anchor to the last assistant
  # entry's own timestamp, written exactly when a response landed = cache
  # written. grep+tail keeps it O(tail) cheap on huge transcripts; mtime is
  # the fallback.
  _last_req_iso=$(tail -c 2000000 "$transcript_path" 2>/dev/null | grep '"type":"assistant"' | tail -1 | jq -r '.timestamp // empty' 2>/dev/null)
  _t_mtime=""
  [ -n "$_last_req_iso" ] && _t_mtime=$(_iso2epoch "$_last_req_iso")
  [ -n "$_t_mtime" ] || _t_mtime=$(stat -f %m "$transcript_path" 2>/dev/null || echo 0)
  if [ "$_t_mtime" -gt 0 ]; then
    _cache_exp=$((_t_mtime + 3600))
    if [ "$(date +%s)" -lt "$_cache_exp" ]; then
      _exp_time=$(date -r "$_cache_exp" '+%-I:%M%p' 2>/dev/null | tr '[:upper:]' '[:lower:]')
      cache_str="${_exp_time:+${_exp_time} · }warm"
    else
      cache_str="cold"
    fi
  fi
fi

# Strip a trailing parenthetical mentioning "context", e.g. " (1M context)".
model=$(printf '%s' "$model" | sed -E 's/[[:space:]]*\([^()]*[Cc][Oo][Nn][Tt][Ee][Xx][Tt][^()]*\)[[:space:]]*$//')
model=$(printf '%s' "$model" | sed -E 's/[[:space:]]+[0-9]+[A-Za-z]*([[:space:]]+[Mm][Ii][Ll][Ll][Ii][Oo][Nn])?[[:space:]]+[Cc][Oo][Nn][Tt][Ee][Xx][Tt][[:space:]]*$//')
model=$(printf '%s' "$model" | sed -E 's/[[:space:]]+$//')

model_str="$model"
if [ -n "$effort_level" ]; then
  model_str="${model_str} · ${effort_level}"
fi

# Assert this pane's marked window title on every render, written straight to
# the tty device: folder name + an INVISIBLE zero-width tty marker. This is
# the marker channel for exact session restore (see profiles.zsh) and for
# agent-notify's window targeting. Doing it in the statusline (not the shell)
# covers EVERY claude pane regardless of launcher, and Ghostty preserves
# zero-width chars in titles though it strips them from on-screen text.
# Encoding: U+2060, 12 bits U+200B(0)/U+200C(1) MSB-first, U+2060.
if [ "$TERM_PROGRAM" = "ghostty" ] && [ -n "$current_dir" ]; then
  _ppid=$PPID _ptty=""
  for _hop in 1 2 3; do
    _ptty=$(ps -o tty= -p "$_ppid" 2>/dev/null | tr -d ' ')
    [ -n "$_ptty" ] && [ "$_ptty" != "??" ] && break
    _ppid=$(ps -o ppid= -p "$_ppid" 2>/dev/null | tr -d ' ')
    [ -n "$_ppid" ] || break
  done
  _pnum=${_ptty//[^0-9]/}; [ "$_ptty" = "??" ] && _pnum=""
  if [ -n "$_pnum" ] && [ -w "/dev/$_ptty" ]; then
    _ZB=$'\xe2\x80\x8b' _ZC=$'\xe2\x80\x8c' _ZJ=$'\xe2\x81\xa0'
    _pnum=$((10#$_pnum)); _tmark=$_ZJ
    for _i in 11 10 9 8 7 6 5 4 3 2 1 0; do
      if [ $(( (_pnum >> _i) & 1 )) -eq 1 ]; then _tmark+=$_ZC; else _tmark+=$_ZB; fi
    done
    _tmark+=$_ZJ
    printf '\033]2;%s%s\007' "${current_dir##*/}" "$_tmark" > "/dev/$_ptty" 2>/dev/null
  fi
fi

fields=("${DIM}${model_str}${RESET}" "${DIM}${context_str}${RESET}")
[ -n "$cache_str" ] && fields+=("${DIM}${cache_str}${RESET}")
fields+=("${DIM}${cost_str}${RESET}")
limit_fields=()

# --- account tag ---
# Wrapped sessions: tag = CLAUDE_CONFIG_DIR basename minus ".claude-".
# Bare/backbone sessions: "base <tag>" DERIVED from the logged-in email in
# ~/.claude.json via ~/.claude/profiles.conf (never assumed), mtime-cached
# because the file is large; unmapped emails show their local part.
profile_tag=""
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
  profile_tag="${CLAUDE_CONFIG_DIR##*/.claude-}"
else
  _cj="$HOME/.claude.json"
  _conf="$HOME/.claude/profiles.conf"
  if [ -f "$_cj" ] && [ -f "$_conf" ]; then
    _bt_cache=${_tmpdir}/claude-backbone-tag.cache
    _cj_m=$(stat -f %m "$_cj" 2>/dev/null)
    _bt_line=$(cat "$_bt_cache" 2>/dev/null)
    if [ -n "$_cj_m" ] && [ "${_bt_line%% *}" = "$_cj_m" ]; then
      _bt_tag="${_bt_line#* }"
    else
      _email=$(jq -r '.oauthAccount.emailAddress // empty' "$_cj" 2>/dev/null)
      _bt_tag=""
      if [ -n "$_email" ]; then
        _bt_tag=$(awk -v e="$_email" '!/^[[:space:]]*#/ && $2==e {print $1; exit}' "$_conf")
        [ -n "$_bt_tag" ] || _bt_tag="${_email%%@*}"
      fi
      echo "$_cj_m $_bt_tag" > "$_bt_cache" 2>/dev/null
    fi
    [ -n "$_bt_tag" ] && profile_tag="base $_bt_tag"
  fi
fi
[ -n "$profile_tag" ] && limit_fields+=("${DIM}${profile_tag}${RESET}")

# Reset clocks ceil to the next half-hour: a clock may read late, never
# early, so checking at the shown time always finds the window reset.
_ceil30() { echo $(( ($1 + 1799) / 1800 * 1800 )); }
_clock() { date -r "$1" '+%-I:%M%p' 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/:00//'; }

if [ -n "$five_hour_used" ]; then
  five_hour_pct=$(awk -v u="$five_hour_used" 'BEGIN{printf "%.0f", u}')
  five_hour_str="5h: ${five_hour_pct}%"
  if [ -n "$five_hour_resets" ]; then
    five_hour_epoch=$(awk -v t="$five_hour_resets" 'BEGIN{printf "%.0f", t}')
    five_hour_time=$(_clock "$(_ceil30 "$five_hour_epoch")")
    [ -n "$five_hour_time" ] && five_hour_str="${five_hour_str} (${five_hour_time})"
  fi
  limit_fields+=("${DIM}${five_hour_str}${RESET}")
fi

# The weekly buckets (wk + any model-scoped ones) are built as pct string +
# detached reset part first, appended in a model-dependent order below; the
# append step decides which reset clock actually renders.
seven_day_str="" seven_day_ceil=0 seven_day_reset=""
if [ -n "$seven_day_used" ]; then
  seven_day_pct=$(awk -v u="$seven_day_used" 'BEGIN{printf "%.0f", u}')
  seven_day_str="wk: ${seven_day_pct}%"
  if [ -n "$seven_day_resets" ]; then
    seven_day_epoch=$(awk -v t="$seven_day_resets" 'BEGIN{printf "%.0f", t}')
    seven_day_ceil=$(_ceil30 "$seven_day_epoch")
    seven_day_weekday=$(date -r "$seven_day_ceil" '+%a' 2>/dev/null)
    seven_day_clock=$(_clock "$seven_day_ceil")
    [ -n "$seven_day_weekday" ] && [ -n "$seven_day_clock" ] && seven_day_reset=" (${seven_day_weekday} ${seven_day_clock})"
  fi
fi

# --- model-scoped weekly buckets ---
# Some accounts carry per-model weekly limits that the statusline feed does
# not expose; the usage API's `limits` array does (kind "weekly_scoped").
# Rendered from the same cache. A bucket whose cached reset has already
# passed is HIDDEN rather than shown: the poll only writes on success
# (expired token / offline leaves the file in place), so that pct belongs to
# a dead window; the next successful poll restores the bucket.
_scoped_rows=$(jq -r '(.limits // [])[] | select(.kind=="weekly_scoped" and (.scope.model.display_name // "") != "") | [(.scope.model.display_name | ascii_downcase), .percent, (.resets_at // "")] | @tsv' "$_usage_cache" 2>/dev/null)
scoped_strs=() scoped_ceils=() scoped_resets=()
scoped_session_idx=""
_model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
_now_epoch=$(date +%s)
if [ -n "$_scoped_rows" ]; then
  while IFS=$'\t' read -r _sname _spct _sreset; do
    [ -n "$_sname" ] || continue
    _sepoch=$(_iso2epoch "$_sreset")
    [ -n "$_sepoch" ] && [ "$_sepoch" -le "$_now_epoch" ] && continue
    _sstr="${_sname}: $(awk -v u="$_spct" 'BEGIN{printf "%.0f", u}')%"
    _sceil=0 _srst=""
    if [ -n "$_sepoch" ]; then
      _sceil=$(_ceil30 "$_sepoch")
      _swd=$(date -r "$_sceil" '+%a' 2>/dev/null)
      _sck=$(_clock "$_sceil")
      [ -n "$_swd" ] && [ -n "$_sck" ] && _srst=" (${_swd} ${_sck})"
    fi
    scoped_strs+=("$_sstr") scoped_ceils+=("$_sceil") scoped_resets+=("$_srst")
    # The bucket scoped to the SESSION's model (name-contained either way,
    # e.g. bucket "fable" in a "Fable 5" session) gets promoted below.
    if [ -z "$scoped_session_idx" ]; then
      case "$_model_lc" in
        *"$_sname"*) scoped_session_idx=$(( ${#scoped_strs[@]} - 1 )) ;;
        *) case "$_sname" in *"$_model_lc"*) scoped_session_idx=$(( ${#scoped_strs[@]} - 1 )) ;; esac ;;
      esac
    fi
  done <<< "$_scoped_rows"
fi

# Weekly-bucket order: a session running a model with its own weekly bucket
# promotes that bucket next to 5h, where the binding limit belongs; wk and
# the other buckets follow. The second-position weekly bucket always carries
# its reset clock; later buckets repeat one only when their CEILED reset
# actually differs (all ride the same weekly cycle anchor, so one clock
# normally covers them, and raw resets minutes apart would render identically
# anyway). Session model with no scoped bucket in the cache -> wk keeps
# second position and its clock, the old layout exactly.
_emit_scoped() {  # append all scoped buckets except index $1, clocks deduped against ceil $2
  local _skip=$1 _anchor=$2 _i _rst
  for (( _i=0; _i<${#scoped_strs[@]}; _i++ )); do
    [ "$_i" = "$_skip" ] && continue
    _rst=${scoped_resets[$_i]}
    [ "${scoped_ceils[$_i]}" = "$_anchor" ] && _rst=""
    limit_fields+=("${DIM}${scoped_strs[$_i]}${_rst}${RESET}")
  done
}
if [ -n "$scoped_session_idx" ]; then
  _anchor_ceil=${scoped_ceils[$scoped_session_idx]}
  limit_fields+=("${DIM}${scoped_strs[$scoped_session_idx]}${scoped_resets[$scoped_session_idx]}${RESET}")
  if [ -n "$seven_day_str" ]; then
    _rst=$seven_day_reset
    [ "$seven_day_ceil" = "$_anchor_ceil" ] && _rst=""
    limit_fields+=("${DIM}${seven_day_str}${_rst}${RESET}")
  fi
  _emit_scoped "$scoped_session_idx" "$_anchor_ceil"
else
  [ -n "$seven_day_str" ] && limit_fields+=("${DIM}${seven_day_str}${seven_day_reset}${RESET}")
  _emit_scoped "" "$seven_day_ceil"
fi

# Background refresh of the usage cache, at most every ~2 min, never blocking
# the render. Reads THIS profile's OAuth token from its keychain slot: with
# CLAUDE_CONFIG_DIR set, Claude Code stores credentials under the service
# name "Claude Code-credentials-<first 8 hex of sha256(config dir path)>";
# the default session uses the unsuffixed name. Note: the usage endpoint is
# unofficial and may change without notice; the segment degrades to absent.
_usage_now=$(date +%s)
_usage_last=$(cat "$_usage_stamp" 2>/dev/null || echo 0)
if [ $((_usage_now - _usage_last)) -ge 120 ]; then
  echo "$_usage_now" > "$_usage_stamp" 2>/dev/null
  (
    _svc="Claude Code-credentials"
    [ -n "$CLAUDE_CONFIG_DIR" ] && _svc="${_svc}-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
    _tok=$(security find-generic-password -s "$_svc" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty')
    if [ -n "$_tok" ]; then
      _resp=$(curl -s --max-time 8 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $_tok" -H "anthropic-beta: oauth-2025-04-20")
      printf '%s' "$_resp" | jq -e '.five_hour' >/dev/null 2>&1 && printf '%s' "$_resp" > "$_usage_cache"
    fi
  ) &
  disown 2>/dev/null || true
fi

# --- git row: state cluster | branch [· worktree] | repo name ---
# `--no-optional-locks` so the statusline never grabs an index lock mid-op.
git_line=""
if [ -n "$current_dir" ]; then
  git_info=$(git -C "$current_dir" --no-optional-locks rev-parse --path-format=absolute --git-dir --git-common-dir --abbrev-ref HEAD 2>/dev/null)
  if [ -z "$git_info" ]; then
    # Non-git directory: row 3 still answers "where am I". Name first so it
    # survives right-edge truncation, then the tilde path.
    git_line="$(basename "$current_dir") | ${current_dir/#$HOME/~}"
  else
    git_dir=$(printf '%s\n' "$git_info" | sed -n 1p)
    common_dir=$(printf '%s\n' "$git_info" | sed -n 2p)
    branch=$(printf '%s\n' "$git_info" | sed -n 3p)
    # Detached HEAD reports the literal string "HEAD": show the short SHA.
    [ "$branch" = "HEAD" ] && branch=$(git -C "$current_dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    git_line="⎇ ${branch}"
    [ "$git_dir" != "$common_dir" ] && git_line="${git_line} · worktree: $(basename "$git_dir")"
    # Repo name from the MAIN checkout (parent of the shared .git), so every
    # worktree shows the repo's one identity; the worktree suffix says which
    # copy.
    git_line="${git_line} | $(basename "$(dirname "$common_dir")")"

    # State cluster prepended to the branch: ✎ dirty · ↑N unpushed · ∆N unmerged.
    #   ✎  uncommitted changes (incl. untracked) — the fragile state
    #   ↑N commits reachable from HEAD that NO remote has — exist only here.
    #      Skipped when the repo has no remotes (every commit would count).
    #   ∆N commits not yet in local main (master fallback) — pushed-but-
    #      unlanded work. Hidden when equal to ↑ (pre-push both count the
    #      same set) and at zero, so it surfaces exactly when work is pushed
    #      and awaiting merge.
    git_state=""
    dirty=$(git -C "$current_dir" --no-optional-locks status --porcelain 2>/dev/null | head -1)
    [ -n "$dirty" ] && git_state="✎"
    unpushed=""
    if [ -n "$(git -C "$current_dir" --no-optional-locks remote 2>/dev/null)" ]; then
      unpushed=$(git -C "$current_dir" --no-optional-locks rev-list --count HEAD --not --remotes 2>/dev/null)
      if [ -n "$unpushed" ] && [ "$unpushed" -gt 0 ] 2>/dev/null; then
        git_state="${git_state:+${git_state} }↑${unpushed}"
      fi
    fi
    unmerged=""
    for merge_base in main master; do
      git -C "$current_dir" --no-optional-locks rev-parse --verify -q "refs/heads/${merge_base}" >/dev/null 2>&1 || continue
      unmerged=$(git -C "$current_dir" --no-optional-locks rev-list --count "${merge_base}..HEAD" 2>/dev/null)
      break
    done
    if [ -n "$unmerged" ] && [ "$unmerged" -gt 0 ] 2>/dev/null && [ "$unmerged" != "$unpushed" ]; then
      git_state="${git_state:+${git_state} }∆${unmerged}"
    fi
    [ -n "$git_state" ] && git_line="${git_state} | ${git_line}"
  fi
fi

join_fields() {
  local out="" f
  for f in "$@"; do
    if [ -z "$out" ]; then out="$f"; else out="${out}${SEP}${f}"; fi
  done
  printf '%s' "$out"
}

printf '%s\n' "$(join_fields "${fields[@]}")"
if [ ${#limit_fields[@]} -gt 0 ]; then
  printf '%s\n' "$(join_fields "${limit_fields[@]}")"
fi
if [ -n "$git_line" ]; then
  printf '%s\n' "${DIM}${git_line}${RESET}"
fi
