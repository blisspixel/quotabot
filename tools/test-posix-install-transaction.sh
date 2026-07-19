#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d)"
test_parent="$(cd "$(dirname "$test_root")" && pwd -P)"
test_name="$(basename "$test_root")"
configured_temp="${TMPDIR:-/tmp}"
resolved_temp="$(cd "$configured_temp" && pwd -P)"
real_mv="$(command -v mv)"
host_kernel="$(uname -s)"
case "$host_kernel" in
  Darwin*)
    fake_uname_s=Darwin
    fake_uname_m=arm64
    transaction_os=darwin
    ;;
  MINGW* | MSYS* | CYGWIN*)
    # Git for Windows otherwise emulates `ln -s` by copying its target. This
    # harness verifies atomic link activation, so require native symlinks for
    # every child utility and installer process it launches.
    export MSYS="winsymlinks:nativestrict"
    fake_uname_s=Linux
    fake_uname_m=x86_64
    transaction_os=linux
    ;;
  *)
    fake_uname_s=Linux
    fake_uname_m=x86_64
    transaction_os=linux
    ;;
esac

cleanup_test() {
  if [[ "$test_parent" != "$resolved_temp" || "$test_name" != tmp.* ]]; then
    echo "Refusing to remove unexpected test directory: $test_root" >&2
    return 1
  fi
  rm -rf -- "$test_root"
}
trap cleanup_test EXIT

