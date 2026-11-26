#!/usr/bin/env bash
# Atomic commit and rollback: the commit function Phi. Part of the immutable core.
#
# Commit sequence: backup -> hash -> write to a temporary file -> integrity
# check -> atomic rename. The running script is replaced in a single rename, so
# there is never a moment when a half-written script is on disk.

# New script text = the unchanged core with the candidate between the markers.
ass_assemble() {
  awk -v b="$ASS_BEGIN_MARKER" -v e="$ASS_END_MARKER" -v cand="$1" '
    $0==e {inside=0}
    !inside {print}
    $0==b {inside=1; while ((getline line < cand) > 0) print line; close(cand)}' "$ASS_SELF"
}

ass_commit() {
  local cand="$1" reason="$2" old_sha new_sha backup tmp version
  old_sha="$(ass_sha256 "$ASS_SELF")"
  version="$(ass_meta_get version)"

  # 1. Backup of the version that is about to be replaced.
  backup="$ASS_STATE_DIR/backups/$(printf '%05d' "$version")-${old_sha:0:12}.sh"
  cp -p "$ASS_SELF" "$backup" || return 1

  # 2-3. Write the new version to a temporary file in the same directory.
  tmp="$(mktemp "$ASS_ROOT/.adaptive.XXXXXX")" || return 1
  ass_assemble "$cand" >"$tmp"

  # 4. Integrity check: the core must be byte-for-byte unchanged, the markers
  #    intact, and the file must parse.
  if [ "$(ass_core_checksum "$tmp")" != "$(cat "$ASS_STATE_DIR/core.sha256" 2>/dev/null)" ] \
     || ! ass_markers_ok "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; ass_log "commit aborted: integrity check failed"; return 1
  fi
  new_sha="$(ass_sha256 "$tmp")"
  chmod 555 "$tmp"

  # 5. Atomic rename.
  mv -f "$tmp" "$ASS_SELF" || { rm -f "$tmp"; return 1; }

  ass_meta_set version "$(( version + 1 ))"
  ass_meta_set epoch_start "$(ass_observation_count)"
  ass_meta_set cooldown_until 0
  jq -cn --arg ts "$(ass_now)" --arg trigger "$reason" --arg old "$old_sha" --arg new "$new_sha" \
        --arg backup "$(basename "$backup")" --argjson version "$(( version + 1 ))" \
    '{ts:$ts,event:"commit",version:$version,trigger:$trigger,previous_sha256:$old,sha256:$new,backup:$backup}' \
    >>"$ASS_STATE_DIR/history.jsonl"
}

# Restore the most recent backup, again with a single atomic rename.
ass_rollback() {
  local backup tmp
  backup="$(find "$ASS_STATE_DIR/backups" -maxdepth 1 -name '*.sh' | sort | tail -n 1)"
  [ -n "$backup" ] || { echo "no backup to roll back to" >&2; return 1; }
  if [ "$(ass_core_checksum "$backup")" != "$(cat "$ASS_STATE_DIR/core.sha256" 2>/dev/null)" ]; then
    echo "backup core does not match the sealed core; refusing" >&2; return 1
  fi
  tmp="$(mktemp "$ASS_ROOT/.adaptive.XXXXXX")" || return 1
  cp "$backup" "$tmp" && chmod 555 "$tmp" && mv -f "$tmp" "$ASS_SELF" || { rm -f "$tmp"; return 1; }
  rm -f "$backup"
  ass_meta_set epoch_start "$(ass_observation_count)"
  jq -cn --arg ts "$(ass_now)" --arg sha "$(ass_sha256 "$ASS_SELF")" \
    '{ts:$ts,event:"rollback",sha256:$sha}' >>"$ASS_STATE_DIR/history.jsonl"
  echo "rolled back to $(basename "$backup")"
}
