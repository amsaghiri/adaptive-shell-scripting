#!/usr/bin/env bash
# Adaptation triggers. Any one of the four is enough (they are OR-combined).
# Prints the name of the trigger that fired and returns 0, or returns 1.
# Part of the immutable core.
#
# Only observations recorded since the last committed adaptation are considered,
# so failures that an adaptation already answered do not fire again.

ass_epoch_observations() {
  tail -n +"$(( $(ass_meta_get epoch_start) + 1 ))" "$ASS_STATE_DIR/observations.jsonl"
}

ass_check_triggers() {
  local obs n
  obs="$(ass_epoch_observations)"
  n="$(printf '%s' "$obs" | grep -c . || true)"
  [ "$n" -gt 0 ] || return 1

  # T1: N consecutive failures.
  if [ "$n" -ge "$ASS_CONSECUTIVE_FAILURES" ] && \
     printf '%s\n' "$obs" | tail -n "$ASS_CONSECUTIVE_FAILURES" | jq -se 'all(.[]; .status=="failure")' >/dev/null; then
    echo "consecutive_failures"; return 0
  fi

  # T2: failure rate over a sliding window of runs.
  if [ "$n" -ge "$ASS_WINDOW" ] && \
     printf '%s\n' "$obs" | tail -n "$ASS_WINDOW" | jq -se --argjson pct "$ASS_WINDOW_FAILURE_RATE" \
       '([.[]|select(.status=="failure")]|length) * 100 >= (length * $pct)' >/dev/null; then
    echo "failure_rate"; return 0
  fi

  # T3: the last run failed with a recognised error pattern.
  # Set ASS_ERROR_REGEX to an empty string to switch this trigger off.
  if [ -n "$ASS_ERROR_REGEX" ] && printf '%s\n' "$obs" | tail -n 1 | jq -e --arg re "$ASS_ERROR_REGEX" \
       '.status=="failure" and (.error|test($re))' >/dev/null; then
    echo "error_pattern"; return 0
  fi

  # T4: the last run succeeded but took more than K times the baseline, where
  # the baseline is the mean runtime of the previous successful runs.
  if printf '%s\n' "$obs" | jq -se --argjson k "$ASS_SLOWDOWN_FACTOR" \
       --argjson m "$ASS_BASELINE_RUNS" --argjson min "$ASS_BASELINE_MIN_RUNS" '
       (.[-1]) as $last
       | ([.[0:-1][]|select(.status=="success")|.duration_s] | .[-$m:]) as $base
       | $last.status=="success" and ($base|length) >= $min
         and $last.duration_s > $k * (($base|add) / ($base|length))' >/dev/null; then
    echo "performance_degradation"; return 0
  fi
  return 1
}