count_directory_entries() {
  local directory="$1"
  local entries
  shopt -s nullglob dotglob
  entries=("$directory"/*)
  shopt -u nullglob dotglob
  printf '%s\n' "${#entries[@]}"
}

count_generation_directories() {
  local directory="$1"
  local entry count=0
  local entries
  shopt -s nullglob
  entries=("$directory"/generation-* "$directory"/legacy-*)
  shopt -u nullglob
  for entry in "${entries[@]}"; do
    if [[ -d "$entry" && ! -L "$entry" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

test_home="$test_root/home"
fake_bin="$test_root/fake-bin"
payload="$test_root/payload"
archive="$test_root/quotabot-linux-x64.tar.gz"
sidecar="$archive.sha256"
outside="$test_root/outside"
install_root="$test_home/.local/share/quotabot"
versions_root="$test_home/.local/share/.quotabot-versions"
wrapper="$test_home/.local/bin/quotabot"
mkdir -p "$fake_bin" "$outside"
printf 'outside sentinel\n' > "$outside/sentinel"

write_payload() {
  local version="$1"
  rm -rf -- "$payload"
  mkdir -p "$payload/bin" "$payload/lib"
  cat > "$payload/bin/quotabot" <<EOF
#!/usr/bin/env sh
printf '%s\n' '$version'
EOF
  chmod +x "$payload/bin/quotabot"
  printf '%s\n' "$version" > "$payload/lib/sqlite3.test"
  tar -C "$payload" -czf "$archive" .
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$archive" | awk '{print $1}')"
  else
    digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
  fi
  printf '%s  %s\n' "$digest" "$(basename "$archive")" > "$sidecar"
}

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env sh
url=''
destination=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; destination=$1 ;;
    http*) url=$1 ;;
  esac
  shift
done
case "$url" in
  *.sha256) cp "$FAKE_SIDECAR" "$destination" ;;
  *) cp "$FAKE_ARCHIVE" "$destination" ;;
esac
EOF
cat > "$fake_bin/uname" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  -s) printf '%s\n' "$FAKE_UNAME_S" ;;
  -m) printf '%s\n' "$FAKE_UNAME_M" ;;
  *) exit 2 ;;
esac
EOF
cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env sh
source_path=''
destination=''
for argument in "$@"; do
  case "$argument" in
    -*) ;;
    *)
      if [ -z "$source_path" ]; then
        source_path=$argument
      else
        destination=$argument
      fi
      ;;
  esac
done
case "$source_path" in
  */.*-link-*)
    if [ -n "${MV_TRACE:-}" ]; then
      printf '%s\n' "$destination" >> "$MV_TRACE"
    fi
    if [ "${FAIL_ACTIVATION:-0}" = 1 ]; then
      fail_target="${FAIL_TARGET:-$HOME/.local/share/quotabot}"
      if [ "$destination" = "$fail_target" ]; then
        exit 73
      fi
    fi
    ;;
esac
exec "$REAL_MV" "$@"
EOF
chmod +x "$fake_bin/curl" "$fake_bin/uname" "$fake_bin/mv"

export HOME="$test_home"
export PATH="$fake_bin:$PATH"
export FAKE_ARCHIVE="$archive"
export FAKE_SIDECAR="$sidecar"
export REAL_MV="$real_mv"
export FAKE_UNAME_S="$fake_uname_s"
export FAKE_UNAME_M="$fake_uname_m"
export QUOTABOT_REPO="example/quotabot"

# An interrupted first migration must restore the complete legacy payload and
# leave the existing PATH wrapper untouched.
mkdir -p "$install_root/bin" "$install_root/lib" "$(dirname "$wrapper")"
printf '#!/usr/bin/env sh\nprintf "old\\n"\n' > "$install_root/bin/quotabot"
chmod +x "$install_root/bin/quotabot"
printf 'old\n' > "$install_root/lib/sqlite3.test"
printf 'old wrapper\n' > "$wrapper"
write_payload candidate
if FAIL_ACTIVATION=1 bash "$repository_root/install.sh" > "$test_root/failure.log" 2>&1; then
  echo 'Injected activation failure unexpectedly succeeded.' >&2
  exit 1
fi
test ! -L "$install_root"
test "$("$install_root/bin/quotabot")" = old
test "$(cat "$install_root/lib/sqlite3.test")" = old
test "$(cat "$wrapper")" = 'old wrapper'
test ! -e "$test_home/.local/share/.quotabot-install.lock"
test "$(count_directory_entries "$versions_root")" -eq 0
grep -q 'the previous install was restored' "$test_root/failure.log"

# A successful migration changes the stable path into one symlink to a complete
# versioned generation. The documented paths and PATH wrapper still work.
bash "$repository_root/install.sh" > "$test_root/first.log" 2>&1
test -L "$install_root"
test "$("$install_root/bin/quotabot")" = candidate
test "$("$wrapper")" = candidate
test "$(cat "$install_root/lib/sqlite3.test")" = candidate

# Stale staging trees and symlinks must be cleaned without following a symlink
# outside the resolved install parent.
staging_orphan="$versions_root/.staging-20260718030303-3001"
staging_escape="$versions_root/.staging-20260718030303-3002"
mkdir -p "$staging_orphan/bin"
ln -s "$outside" "$staging_escape"
ln -s "$outside" "$test_home/.local/share/.quotabot-link-orphan"
write_payload second
reader_log="$test_root/readers.log"
(
  for ((reader_index = 0; reader_index < 200; reader_index++)); do
    if ! "$wrapper" >> "$reader_log"; then
      printf 'reader-failed\n' >> "$reader_log"
    fi
  done
) &
reader_pid=$!
bash "$repository_root/install.sh" > "$test_root/second.log" 2>&1
wait "$reader_pid"
if grep -Ev '^(candidate|second)$' "$reader_log" >/dev/null; then
  echo 'A concurrent reader observed a missing or partial payload.' >&2
  exit 1
fi
test "$("$wrapper")" = second
test "$(cat "$outside/sentinel")" = 'outside sentinel'
test ! -e "$staging_orphan"
test ! -L "$staging_escape"
test ! -L "$test_home/.local/share/.quotabot-link-orphan"

# Repeated installs retain only the active payload and one rollback generation.
write_payload third
bash "$repository_root/install.sh" > "$test_root/third.log" 2>&1
test "$("$wrapper")" = third
generation_count="$(count_generation_directories "$versions_root")"
test "$generation_count" -eq 2
test "$(cat "$outside/sentinel")" = 'outside sentinel'

# A pre-existing versions-directory symlink is rejected, never traversed or
# cleaned. This models a hostile or corrupted legacy layout.
unsafe_home="$test_root/unsafe-home"
mkdir -p "$unsafe_home/.local/share" "$unsafe_home/.local/bin"
ln -s "$outside" "$unsafe_home/.local/share/.quotabot-versions"
if HOME="$unsafe_home" bash "$repository_root/install.sh" > "$test_root/unsafe.log" 2>&1; then
  echo 'A symlinked versions directory unexpectedly passed validation.' >&2
  exit 1
fi
test "$(cat "$outside/sentinel")" = 'outside sentinel'
grep -q 'Refusing to use a symlink' "$test_root/unsafe.log"

assert_rejected_prior_target() {
  local label="$1"
  local link_value="$2"
  local setup_kind="$3"
  local case_home="$test_root/prior-$label"
  local case_share="$case_home/.local/share"
  local case_versions="$case_share/.quotabot-versions"
  local case_target="$case_share/quotabot"
  local valid_name="generation-20260718010101-1234"

  mkdir -p "$case_versions" "$case_home/.local/bin"
  case "$setup_kind" in
    traversal)
      mkdir -p \
        "$case_versions/$valid_name" \
        "$case_share/outside/bin" "$case_share/outside/lib"
      ;;
    extra)
      mkdir -p "$case_versions/$valid_name/child"
      ;;
    missing) ;;
    generation-symlink)
      ln -s "$outside" "$case_versions/$valid_name"
      ;;
    *)
      echo "Unknown prior-target test kind: $setup_kind" >&2
      exit 1
      ;;
  esac
  ln -s "$link_value" "$case_target"
  observed_link="$(readlink "$case_target")"
  before_entries="$(count_directory_entries "$case_versions")"
  if HOME="$case_home" bash "$repository_root/install.sh" \
    > "$test_root/prior-$label.log" 2>&1; then
    echo "Invalid prior target unexpectedly passed validation: $label" >&2
    exit 1
  fi
  test "$(readlink "$case_target")" = "$observed_link"
  after_entries="$(count_directory_entries "$case_versions")"
  test "$after_entries" -eq "$before_entries"
  test ! -e "$case_share/.quotabot-install.lock"
  test "$(cat "$outside/sentinel")" = 'outside sentinel'
  grep -Eq 'Refusing to replace|Refusing to use' "$test_root/prior-$label.log"
}

