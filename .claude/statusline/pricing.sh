#!/bin/bash
# Prices today's Claude Code usage across all session transcripts and prints
# "<total>|<flag>" (flag is "?" if a model with no known price was seen).
#
# Runs every tick of the statusline's refreshInterval, so it must stay cheap:
# each file's already-priced bytes are never re-read. $state_file remembers,
# per transcript, the byte offset up to which it's been priced; each run only
# reads and prices the bytes appended since then. A new day resets the state
# and reprices everything once, after which it's incremental again.
#
# Associative arrays aren't available (macOS ships bash 3.2), so offsets are
# kept as a flat "path<TAB>offset" file and looked up with awk.

today=$(date +%Y-%m-%d)
projects_dir=~/.claude/projects
pricing_table="${pricing_table:-$HOME/.claude/statusline/model-pricing.csv}"

state_file=/tmp/claude_daily_cost_state.json
lock_file=/tmp/claude_daily_cost_state.lock
# Sentinel whose mtime marks "last time we actually scanned transcripts".
# Its own content is unused - only its mtime matters, as a reference point
# for `find -newer`.
scan_sentinel=/tmp/claude_daily_cost_scan_sentinel

old_offsets_tsv=$(mktemp)
new_offsets_tsv=$(mktemp)
chunk_file=$(mktemp)
trap 'rm -f "${old_offsets_tsv}" "${new_offsets_tsv}" "${chunk_file}"' EXIT

# Running totals, seeded from $state_file by load_state.
total=0
unrecognized=false

# --- State ------------------------------------------------------------------

# True when $state_file exists and was written today.
state_is_today() {
  [ -f "${state_file}" ] && [ "$(jq -r '.date' "${state_file}" 2>/dev/null)" = "${today}" ]
}

# Load today's total and unrecognized flag from $state_file, and its
# per-file offsets into $old_offsets_tsv. Leaves the defaults on a new day.
load_state() {
  state_is_today || return 0
  read -r total unrecognized < <(jq -r '[.total, .unrecognized] | @tsv' "${state_file}")
  jq -r '.offsets | to_entries[] | "\(.key)\t\(.value)"' "${state_file}" > "${old_offsets_tsv}"
}

# Rewrite $state_file from the running totals and $new_offsets_tsv.
save_state() {
  local offsets_json
  offsets_json=$(jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) | map({(.[0]): (.[1] | tonumber)}) | add // {}
  ' "${new_offsets_tsv}")

  jq -n --arg date "${today}" --argjson total "${total}" --argjson unrecognized "${unrecognized}" --argjson offsets "${offsets_json}" \
    '{date: $date, total: $total, unrecognized: $unrecognized, offsets: $offsets}' > "${state_file}"
}

# Byte offset already priced for $1, or 0 if never seen.
offset_for() {
  awk -F'\t' -v f="$1" '$1 == f { print $2; found=1 } END { if (!found) print 0 }' "${old_offsets_tsv}"
}

# --- Output -----------------------------------------------------------------

# Print "<total>|<flag>" from the running totals.
print_result() {
  local flag=""
  [ "${unrecognized}" = "true" ] && flag="?"
  printf '%.4f|%s' "${total:-0}" "${flag}"
}

# --- Concurrency and freshness checks ---------------------------------------

# Serialize the read-modify-write of $state_file across concurrent sessions.
# Short timeout so a stuck/held lock degrades to "print last known total"
# instead of hanging the statusline tick. Without flock, runs unlocked.
acquire_lock() {
  exec 9>"${lock_file}"
  ! command -v flock >/dev/null 2>&1 || flock -w 2 9
}

# True when a transcript changed since our last actual scan (or there was
# no scan yet), i.e. the cached total can't be trusted.
transcripts_changed() {
  [ -f "${scan_sentinel}" ] || return 0
  local newer
  newer=$(find "${projects_dir}" -name "*.jsonl" -newer "${scan_sentinel}" -newermt "${today} 00:00:00" -print -quit 2>/dev/null)
  [ -n "${newer}" ]
}

# --- Pricing ----------------------------------------------------------------

