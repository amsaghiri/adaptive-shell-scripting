#!/usr/bin/env bash
# Observation layer: run the payload and append one structured record to the
# observation log O. Part of the immutable core.

# Remove control characters and cap the length, so that text produced by the
# payload cannot break the log or smuggle formatting into the LLM prompt.
ass_sanitize() { tr -d '\000-\010\013\014\016-\037\177' | tr '\n\t' '  ' | cut -c1-"${1:-300}"; }

ass_execute_and_observe() {
  local payload="$1" out err rss start end code status duration max_rss error
  out="$(mktemp "$ASS_STATE_DIR/out.XXXXXX")"; err="$(mktemp "$ASS_STATE_DIR/err.XXXXXX")"
  rss="$(mktemp "$ASS_STATE_DIR/rss.XXXXXX")"

  start="$(date +%s.%N)"
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -f '%M' -o "$rss" bash "$payload" >"$out" 2>"$err"; code=$?
  else
    bash "$payload" >"$out" 2>"$err"; code=$?
  fi
  end="$(date +%s.%N)"

  cat "$out"; cat "$err" >&2
  duration="$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e-s}')"
  if [ "$code" -eq 0 ]; then status=success; else status=failure; fi
  max_rss="$(tail -n 1 "$rss" 2>/dev/null | grep -E '^[0-9]+$' || echo null)"
  error="$(tail -n 5 "$err" | ass_sanitize 300)"

  jq -cn --arg ts "$(ass_now)" --arg status "$status" --argjson code "$code" \
        --argjson duration "$duration" --argjson rss "${max_rss:-null}" \
        --arg error "$error" --argjson version "$(ass_meta_get version)" \
        --argjson out_bytes "$(wc -c <"$out" | tr -d ' ')" \
    '{ts:$ts,version:$version,status:$status,exit_code:$code,duration_s:$duration,
      max_rss_kb:$rss,stdout_bytes:$out_bytes,error:$error}' >>"$ASS_STATE_DIR/observations.jsonl"

  rm -f "$out" "$err" "$rss"
  return "$code"
}