assert_rejected_prior_target \
  traversal '.quotabot-versions/generation-20260718010101-1234/../../outside' traversal
assert_rejected_prior_target \
  extra '.quotabot-versions/generation-20260718010101-1234/child' extra
assert_rejected_prior_target \
  missing '.quotabot-versions/generation-20260718010101-1234' missing
assert_rejected_prior_target \
  generation-symlink '.quotabot-versions/generation-20260718010101-1234' generation-symlink

# Exercise the two-target source-setup transaction directly from setup.sh. The
# harness sources only the marked production functions, so no build runs.
source <(sed -n \
  '/^# BEGIN POSIX INSTALL TRANSACTION FUNCTIONS$/,/^# END POSIX INSTALL TRANSACTION FUNCTIONS$/p' \
  "$repository_root/tools/setup.sh")
os="$transaction_os"

setup_invalid_source="$test_root/setup-invalid-source"
mkdir -p "$setup_invalid_source/bin" "$setup_invalid_source/lib"
cat > "$setup_invalid_source/bin/quotabot" <<'EOF'
#!/usr/bin/env sh
printf 'setup-candidate\n'
EOF
chmod +x "$setup_invalid_source/bin/quotabot"
printf 'setup-candidate-lib\n' > "$setup_invalid_source/lib/sqlite3.test"
for invalid_label in traversal extra missing generation-symlink; do
  invalid_target="$test_root/prior-$invalid_label/.local/share/quotabot"
  invalid_link="$(readlink "$invalid_target")"
  if install_versioned_single "$setup_invalid_source" "$invalid_target" cli \
    > "$test_root/setup-prior-$invalid_label.log" 2>&1; then
    echo "Source setup accepted invalid prior target: $invalid_label" >&2
    exit 1
  fi
  test "$(readlink "$invalid_target")" = "$invalid_link"
  test ! -e "${invalid_target%/*}/.quotabot-install.lock"
  test "$(cat "$outside/sentinel")" = 'outside sentinel'
done

setup_single_target="$test_root/setup-single/home/.local/share/quotabot"
install_versioned_single "$setup_invalid_source" "$setup_single_target" cli
test -L "$setup_single_target"
test "$("$setup_single_target/bin/quotabot")" = setup-candidate
install_versioned_single "$setup_invalid_source" "$setup_single_target" cli
single_versions="${setup_single_target%/*}/.quotabot-versions"
single_count="$(count_generation_directories "$single_versions")"
test "$single_count" -eq 2

