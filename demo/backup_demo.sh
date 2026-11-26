#!/usr/bin/env bash
# The "adaptive backup" use case, end to end, in a throwaway directory.
#
# A backup script works, then the directory it backs up is moved. After three
# failed runs the framework asks for a new payload, validates it, commits it,
# and the next run succeeds.
#
# The demo is offline and repeatable: the LLM is replaced by llm/mock.sh, which
# returns a prepared fix, and the sandbox runs in "local" mode. Nothing outside
# the temporary directory is touched.
#
#   bash demo/backup_demo.sh
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d /tmp/ass-demo.XXXXXX)"
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT

cp -r "$REPO/adaptive.sh" "$REPO/lib" "$REPO/llm" "$REPO/policy" "$W/"
mkdir -p "$W/data/projects"; echo "quarterly report" >"$W/data/projects/report.txt"

export ASS_STATE_DIR="$W/state" ASS_SANDBOX=local ASS_SANDBOX_SETUP=""
export ASS_LLM_CMD="$W/llm/mock.sh" ASS_MOCK_RESPONSE="$W/llm_reply.sh"
export ASS_ERROR_REGEX=""          # use only the consecutive-failure trigger here
A="$W/adaptive.sh"

payload() {   # $1 = directory to back up
  cat <<P
# Adaptive backup: archive a project directory into a backup directory.
SRC="$1"
DEST="$W/backups"

if [ ! -d "\$SRC" ]; then
  echo "source directory \$SRC is missing" >&2
  exit 1
fi
mkdir -p "\$DEST"
tar -czf "\$DEST/projects-\$(date +%s%N).tar.gz" -C "\$SRC" .
echo "backup of \$SRC written to \$DEST"
P
}
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
run()  { "$A" run 2>&1 | sed 's/^/   /'; }

step "1. Seal the core and install the first payload"
"$A" seal | sed 's/^/   /'
payload "$W/data/projects" >"$W/payload.sh"
"$A" install "$W/payload.sh" 2>&1 | sed 's/^/   /'

step "2. A normal run"
run

step "3. The environment changes: the project directory is moved"
mv "$W/data/projects" "$W/data/projects-2026"
echo "   moved data/projects -> data/projects-2026"
payload "$W/data/projects-2026" >"$W/llm_reply.sh"     # the reply the mock LLM will give

step "4. Three scheduled runs fail; the third one triggers adaptation"
run; run; run

step "5. The next scheduled run uses the adapted payload"
run

step "6. What was recorded"
"$A" status 2>/dev/null | sed 's/^/   /'
echo "   history:"
jq -r '"     \(.ts)  \(.event)  v\(.version // "-")  \(.trigger // .reason // "")"' "$ASS_STATE_DIR/history.jsonl"
echo "   payload change:"
diff <(sed -n '/PAYLOAD-BEGIN/,/PAYLOAD-END/p' "$ASS_STATE_DIR"/backups/00001-*.sh) \
     <(sed -n '/PAYLOAD-BEGIN/,/PAYLOAD-END/p' "$A") | sed "s|$W|<workdir>|g; s/^/     /"
