#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d)"
test_root="$(cd "$test_root" && pwd -P)"
test_parent="$(cd "$(dirname "$test_root")" && pwd -P)"
test_name="$(basename "$test_root")"
resolved_temp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
real_rm="$(command -v rm)"
installed_pid=""
unrelated_pid=""

cleanup_test() {
  set +e
  if [ -n "$installed_pid" ]; then kill "$installed_pid" 2>/dev/null; fi
  if [ -n "$unrelated_pid" ]; then kill "$unrelated_pid" 2>/dev/null; fi
  if [ -n "$installed_pid" ]; then wait "$installed_pid" 2>/dev/null; fi
  if [ -n "$unrelated_pid" ]; then wait "$unrelated_pid" 2>/dev/null; fi
  if [ "$test_parent" != "$resolved_temp" ] || [[ "$test_name" != tmp.* ]]; then
    echo "Refusing to remove unexpected test directory: $test_root" >&2
    return 1
  fi
  "$real_rm" -rf -- "$test_root"
}
trap cleanup_test EXIT

export HOME="$test_root/home"
export XDG_CONFIG_HOME="$test_root/config"
physical_share="$test_root/physical-share"
mkdir -p "$HOME/.local" "$physical_share"
ln -s "$physical_share" "$HOME/.local/share"
cli_root="$HOME/.local/share/quotabot"
cli_versions="$HOME/.local/share/.quotabot-versions"
cli_generation="$cli_versions/generation-20260821010101-1001"
config_sentinel="$XDG_CONFIG_HOME/quotabot/manual/uninstall-sentinel"
mkdir -p "$cli_generation/bin" "$cli_generation/lib" "$(dirname "$config_sentinel")"
printf 'keep\n' > "$config_sentinel"
printf 'library\n' > "$cli_generation/lib/sqlite3.test"
ln -s '.quotabot-versions/generation-20260821010101-1001' "$cli_root"
mkdir -p "$HOME/.local/bin"
printf '#!/usr/bin/env sh\nexit 0\n' > "$HOME/.local/bin/quotabot"
chmod +x "$HOME/.local/bin/quotabot"

host_kernel="$(uname -s)"
case "$host_kernel" in
  Darwin*)
    desktop_root="$HOME/Applications/quotabot.app"
    desktop_versions="$HOME/Applications/.quotabot.app-versions"
    desktop_generation="$desktop_versions/generation-20260821020202-1002"
    mkdir -p "$desktop_generation/Contents/MacOS"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$desktop_generation/Contents/MacOS/quotabot"
    chmod +x "$desktop_generation/Contents/MacOS/quotabot"
    ln -s '.quotabot.app-versions/generation-20260821020202-1002' "$desktop_root"
    ;;
  Linux*)
    desktop_root="$HOME/.local/share/quotabot-desktop"
    desktop_versions="$HOME/.local/share/.quotabot-desktop-versions"
    desktop_generation="$desktop_versions/generation-20260821020202-1002"
    mkdir -p "$desktop_generation" "$test_root/unrelated"
    cp "$(command -v sleep)" "$cli_generation/bin/quotabot"
    cp "$(command -v sleep)" "$test_root/unrelated/quotabot"
    cp "$(command -v sleep)" "$desktop_generation/quotabot"
    ln -s '.quotabot-desktop-versions/generation-20260821020202-1002' "$desktop_root"
    "$cli_generation/bin/quotabot" 60 &
    installed_pid=$!
    "$test_root/unrelated/quotabot" 60 &
    unrelated_pid=$!
    sleep 0.1
    ;;
  *) echo "Unsupported test host: $host_kernel" >&2; exit 1 ;;
esac

bash "$repository_root/uninstall.sh" > "$test_root/uninstall.log" 2>&1

if [ -n "$installed_pid" ]; then
  wait "$installed_pid" 2>/dev/null || true
  if kill -0 "$installed_pid" 2>/dev/null; then
    echo 'The installed quotabot process survived uninstall.' >&2
    exit 1
  fi
  installed_pid=""
  if ! kill -0 "$unrelated_pid" 2>/dev/null; then
    echo 'Uninstall stopped an unrelated quotabot process.' >&2
    exit 1
  fi
