#!/bin/bash
# Read the session JSON Claude Code passes on stdin and pull out the fields we display.
input=$(cat)
cwd=$(echo "${input}"    | jq -r '.cwd')
model=$(echo "${input}"  | jq -r '.model.display_name')
total_cost_usd=$(echo "${input}" | jq -r '.cost.total_cost_usd // empty')
used_pct_raw=$(echo "${input}" | jq -r '.context_window.used_percentage // empty')
total_input_tokens=$(echo "${input}" | jq -r '.context_window.total_input_tokens // empty')
ctx_window_size=$(echo "${input}" | jq -r '.context_window.context_window_size // empty')

# "cur" cost: Claude Code's own reported cost for the current session.
cost=$(echo "${total_cost_usd}" | awk '{if($1+0>0) printf "$%.4f", $1}')

today=$(date +%Y-%m-%d)
# Total tokens used today across all sessions, from Claude Code's own stats cache.
daily_tokens=$(jq --arg date "${today}" '
  (.dailyModelTokens // [])[] | select(.date == $date) | .tokensByModel | to_entries | map(.value) | add // 0
' ~/.claude/stats-cache.json 2>/dev/null)

# "tot" cost: our own recomputed daily total, cached since scanning every JSONL
# transcript on each statusline redraw would be too slow to run live. Invalidated
# by data (any today's transcript touched since the cache was written), not by a
# fixed TTL, so it can't lag behind "cur" after a new message lands.
daily_cost_cache=/tmp/claude_daily_cost_cache
daily_cost=""
if [ -f "${daily_cost_cache}" ]; then
  cache_line=$(cat "${daily_cost_cache}")
  cache_date="${cache_line%% *}"
  stale=$(find ~/.claude/projects -name "*.jsonl" -newer "${daily_cost_cache}" -newermt "${today} 00:00:00" -print -quit 2>/dev/null)
  if [ "${cache_date}" = "${today}" ] && [ -z "${stale}" ]; then
    daily_cost="${cache_line#* }"
  fi
fi
if [ -z "${daily_cost}" ]; then
  # Cache miss/expired: recompute from today's JSONL transcripts.
  # jq extracts per-message token counts (input/output/cache-write by TTL/cache-read);
  # awk prices each model at its official per-MTok rate and sums the total.
  # Any model string that matches none of the known models is flagged with a
  # trailing "?" so an unpriced/unrecognized model doesn't silently show as $0.
  jq_usage_filter=$(cat <<'JQ_FILTER'
select(.timestamp != null and (.timestamp | startswith($today)) and .message.usage != null) |
[.message.model, .message.usage.input_tokens, .message.usage.output_tokens,
 (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
 (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
 .message.usage.cache_read_input_tokens] | @tsv
JQ_FILTER
)
  awk_pricing_script=$(cat <<'AWK_SCRIPT'
{
  model=$1; inp=$2+0; outp=$3+0; cw1h=$4+0; cw5m=$5+0; cr=$6+0
  if (model == "claude-opus-5-5")   { ir=4; or=20; cwr1h=8;   cwr5m=5;   crr=0.2 }
  else if (model == "claude-opus-5"){ ir=5; or=25; cwr1h=10;  cwr5m=6.25;crr=0.5 }
  else if (model == "claude-haiku-4-5" || model == "anthropic.claude-haiku-4-5-20251001-v1:0") { ir=1; or=5;  cwr1h=2;  cwr5m=1.25;crr=0.1 }
  else if (model == "claude-sonnet-5")  { ir=2; or=10; cwr1h=4;  cwr5m=2.5; crr=0.2 }
  else if (model == "<synthetic>") { ir=0; or=0; cwr1h=0; cwr5m=0; crr=0 }
  else                      { ir=0; or=0;  cwr1h=0; cwr5m=0; crr=0; unrecognized=1 }
  total += (inp*ir + outp*or + cw1h*cwr1h + cw5m*cwr5m + cr*crr)/1000000
}
END { printf "%.4f|%s", total, (unrecognized ? "?" : "") }
AWK_SCRIPT
)
  daily_cost=$(find ~/.claude/projects -name "*.jsonl" -newermt "${today} 00:00:00" 2>/dev/null | \
    xargs -I{} jq -r --arg today "${today}" "${jq_usage_filter}" {} 2>/dev/null | \
    awk -F'\t' "${awk_pricing_script}")
  echo "${today} ${daily_cost}" > "${daily_cost_cache}"
fi

# Git branch + dirty status for the current working directory.
branch=$(git --no-optional-locks -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
git_dirty=$(git --no-optional-locks -C "${cwd}" status --porcelain 2>/dev/null | head -1)
display_dir="${cwd/#$HOME/~}"

# Left side of the statusline: arrow + current directory.
printf -v output "\033[32m➜\033[0m  \033[36m%s\033[0m" "${display_dir}"

if [ -n "${branch}" ]; then
  if [ -n "${git_dirty}" ]; then
    printf -v branch_part " \033[34mgit:(\033[31m%s\033[34m)\033[0m \033[33m✗\033[0m" "${branch}"
  else
    printf -v branch_part " \033[34mgit:(\033[31m%s\033[34m)\033[0m" "${branch}"
  fi
  output="${output}${branch_part}"
fi

# Format a token count as e.g. "1.2k" once it hits four digits.
format_k() {
  echo "${1}" | awk '{if($1>=1000) printf "%.1fk", $1/1000; else printf "%d", $1}'
}

orange="\033[33m"
grey="\033[90m"
reset="\033[0m"
sep="${grey} | ${reset}"

# Right side of the statusline, built up piece by piece: model name, then
# context-window usage, then today's total tokens, then cur/tot cost.
printf -v bracket "${orange}%s${reset}" "${model}"

# Context window usage for the current session, e.g. "ctx 50.0k/200.0k (25%)".
if [ -n "${total_input_tokens}" ] && [ -n "${ctx_window_size}" ] && [ "${ctx_window_size}" != "0" ]; then
  tokens_used_fmt=$(format_k "${total_input_tokens}")
  tokens_total_fmt=$(format_k "${ctx_window_size}")
  used_pct=$(echo "${used_pct_raw}" | awk '{printf "%d", $1}')
  printf -v ctx_part "${sep}${orange}ctx %s/%s (%s%%)${reset}" "${tokens_used_fmt}" "${tokens_total_fmt}" "${used_pct}"
  bracket="${bracket}${ctx_part}"
fi

# Total tokens used today across all sessions.
if [ -n "${daily_tokens}" ] && [ "${daily_tokens}" != "0" ] && [ "${daily_tokens}" != "null" ]; then
  daily_tokens_fmt=$(format_k "${daily_tokens}")
  printf -v daily_tokens_part "${sep}${orange}%s${reset}" "${daily_tokens_fmt}"
  bracket="${bracket}${daily_tokens_part}"
fi

# Split the cached "cost|flag" pair computed above; the flag is "?" when
# today's usage included a model our pricing table doesn't recognize.
daily_unrecognized="${daily_cost#*|}"
daily_cost="${daily_cost%%|*}"

daily_cost_fmt="\$0.0000"
if [ -n "${daily_cost}" ] && awk -v c="${daily_cost}" 'BEGIN{exit !(c+0>0)}'; then
  daily_cost_fmt=$(printf "\$%.4f" "${daily_cost}")
fi
if [ "${daily_unrecognized}" = "?" ]; then
  daily_cost_fmt="${daily_cost_fmt}?"
fi
# "cur" = this session's cost (from Claude Code), "tot" = our recomputed daily total.
printf -v cost_part "${sep}${orange}cur %s${sep}${orange}tot %s${reset}" "${cost:-\$0.0000}" "${daily_cost_fmt}"
bracket="${bracket}${cost_part}"

printf "%s  ${grey}(${reset}%s${grey})${reset}" "${output}" "${bracket}"