# jq: one TSV row per message from today, with its token counts:
# model, input, output, cache-write 1h, cache-write 5m, cache-read.
extract_usage() {
  jq -r --arg today "${today}" '
    select(.timestamp != null and ((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%Y-%m-%d")) == $today) and .message.usage != null) |
    (.message.usage.cache_creation.ephemeral_1h_input_tokens) as $cw1h |
    (.message.usage.cache_creation.ephemeral_5m_input_tokens) as $cw5m |
    (.message.usage.cache_creation_input_tokens) as $flat |
    # Normally the nested ephemeral_1h/5m fields carry the cache-write split.
    # Fall back to the flat (undifferentiated) field only when BOTH nested
    # fields are absent, so a response that has both never double-counts.
    # The flat field has no TTL split, so it is priced at the 5m rate - the
    # more common/conservative default (never seen in practice as of this
    # audit: 0 of 25,906 flat-field lines checked lacked the nested object).
    if ($cw1h == null and $cw5m == null and $flat != null) then
      [.message.model, .message.usage.input_tokens, .message.usage.output_tokens, 0, $flat, .message.usage.cache_read_input_tokens]
    else
      [.message.model, .message.usage.input_tokens, .message.usage.output_tokens, ($cw1h // 0), ($cw5m // 0), .message.usage.cache_read_input_tokens]
    end | @tsv
  ' 2>/dev/null
}

# awk: prices the rows from extract_usage at each model's per-MTok rate
# (loaded from $pricing_table) and prints "<total>|<unrecognized 0/1>".
# A model with no matching row sets unrecognized so it doesn't silently
# show as $0.
price_usage() {
  awk -F'\t' '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s ~ /^".*"$/) { s = substr(s, 2, length(s) - 2) }
      return s
    }
    # First file: the ";"-separated pricing table.
    FNR == NR {
      if ($0 !~ /^#/) {
        n = split($0, f, ";")
        if (n == 6) {
          m = trim(f[1])
          if (m != "model") {
            rate_in[m]=trim(f[2]); rate_out[m]=trim(f[3]); rate_cw1h[m]=trim(f[4]); rate_cw5m[m]=trim(f[5]); rate_cr[m]=trim(f[6])
          }
        }
      }
      next
    }
    # Second file (stdin): usage rows.
    {
      model=$1; inp=$2+0; outp=$3+0; cw1h=$4+0; cw5m=$5+0; cr=$6+0
      if (model in rate_in) {
        total += (inp*rate_in[model] + outp*rate_out[model] + cw1h*rate_cw1h[model] + cw5m*rate_cw5m[model] + cr*rate_cr[model])/1000000
      } else {
        unrecognized=1
      }
    }
    END { printf "%.6f|%s", total, (unrecognized ? "1" : "0") }
  ' "${pricing_table}" -
}

# Price the unpriced bytes of transcript $1 and add them to the running
# totals. Records the new offset for $1 in $new_offsets_tsv.
price_transcript() {
  local file="$1" size offset chunk_bytes priced

  size=$(stat -f%z "${file}" 2>/dev/null || stat -c%s "${file}" 2>/dev/null)
  [ -z "${size}" ] && return 0

  offset=$(offset_for "${file}")
  # File shrank (rotated/truncated): reprice it from the start.
  [ "${size}" -lt "${offset}" ] && offset=0

  if [ "${size}" -gt "${offset}" ]; then
    tail -c "+$((offset + 1))" "${file}" > "${chunk_file}"
    chunk_bytes=$(wc -c < "${chunk_file}")

    # A trailing byte that isn't a newline means the last line is still being
    # written: price only the complete lines before it; the rest is picked up
    # next tick.
    if [ -n "$(tail -c1 "${chunk_file}")" ]; then
      chunk_bytes=$((chunk_bytes - $(tail -n1 "${chunk_file}" | wc -c)))
    fi

    if [ "${chunk_bytes}" -gt 0 ]; then
      priced=$(head -c "${chunk_bytes}" "${chunk_file}" | extract_usage | price_usage)
      total=$(awk -v t="${total}" -v i="${priced%%|*}" 'BEGIN{printf "%.6f", t+i}')
      [ "${priced#*|}" = "1" ] && unrecognized=true
      offset=$((offset + chunk_bytes))
    fi
  fi

  printf '%s\t%s\n' "${file}" "${offset}" >> "${new_offsets_tsv}"
}

# --- Main -------------------------------------------------------------------

# Lock held elsewhere: print the last known total for today (or zero).
if ! acquire_lock; then
  load_state
  print_result
  exit 0
fi

# Fast path: if no transcript has changed since our last actual scan, the
# cached total is still correct - skip find/stat/jq/rewrite entirely.
if state_is_today && ! transcripts_changed; then
  load_state
  print_result
  exit 0
fi

load_state

# Stamp the sentinel's mtime to "now, before we start reading" (not after),
# so any transcript write that lands mid-scan is still newer than the
# sentinel and triggers a full rescan on the next tick instead of being
# missed by the fast path.
touch "${scan_sentinel}"

while IFS= read -r file; do
  price_transcript "${file}"
done < <(find "${projects_dir}" -name "*.jsonl" -newermt "${today} 00:00:00" 2>/dev/null)

save_state
print_result
