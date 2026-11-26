#!/usr/bin/env bash
# =============================================================================
# QUINE CORE  (immutable)
#
# Adaptive Shell Scripting with Quine Programs and Large Language Models
# Reference implementation of the framework described in:
#   A. M. Saghiri, ICCRAIDS 2026, doi:10.1109/ICCRAIDS67816.2026.11519702
#
# This file is one script made of two parts:
#   * the core  - everything outside the payload markers. It never changes.
#   * the payload - the lines between PAYLOAD-BEGIN and PAYLOAD-END at the end
#     of this file. It is the only part that adaptation may rewrite.
#
# The core reads its own source (the "quine" step), runs the payload, records
# what happened, decides whether adaptation is needed, asks an LLM for a new
# payload, validates the proposal, and atomically replaces itself.
# =============================================================================
set -u

ASS_SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ASS_ROOT="$(dirname "$ASS_SELF")"
export ASS_SELF ASS_ROOT

# shellcheck source=lib/common.sh
. "$ASS_ROOT/lib/common.sh"
# shellcheck source=lib/observe.sh
. "$ASS_ROOT/lib/observe.sh"
# shellcheck source=lib/triggers.sh
. "$ASS_ROOT/lib/triggers.sh"
# shellcheck source=lib/propose.sh
. "$ASS_ROOT/lib/propose.sh"
# shellcheck source=lib/validate.sh
. "$ASS_ROOT/lib/validate.sh"
# shellcheck source=lib/commit.sh
. "$ASS_ROOT/lib/commit.sh"

ass_usage() {
  cat <<'USAGE'
Usage: adaptive.sh <command>

  run                 Execute the payload, record an observation, and adapt if a
                      trigger fires. This is what cron should call.
  seal                Record the core checksum. Run once after installing.
  verify              Check the core against the sealed checksum.
  status              Show version, core integrity, and recent observations.
  payload             Print the current payload.
  install <file>      Validate <file> and commit it as the payload.
  adapt [reason]      Force one adaptation cycle now.
  rollback            Restore the previous version of this script.
USAGE
}

# One full pass of the adaptation loop: propose -> validate -> commit.
ass_adapt() {
  local reason="$1" candidate
  candidate="$(mktemp "$ASS_STATE_DIR/candidate.XXXXXX")"
  ass_log "adaptation started (trigger: $reason)"

  if ! ass_propose "$reason" "$candidate"; then
    ass_log "proposal failed; manual attention needed"
    ass_escalate "$reason" "the LLM did not return a payload"
    rm -f "$candidate"; return 1
  fi
  if ! ass_validate "$candidate"; then
    ass_log "candidate rejected by the safety pipeline; manual attention needed"
    ass_escalate "$reason" "candidate rejected: $ASS_REJECT_REASON"
    rm -f "$candidate"; return 1
  fi
  if ! ass_commit "$candidate" "$reason"; then
    ass_log "commit failed; the running version is unchanged"
    ass_escalate "$reason" "commit failed"
    rm -f "$candidate"; return 1
  fi
  rm -f "$candidate"
  ass_log "adaptation committed (version $(ass_meta_get version))"
}

ass_run() {
  ass_verify_core || { ass_log "core integrity check FAILED; refusing to run"; return 70; }

  local payload code reason
  payload="$(mktemp "$ASS_STATE_DIR/payload.XXXXXX")"
  ass_extract_payload "$ASS_SELF" >"$payload"

  ass_execute_and_observe "$payload"; code=$?
  rm -f "$payload"

  if reason="$(ass_check_triggers)"; then
    if ass_in_cooldown; then
      ass_log "trigger '$reason' fired, but a recent proposal was rejected; waiting"
    else
      ass_adapt "$reason" || true
    fi
  fi
  return "$code"
}

ass_main() {
  local cmd="${1:-run}"
  ass_init_state
  case "$cmd" in
    run)      ass_run ;;
    seal)     ass_seal_core ;;
    verify)   ass_verify_core && echo "core OK" ;;
    status)   ass_status ;;
    payload)  ass_extract_payload "$ASS_SELF" ;;
    install)  [ -n "${2:-}" ] || { ass_usage; return 64; }
              ass_validate "$2" || { echo "rejected: $ASS_REJECT_REASON" >&2; return 65; }
              ass_commit "$2" "manual install" ;;
    adapt)    ass_adapt "${2:-manual}" ;;
    rollback) ass_rollback ;;
    -h|--help|help) ass_usage ;;
    *)        ass_usage; return 64 ;;
  esac
}

ass_main "$@"
exit $?
# =============================================================================
# EVOLVABLE PAYLOAD  (the only region adaptation may change)
# The core exits above, so these lines never run inside the core process.
# They are extracted and executed as a separate shell script.
# =============================================================================
# PAYLOAD-BEGIN
echo "No payload installed yet. Use: ./adaptive.sh install <file>"
# PAYLOAD-END
