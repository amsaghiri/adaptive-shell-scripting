#!/usr/bin/env bash
# Safety pipeline: the validator V. Three stages, fail-fast, and completely
# independent of the LLM. A candidate that fails any stage is discarded.
# Part of the immutable core.
#
#   Stage 1  syntactic   bash -n, ShellCheck, marker verification
#   Stage 2  semantic    run in a sandbox with mock data and a time limit
#   Stage 3  policy      command whitelist, path restrictions, forbidden patterns
#
# On failure, ASS_REJECT_REASON says which stage rejected the candidate and why.

# shellcheck disable=SC2034  # read by the caller in adaptive.sh
ASS_REJECT_REASON=""
ass_reject() { ASS_REJECT_REASON="$1"; ass_log "REJECT $1"; return 1; }

# ---- Stage 1: syntactic -----------------------------------------------------
ass_validate_syntax() {
  local cand="$1" assembled
  [ -s "$cand" ] || { ass_reject "stage 1: candidate is empty"; return 1; }
  if grep -q -F -e "$ASS_BEGIN_MARKER" -e "$ASS_END_MARKER" "$cand"; then
    ass_reject "stage 1: candidate contains a payload marker"; return 1
  fi
  bash -n "$cand" 2>/dev/null || { ass_reject "stage 1: bash -n reports a syntax error"; return 1; }

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s bash -S "$ASS_SHELLCHECK_SEVERITY" "$cand" >/dev/null 2>&1 || \
      { ass_reject "stage 1: ShellCheck reports problems at severity '$ASS_SHELLCHECK_SEVERITY'"; return 1; }
  elif [ "$ASS_SHELLCHECK" = required ]; then
    ass_reject "stage 1: ShellCheck is not installed (set ASS_SHELLCHECK=optional to skip)"; return 1
  fi

  # The assembled script must still have exactly one pair of markers and parse.
  assembled="$(mktemp "$ASS_STATE_DIR/assembled.XXXXXX")"
  ass_assemble "$cand" >"$assembled"
  if ! ass_markers_ok "$assembled" || ! bash -n "$assembled" 2>/dev/null; then
    rm -f "$assembled"; ass_reject "stage 1: marker verification failed"; return 1
  fi
  rm -f "$assembled"
}

# ---- Stage 2: semantic ------------------------------------------------------
ass_validate_sandbox() {
  local cand="$1" code setup=()
  case "$ASS_SANDBOX" in
    docker)
      command -v docker >/dev/null 2>&1 || { ass_reject "stage 2: docker is not available"; return 1; }
      [ -n "$ASS_SANDBOX_SETUP" ] && setup=(-v "$ASS_SANDBOX_SETUP:/sandbox/setup.sh:ro")
      timeout "$ASS_SANDBOX_TIMEOUT" docker run --rm --network none --memory 256m --cpus 1 \
        --pids-limit 128 -v "$cand:/sandbox/payload.sh:ro" "${setup[@]}" "$ASS_SANDBOX_IMAGE" \
        bash -c '[ -f /sandbox/setup.sh ] && bash /sandbox/setup.sh; exec bash /sandbox/payload.sh' \
        >/dev/null 2>"$ASS_STATE_DIR/sandbox.err"
      code=$? ;;
    local)
      # No isolation: a subprocess with a time limit and resource limits.
      # For tests and demos only. The policy stage has already run in this mode.
      ( ulimit -t "$ASS_SANDBOX_TIMEOUT" -f 1048576 2>/dev/null
        [ -n "$ASS_SANDBOX_SETUP" ] && bash "$ASS_SANDBOX_SETUP"
        exec timeout "$ASS_SANDBOX_TIMEOUT" bash "$cand" ) >/dev/null 2>"$ASS_STATE_DIR/sandbox.err"
      code=$? ;;
    *) ass_reject "stage 2: unknown sandbox '$ASS_SANDBOX'"; return 1 ;;
  esac
  [ "$code" -eq 124 ] && { ass_reject "stage 2: sandbox run exceeded ${ASS_SANDBOX_TIMEOUT}s"; return 1; }
  [ "$code" -eq 0 ] || { ass_reject "stage 2: sandbox run exited with code $code"; return 1; }
}