fi
for removed in \
  "$HOME/.local/bin/quotabot" "$cli_root" "$cli_versions" \
  "$desktop_root" "$desktop_versions"; do
  if [ -e "$removed" ] || [ -L "$removed" ]; then
    echo "Uninstall retained $removed" >&2
    exit 1
  fi
done
test -f "$config_sentinel"

# macOS lsof can report the dynamic loader before the main executable. Inspect
# every text mapping, and match the physical executable when Applications is
# reached through a symlinked parent.
if [ -n "$unrelated_pid" ]; then
  kill "$unrelated_pid" 2>/dev/null || true
  wait "$unrelated_pid" 2>/dev/null || true
  unrelated_pid=""
fi
mac_home="$test_root/mac-home"
mac_physical_applications="$test_root/mac-applications"
mkdir -p "$mac_home" "$mac_physical_applications"
ln -s "$mac_physical_applications" "$mac_home/Applications"
mac_versions="$mac_home/Applications/.quotabot.app-versions"
mac_generation="$mac_versions/generation-20260821040404-1004"
mac_executable="$mac_generation/Contents/MacOS/quotabot"
mkdir -p "$(dirname "$mac_executable")"
cp "$(command -v sleep)" "$mac_executable"
ln -s '.quotabot.app-versions/generation-20260821040404-1004' \
  "$mac_home/Applications/quotabot.app"
"$mac_executable" 60 &
installed_pid=$!
sleep 0.1
mac_fake_bin="$test_root/mac-fake-bin"
mkdir -p "$mac_fake_bin"
cat > "$mac_fake_bin/uname" <<'EOF'
#!/usr/bin/env sh
printf 'Darwin\n'
EOF
cat > "$mac_fake_bin/lsof" <<'EOF'
#!/usr/bin/env sh
pid=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -p ]; then
    shift
    pid=$1
  fi
  shift
done
if [ "$pid" = "$MAC_INSTALLED_PID" ]; then
  printf 'p%s\n' "$pid"
  printf 'n/usr/lib/dyld\n'
  printf 'n%s\n' "$MAC_EXECUTABLE"
fi
EOF
chmod +x "$mac_fake_bin/uname" "$mac_fake_bin/lsof"
export MAC_INSTALLED_PID="$installed_pid"
export MAC_EXECUTABLE="$(cd "$(dirname "$mac_executable")" && pwd -P)/quotabot"
HOME="$mac_home" PATH="$mac_fake_bin:$PATH" \
  bash "$repository_root/uninstall.sh" > "$test_root/mac-uninstall.log" 2>&1
wait "$installed_pid" 2>/dev/null || true
if kill -0 "$installed_pid" 2>/dev/null; then
  echo 'The macOS installed quotabot process survived uninstall.' >&2
  exit 1
fi
installed_pid=""
test ! -e "$mac_home/Applications/quotabot.app"
test ! -L "$mac_home/Applications/quotabot.app"
test ! -e "$mac_versions"

# A failed generation-store removal must produce a nonzero result and name the
# retained payload instead of printing successful completion.
mkdir -p "$cli_versions/generation-20260821030303-1003/bin"
printf 'retained\n' > "$cli_versions/generation-20260821030303-1003/bin/quotabot"
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/rm" <<'EOF'
#!/usr/bin/env sh
case " $* " in
  *"/.quotabot-versions "*) exit 73 ;;
esac
exec "$REAL_RM" "$@"
EOF
chmod +x "$fake_bin/rm"
export REAL_RM="$real_rm"
if PATH="$fake_bin:$PATH" bash "$repository_root/uninstall.sh" \
  > "$test_root/retained.log" 2>&1; then
  echo 'Uninstall accepted a retained CLI generation store.' >&2
  exit 1
fi
grep -Fq "retained payloads" "$test_root/retained.log"
grep -Fq "$cli_versions" "$test_root/retained.log"
if grep -Fq 'successfully uninstalled' "$test_root/retained.log"; then
  echo 'Failed uninstall printed successful completion.' >&2
  exit 1
fi

printf 'POSIX uninstall tests passed.\n'
