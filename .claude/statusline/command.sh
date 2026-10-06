#!/bin/bash
# Claude Code statusline. Reads the session JSON from stdin and prints two
# lines: directory + git on the first, then model/usage/cost segments on the second.
# Colors and segment builders live in segments.sh.
source "$(dirname "${BASH_SOURCE[0]}")/segments.sh"

# Pull out the fields we display in a single jq pass (one per line, in order).
{
  read -r cwd
  read -r model
  read -r effort
  read -r total_cost_usd
  read -r total_input_tokens
  read -r ctx_window_size
  read -r cache_warm
  read -r cache_expires_at
} < <(jq -r '
  .cwd,
  .model.display_name,
  (.effort.level // ""),
  (.cost.total_cost_usd // ""),
  (.context_window.total_input_tokens // ""),
  (.context_window.context_window_size // ""),
  (.prompt_cache.warm // false),
  (.prompt_cache.expires_at // "")
')

# First line: arrow + current directory + git branch.
printf -v location_line "${green}➜${reset}  ${cyan}%s${reset}%s" "${cwd/#$HOME/~}" "$(segment_git "${cwd}")"

# Second line: model, effort, context usage, today's tokens, costs, cache timer.
usage_line=$(
  printf "${orange}%s${reset}" "${model}"
  [ -n "${effort}" ] && segment "${effort}"
  segment_context "${total_input_tokens}" "${ctx_window_size}"
  segment_daily_tokens
  segment_cost "${total_cost_usd}"
  segment_cache "${cache_warm}" "${cache_expires_at}"
)

printf "%s\n%s\n" "${location_line}" "${usage_line}"
