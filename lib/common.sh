#!/usr/bin/env bash
# Shared configuration, state, logging, and the core-integrity functions.
# Part of the immutable core.

ASS_BEGIN_MARKER='# PAYLOAD-BEGIN'
ASS_END_MARKER='# PAYLOAD-END'

# ---- configuration (override in config.env or the environment) --------------
[ -f "$ASS_ROOT/config.env" ] && . "$ASS_ROOT/config.env"

: "${ASS_STATE_DIR:=$ASS_ROOT/state}"
: "${ASS_POLICY_DIR:=$ASS_ROOT/policy}"

# Triggers
: "${ASS_CONSECUTIVE_FAILURES:=3}"     # T1: this many failures in a row
: "${ASS_WINDOW:=10}"                  # T2: window size in runs
: "${ASS_WINDOW_FAILURE_RATE:=50}"     # T2: percent of failures in the window
: "${ASS_ERROR_REGEX=No such file or directory|not found|Permission denied|Connection refused}"   # T3 (empty = off)
: "${ASS_SLOWDOWN_FACTOR:=2}"          # T4: runtime above this multiple of baseline
: "${ASS_BASELINE_RUNS:=20}"           # T4: successful runs used for the baseline
: "${ASS_BASELINE_MIN_RUNS:=5}"        # T4: successful runs needed before it can fire
: "${ASS_COOLDOWN_RUNS:=3}"            # runs to wait after a rejected proposal

# LLM integration
: "${ASS_LLM_CMD:=}"                   # command: prompt on stdin, payload on stdout
: "${ASS_LLM_TEMPERATURE:=0.3}"
: "${ASS_LLM_MAX_TOKENS:=2000}"
: "${ASS_PROMPT_OBSERVATIONS:=30}"     # observations included in the prompt

# Safety pipeline
: "${ASS_SANDBOX:=docker}"             # docker | local (local is for tests only)
: "${ASS_SANDBOX_IMAGE:=ubuntu:22.04}"
: "${ASS_SANDBOX_TIMEOUT:=60}"         # seconds
: "${ASS_SANDBOX_SETUP:=}"             # optional script that creates mock data
: "${ASS_SHELLCHECK:=required}"        # required | optional
: "${ASS_SHELLCHECK_SEVERITY:=error}"

export ASS_STATE_DIR ASS_POLICY_DIR ASS_LLM_TEMPERATURE ASS_LLM_MAX_TOKENS

# ---- small helpers ----------------------------------------------------------
ass_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ass_log() { printf '%s %s\n' "$(ass_now)" "$*" >>"$ASS_STATE_DIR/adaptive.log"; printf '[adaptive] %s\n' "$*" >&2; }

ass_sha256() { sha256sum "$1" | cut -d' ' -f1; }

ass_init_state() {
  mkdir -p "$ASS_STATE_DIR/backups"
  [ -f "$ASS_STATE_DIR/observations.jsonl" ] || : >"$ASS_STATE_DIR/observations.jsonl"
  [ -f "$ASS_STATE_DIR/history.jsonl" ] || : >"$ASS_STATE_DIR/history.jsonl"
  [ -f "$ASS_STATE_DIR/metadata.json" ] || \
    printf '{"version":0,"epoch_start":0,"cooldown_until":0}\n' >"$ASS_STATE_DIR/metadata.json"
}

# Metadata M: version counter and bookkeeping for triggers.
ass_meta_get() { jq -r --arg k "$1" '.[$k] // 0' "$ASS_STATE_DIR/metadata.json"; }
ass_meta_set() {
  local tmp; tmp="$(mktemp "$ASS_STATE_DIR/meta.XXXXXX")"
  jq --arg k "$1" --argjson v "$2" '.[$k]=$v' "$ASS_STATE_DIR/metadata.json" >"$tmp" && mv -f "$tmp" "$ASS_STATE_DIR/metadata.json"
}

ass_observation_count() { wc -l <"$ASS_STATE_DIR/observations.jsonl" | tr -d ' '; }

# ---- the quine step: the script reads its own source ------------------------
# Payload P: the lines strictly between the two markers.
ass_extract_payload() {
  awk -v b="$ASS_BEGIN_MARKER" -v e="$ASS_END_MARKER" '
    $0==e {inside=0}
    inside {print}
    $0==b {inside=1}' "$1"
}

# Core C: everything except the payload lines (the markers belong to the core).
ass_extract_core() {
  awk -v b="$ASS_BEGIN_MARKER" -v e="$ASS_END_MARKER" '
    $0==e {inside=0}
    !inside {print}
    $0==b {inside=1}' "$1"
}

# Exactly one BEGIN marker followed by exactly one END marker.
ass_markers_ok() {
  local b e
  b="$(grep -n -x -F "$ASS_BEGIN_MARKER" "$1" | cut -d: -f1)"
  e="$(grep -n -x -F "$ASS_END_MARKER" "$1" | cut -d: -f1)"
  [ "$(printf '%s\n' "$b" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$e" | grep -c .)" = 1 ] && [ "$b" -lt "$e" ]
}

# Checksum of the core: the script without its payload, plus every library file.
ass_core_checksum() {
  { ass_extract_core "${1:-$ASS_SELF}"
    for f in "$ASS_ROOT"/lib/*.sh; do printf '== %s\n' "$(basename "$f")"; cat "$f"; done
  } | sha256sum | cut -d' ' -f1
}

ass_seal_core() {
  ass_core_checksum >"$ASS_STATE_DIR/core.sha256"
  chmod a-w "$ASS_SELF" "$ASS_ROOT"/lib/*.sh 2>/dev/null || true
  echo "core sealed: $(cat "$ASS_STATE_DIR/core.sha256")"
}

ass_verify_core() {
  [ -f "$ASS_STATE_DIR/core.sha256" ] || { ass_log "core is not sealed; run: adaptive.sh seal"; return 1; }
  [ "$(ass_core_checksum)" = "$(cat "$ASS_STATE_DIR/core.sha256")" ] && ass_markers_ok "$ASS_SELF"
}

ass_in_cooldown() { [ "$(ass_observation_count)" -lt "$(ass_meta_get cooldown_until)" ]; }

# A rejected or failed adaptation is handed to a person.
ass_escalate() {
  jq -cn --arg ts "$(ass_now)" --arg trigger "$1" --arg why "$2" \
    '{ts:$ts,event:"needs_attention",trigger:$trigger,reason:$why}' >>"$ASS_STATE_DIR/history.jsonl"
  ass_meta_set cooldown_until "$(( $(ass_observation_count) + ASS_COOLDOWN_RUNS ))"
  printf '%s trigger=%s reason=%s\n' "$(ass_now)" "$1" "$2" >>"$ASS_STATE_DIR/needs_attention"
}

ass_status() {
  echo "script:   $ASS_SELF"
  echo "version:  $(ass_meta_get version)"
  if ass_verify_core 2>/dev/null; then echo "core:     OK"; else echo "core:     NOT VERIFIED"; fi
  echo "runs:     $(ass_observation_count)"
  echo "last observations:"
  tail -n 5 "$ASS_STATE_DIR/observations.jsonl" | jq -r '"  \(.ts)  \(.status)  exit=\(.exit_code)  \(.duration_s)s  \(.error|.[0:70])"'
  [ -s "$ASS_STATE_DIR/needs_attention" ] && { echo "needs attention:"; tail -n 3 "$ASS_STATE_DIR/needs_attention" | sed 's/^/  /'; }
  return 0
}
