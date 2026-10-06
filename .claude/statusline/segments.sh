# Colors and segment builders for the statusline. Source this file; don't execute it.
# Each segment_* function prints its piece (or nothing when there is nothing to show).

statusline_dir="$(dirname "${BASH_SOURCE[0]}")"

# ANSI colors, named to match the zsh prompt theme (robbyrussell) they mirror.
green="\033[32m"
dark_green="\033[38;2;38;150;62m"
cyan="\033[36m"
white="\033[37m"
red="\033[31m"
yellow="\033[33m"
orange="\033[38;2;217;119;87m"
grey="\033[90m"
reset="\033[0m"
sep="${grey} | ${reset}"

# Format a token count as e.g. "1.2k" once it hits four digits.
format_k() {
  echo "${1}" | awk '{if($1>=1000) printf "%.1fk", $1/1000; else printf "%d", $1}'
}

# One piece of the second line: separator + orange text (%b, so it may carry
# color codes). Args: text.
segment() {
  printf "${sep}${orange}%b${reset}" "${1}"
}

# Time left until the warm 1h prompt cache goes cold, e.g. "42m17s".
# Args: warm ("true"/"false") expires_at (epoch seconds).
segment_cache() {
  { [ "${1}" = "true" ] && [ -n "${2}" ]; } || return 0
  local remaining=$(( ${2} - $(date +%s) ))
  [ "${remaining}" -gt 0 ] || return 0
  segment "$(awk -v s="${remaining}" 'BEGIN{printf "%dm%02ds", int(s/60), s%60}')"
}

# Fixed-width bar for a percentage, one block per 5%. Filled blocks are green
# (yellow above 50%, red above 80%), empty ones white. Emits color codes, so
# print it through %b. Args: pct.
progress_bar() {
  local width=20 filled=$(( ${1} / 5 )) fill_color="${dark_green}" filled_part="" empty_part="" i
  [ "${filled}" -gt "${width}" ] && filled="${width}"
  if [ "${1}" -gt 80 ]; then fill_color="${red}"; elif [ "${1}" -gt 50 ]; then fill_color="${yellow}"; fi
  for (( i = 0; i < width; i++ )); do
    if [ "${i}" -lt "${filled}" ]; then filled_part="${filled_part}■"; else empty_part="${empty_part}■"; fi
  done
  echo "${fill_color}${filled_part}${white}${empty_part}${orange}"
}

# Context-window usage, e.g. "<bar> 25% | 50.0k/200.0k". Args: used_tokens window_size.
segment_context() {
  local used="${1}" size="${2}"
  # `/context` and auto-compact both treat autoCompactWindow (when set) as the
  # effective max, not the model's raw context_window_size - our gateway's
  # raw value doesn't match what the rest of Claude Code reports as "full".
  # Read the live setting so this tracks the user's settings.json, not a
  # hardcoded number, and recompute the percentage against the same max
  # rather than trusting context_window.used_percentage (which is derived
  # from the raw size).
  local override
  override=$(jq -r '.autoCompactWindow // empty' ~/.claude/settings.json 2>/dev/null)
  [ -n "${override}" ] && size="${override}"

  { [ -n "${used}" ] && [ -n "${size}" ] && [ "${size}" != "0" ]; } || return 0
  local pct
  pct=$(awk -v u="${used}" -v t="${size}" 'BEGIN{printf "%d", (u/t)*100}')
  segment "$(progress_bar "${pct}") ${pct}%${sep}${orange}$(format_k "${used}")/$(format_k "${size}")"
}

# Session cost plus today's recomputed total, each shown only when > 0.
# Args: session_cost_usd.
segment_cost() {
  local session
  session=$(echo "${1}" | awk '{if($1+0>0) printf "$%.2f", $1}')
  [ -n "${session}" ] && segment "${session}"

  # pricing.sh keeps an incremental per-file byte-offset cache
  # (/tmp/claude_daily_cost_state.json), so even at refreshInterval=1 it only
  # prices bytes appended since its last run. Model rates live in
  # model-pricing.csv. It returns "cost|flag"; the flag is "?" when today's
  # usage included a model our pricing table doesn't recognize.
  local daily cost flag
  daily=$(bash "${statusline_dir}/pricing.sh")
  cost="${daily%%|*}"
  flag="${daily#*|}"
  if [ -n "${cost}" ] && awk -v c="${cost}" 'BEGIN{exit !(c+0>0)}'; then
    local fmt
    fmt=$(printf "\$%.2f" "${cost}")
    [ "${flag}" = "?" ] && fmt="${fmt}?"
    segment "${fmt}"
  fi
}

# Total tokens used today across all sessions, from Claude Code's stats cache.
segment_daily_tokens() {
  local tokens
  tokens=$(jq --arg date "$(date +%Y-%m-%d)" '
    (.dailyModelTokens // [])[] | select(.date == $date) | .tokensByModel | to_entries | map(.value) | add // 0
  ' ~/.claude/stats-cache.json 2>/dev/null)
  case "${tokens}" in
    "" | 0 | null) return 0 ;;
  esac
  segment "$(format_k "${tokens}")"
}

# " git:(branch)" plus a ✗ when dirty; nothing outside a repository. Args: cwd.
segment_git() {
  local branch
  branch=$(git --no-optional-locks -C "${1}" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "${branch}" ] || return 0
  printf " ${grey}git:(${red}%s${grey})${reset}" "${branch}"
  if [ -n "$(git --no-optional-locks -C "${1}" status --porcelain 2>/dev/null | head -1)" ]; then
    printf " ${yellow}✗${reset}"
  fi
}
