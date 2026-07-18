#!/usr/bin/env bash

# Atomically activates an archive and checksum as far as portable POSIX file
# operations allow. A per-asset lock serializes writers, and an interrupted or
# failed second rename restores the complete previous pair.

publish_package_pair() (
  set -euo pipefail

  if [[ $# -ne 5 ]]; then
    echo 'publish_package_pair requires TEMP_ARCHIVE TEMP_SIDECAR ARCHIVE SIDECAR WORKSPACE' >&2
    exit 2
  fi

  temporary_archive="$1"
  temporary_sidecar="$2"
  archive="$3"
  sidecar="$4"
  workspace="$5"
  backup_archive="$workspace/previous-archive"
  backup_sidecar="$workspace/previous-sidecar"
  preserve_marker="$workspace/.preserve"
  lock_path="$archive.quotabot-package.lock"
  lock_owner="${BASHPID:-$$}"
  lock_acquired=0
  activation_started=0
  committed=0

  cleanup_pair() {
    status=$?
    set +e
    rollback_failed=0

    if [[ "$activation_started" -eq 1 && "$committed" -eq 0 ]]; then
      if [[ ! -e "$temporary_archive" && ! -L "$temporary_archive" && \
            ( -e "$archive" || -L "$archive" ) ]]; then
        rm -f "$archive" || rollback_failed=1
      fi
      if [[ ! -e "$temporary_sidecar" && ! -L "$temporary_sidecar" && \
            ( -e "$sidecar" || -L "$sidecar" ) ]]; then
        rm -f "$sidecar" || rollback_failed=1
      fi
      if [[ -e "$backup_archive" || -L "$backup_archive" ]]; then
        mv "$backup_archive" "$archive" || rollback_failed=1
      fi
      if [[ -e "$backup_sidecar" || -L "$backup_sidecar" ]]; then
        mv "$backup_sidecar" "$sidecar" || rollback_failed=1
      fi
      if [[ "$rollback_failed" -ne 0 ]]; then
        : > "$preserve_marker"
        echo "Package activation failed and rollback was incomplete. Recovery files remain in $workspace" >&2
        status=1
      elif [[ "$status" -ne 0 ]]; then
        echo 'Package activation failed; the previous archive and checksum were restored.' >&2
      fi
    fi

    if [[ "$lock_acquired" -eq 1 && -f "$lock_path" && \
          "$(cat "$lock_path" 2>/dev/null)" == "$lock_owner" ]]; then
      rm -f "$lock_path"
    fi
    trap - EXIT INT TERM
    exit "$status"
  }
  trap cleanup_pair EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! (set -o noclobber; printf '%s\n' "$lock_owner" > "$lock_path") 2>/dev/null; then
    existing_owner="$(cat "$lock_path" 2>/dev/null || true)"
    case "$existing_owner" in
      ''|*[!0-9]*) owner_is_live=0 ;;
      *)
        if kill -0 "$existing_owner" 2>/dev/null; then
          owner_is_live=1
        else
          owner_is_live=0
        fi
        ;;
    esac
    if [[ "$owner_is_live" -eq 1 ]]; then
      echo "Another package operation is already publishing $archive" >&2
      exit 1
    fi

    stale_lock="$lock_path.stale.$lock_owner"
    if ! mv "$lock_path" "$stale_lock" 2>/dev/null; then
      echo "Could not recover the stale package lock for $archive" >&2
      exit 1
    fi
    rm -f "$stale_lock"
    if ! (set -o noclobber; printf '%s\n' "$lock_owner" > "$lock_path") 2>/dev/null; then
      echo "Another package operation started publishing $archive" >&2
      exit 1
    fi
  fi
  lock_acquired=1
  activation_started=1

  if [[ -e "$archive" || -L "$archive" ]]; then
    mv "$archive" "$backup_archive" || exit 1
  fi
  if [[ -e "$sidecar" || -L "$sidecar" ]]; then
    mv "$sidecar" "$backup_sidecar" || exit 1
  fi
  mv "$temporary_archive" "$archive" || exit 1
  mv "$temporary_sidecar" "$sidecar" || exit 1
  committed=1

  rm -f "$backup_archive" "$backup_sidecar" || exit 1
)