prepare_pair_case() {
  local label="$1"
  local case_root="$test_root/pair-$label"
  local old_cli_name="generation-20260718020202-2101"
  local old_desktop_name="generation-20260718020202-2102"

  pair_cli_source="$case_root/sources/cli"
  pair_desktop_source="$case_root/sources/desktop"
  pair_cli_target="$case_root/home/.local/share/quotabot"
  pair_desktop_target="$case_root/home/.local/share/quotabot-desktop"
  pair_cli_versions="$case_root/home/.local/share/.quotabot-versions"
  pair_desktop_versions="$case_root/home/.local/share/.quotabot-desktop-versions"
  mkdir -p \
    "$pair_cli_source/bin" "$pair_cli_source/lib" \
    "$pair_desktop_source" \
    "$pair_cli_versions/$old_cli_name/bin" \
    "$pair_cli_versions/$old_cli_name/lib" \
    "$pair_desktop_versions/$old_desktop_name"
  cat > "$pair_cli_source/bin/quotabot" <<'EOF'
#!/usr/bin/env sh
printf 'new-cli\n'
EOF
  cat > "$pair_desktop_source/quotabot" <<'EOF'
#!/usr/bin/env sh
printf 'new-desktop\n'
EOF
  cat > "$pair_cli_versions/$old_cli_name/bin/quotabot" <<'EOF'
#!/usr/bin/env sh
printf 'old-cli\n'
EOF
  cat > "$pair_desktop_versions/$old_desktop_name/quotabot" <<'EOF'
#!/usr/bin/env sh
printf 'old-desktop\n'
EOF
  chmod +x \
    "$pair_cli_source/bin/quotabot" \
    "$pair_desktop_source/quotabot" \
    "$pair_cli_versions/$old_cli_name/bin/quotabot" \
    "$pair_desktop_versions/$old_desktop_name/quotabot"
  printf 'new-cli-lib\n' > "$pair_cli_source/lib/sqlite3.test"
  printf 'old-cli-lib\n' > "$pair_cli_versions/$old_cli_name/lib/sqlite3.test"
  pair_old_cli_link=".quotabot-versions/$old_cli_name"
  pair_old_desktop_link=".quotabot-desktop-versions/$old_desktop_name"
  ln -s "$pair_old_cli_link" "$pair_cli_target"
  ln -s "$pair_old_desktop_link" "$pair_desktop_target"
}

assert_pair_restored() {
  test "$(readlink "$pair_cli_target")" = "$pair_old_cli_link"
  test "$(readlink "$pair_desktop_target")" = "$pair_old_desktop_link"
  test "$("$pair_cli_target/bin/quotabot")" = old-cli
  test "$("$pair_desktop_target/quotabot")" = old-desktop
  test "$(cat "$pair_cli_target/lib/sqlite3.test")" = old-cli-lib
  test ! -e "${pair_cli_target%/*}/.quotabot-install.lock"
  test ! -e "${pair_desktop_target%/*}/.quotabot-desktop-install.lock"
  cli_count="$(count_generation_directories "$pair_cli_versions")"
  desktop_count="$(count_generation_directories "$pair_desktop_versions")"
  test "$cli_count" -eq 1
  test "$desktop_count" -eq 1
}

prepare_pair_case first-activation
export FAIL_ACTIVATION=1
export FAIL_TARGET="$pair_desktop_target"
export MV_TRACE="$test_root/pair-first-activation.trace"
if install_versioned_pair \
  "$pair_cli_source" "$pair_cli_target" \
  "$pair_desktop_source" "$pair_desktop_target" linux-desktop \
  > "$test_root/pair-first-activation.log" 2>&1; then
  echo 'Injected first paired activation failure unexpectedly succeeded.' >&2
  exit 1
fi
unset FAIL_ACTIVATION FAIL_TARGET MV_TRACE
test "$(cat "$test_root/pair-first-activation.trace")" = "$pair_desktop_target"
grep -q "Could not activate the new quotabot payload at $pair_desktop_target" \
  "$test_root/pair-first-activation.log"
assert_pair_restored

prepare_pair_case second-activation
export FAIL_ACTIVATION=1
export FAIL_TARGET="$pair_cli_target"
export MV_TRACE="$test_root/pair-second-activation.trace"
if install_versioned_pair \
  "$pair_cli_source" "$pair_cli_target" \
  "$pair_desktop_source" "$pair_desktop_target" linux-desktop \
  > "$test_root/pair-second-activation.log" 2>&1; then
  echo 'Injected second paired activation failure unexpectedly succeeded.' >&2
  exit 1
fi
unset FAIL_ACTIVATION FAIL_TARGET MV_TRACE
expected_trace="$(printf '%s\n%s' "$pair_desktop_target" "$pair_cli_target")"
test "$(cat "$test_root/pair-second-activation.trace")" = "$expected_trace"
grep -q "Could not activate the new quotabot payload at $pair_cli_target" \
  "$test_root/pair-second-activation.log"
assert_pair_restored

prepare_pair_case success
install_versioned_pair \
  "$pair_cli_source" "$pair_cli_target" \
  "$pair_desktop_source" "$pair_desktop_target" linux-desktop
test "$("$pair_cli_target/bin/quotabot")" = new-cli
test "$("$pair_desktop_target/quotabot")" = new-desktop
test "$(cat "$pair_cli_target/lib/sqlite3.test")" = new-cli-lib
cli_count="$(count_generation_directories "$pair_cli_versions")"
desktop_count="$(count_generation_directories "$pair_desktop_versions")"
test "$cli_count" -eq 2
test "$desktop_count" -eq 2

printf 'POSIX install transaction tests passed.\n'