# ---- Stage 3: policy --------------------------------------------------------
# The checks below are textual and deliberately conservative: when in doubt the
# candidate is rejected. They are a guard rail, not a shell parser.

# Command words used by the candidate, one per line.
ass_command_words() {
  # Single-quoted text is dropped. Double quotes are only unwrapped, because
  # they can hide a command substitution; text inside them is then examined
  # like code, which errs on the side of rejecting.
  sed -E -e 's/^[[:space:]]*#.*$//' -e "s/'[^']*'/ S /g" -e 's/"//g' -e 's/[[:space:]]#.*$//' \
         -e 's/\$\(\([^()]*\)\)/A/g' \
         -e 's/\$\{[^{}$`]*\}/A/g' \
         -e 's/^[[:space:]]*[A-Za-z0-9_*|?.$-]+\)[[:space:]]*//' "$1" \
  | sed -E 's/\$\(|`|\|\||&&|[;|&({}]/\n/g' \
  | sed -E 's/^[[:space:]]*(then|do|else|elif|if|while|until|!|time)[[:space:]]+//' \
  | sed -E 's/^[[:space:]]*(then|do|else|elif|if|while|until|!|time)[[:space:]]+//' \
  | awk '{ i=1; while (i<=NF && $i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
           if (i<=NF) { w=$i; gsub(/\)+$/, "", w); if (w != "") print w } }' \
  | grep -v -x -E 'if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|S|\[\[|\]\]|\[|\]|[0-9]+|<<.*|[<>].*' \
  | sort -u
}

ass_validate_policy() {
  local cand="$1" word path pattern defined
  # Functions defined inside the candidate may be called by it.
  defined="$(grep -o -E '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' "$cand" \
             | sed -E 's/function[[:space:]]+//; s/[[:space:]()]//g')"

  while IFS= read -r word; do
    [ -n "$word" ] || continue
    printf '%s\n' "$defined" | grep -q -x -F -- "$word" && continue
    grep -q -x -F -- "$word" "$ASS_POLICY_DIR/allowed_commands.txt" || \
      { ass_reject "stage 3: command '$word' is not on the whitelist"; return 1; }
  done < <(ass_command_words "$cand")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    ass_path_allowed "$path" || { ass_reject "stage 3: path '$path' is outside the allowed locations"; return 1; }
  done < <(grep -v -E '^[[:space:]]*#' "$cand" | grep -o -E '(^|[[:space:]"'"'"'=:(<>])/[A-Za-z0-9._/-]*' | sed -E 's/^[^/]*//' | sort -u)

  while IFS= read -r pattern; do
    case "$pattern" in ''|'#'*) continue ;; esac
    grep -q -E -- "$pattern" "$cand" && { ass_reject "stage 3: forbidden pattern '$pattern'"; return 1; }
  done <"$ASS_POLICY_DIR/forbidden_patterns.txt"
  return 0
}

ass_path_allowed() {
  local p="$1" prefix
  [ "$p" = / ] && return 1
  while IFS= read -r prefix; do
    case "$prefix" in ''|'#'*) continue ;; esac
    case "$p" in "$prefix"|"$prefix"/*) return 0 ;; esac
  done <"$ASS_POLICY_DIR/allowed_paths.txt"
  return 1
}

# ---- the pipeline -----------------------------------------------------------
ass_validate() {
  local cand; cand="$(readlink -f "$1")"
  ASS_REJECT_REASON=""
  ass_validate_syntax "$cand" || return 1
  if [ "$ASS_SANDBOX" = local ]; then
    # Without isolation, never execute a candidate that has not passed policy.
    ass_validate_policy "$cand" || return 1
    ass_validate_sandbox "$cand" || return 1
  else
    ass_validate_sandbox "$cand" || return 1
    ass_validate_policy "$cand" || return 1
  fi
  ass_log "candidate passed all three validation stages"
}
