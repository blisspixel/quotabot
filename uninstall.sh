#!/usr/bin/env bash
# Uninstalls the quotabot CLI and desktop app on macOS and Linux.
# Removes the CLI and desktop app installations, and removes desktop shortcuts.
# Does not delete metadata, cache, or logs unless the --purge switch is provided.

set -euo pipefail

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    -h | --help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '\033[32m    %s\033[0m\n' "$1"; }

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$os" in
  darwin*) os=darwin ;;
  linux*) os=linux ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac

cli_wrapper="$HOME/.local/bin/quotabot"
cli_root="$HOME/.local/share/quotabot"
cli_versions="$HOME/.local/share/.quotabot-versions"
linux_desktop="$HOME/.local/share/quotabot-desktop"
linux_desktop_versions="$HOME/.local/share/.quotabot-desktop-versions"
macos_desktop="$HOME/Applications/quotabot.app"
macos_desktop_versions="$HOME/Applications/.quotabot.app-versions"
desktop_entry="$HOME/.local/share/applications/quotabot.desktop"
uninstall_failed=0

installed_process_roots=()
register_installed_process_root() {
  local candidate="$1" resolved existing
  if [ ! -d "$candidate" ] || [ -L "$candidate" ]; then
    return 0
  fi
  resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 0
  [ "$resolved" != / ] || return 0
  if [ "${#installed_process_roots[@]}" -gt 0 ]; then
    for existing in "${installed_process_roots[@]}"; do
      [ "$existing" != "$resolved" ] || return 0
    done
  fi
  installed_process_roots+=("$resolved")
}
for process_root in \
  "$cli_root" "$cli_versions" \
  "$linux_desktop" "$linux_desktop_versions" \
  "$macos_desktop" "$macos_desktop_versions"; do
  register_installed_process_root "$process_root"
done

is_installed_executable_path() {
  local executable="$1" process_root
  if [ "${#installed_process_roots[@]}" -gt 0 ]; then
    for process_root in "${installed_process_roots[@]}"; do
      case "$executable" in
        "$process_root"/*) return 0 ;;
      esac
    done
  fi
  return 1
}

installed_process_path() {
  local pid="$1" executable=""
  if [ "$os" = linux ] && [ -e "/proc/$pid/exe" ]; then
    executable="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    executable="${executable% (deleted)}"
    if is_installed_executable_path "$executable"; then
      printf '%s\n' "$executable"
      return 0
    fi
  elif command -v lsof >/dev/null 2>&1; then
    while IFS= read -r executable; do
      if is_installed_executable_path "$executable"; then
        printf '%s\n' "$executable"
        return 0
      fi
    done < <(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p')
  fi
  return 1
}

stop_installed_quotabot_processes() {
  local pid attempt
  local installed_pids=()
  while IFS= read -r pid; do
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    if installed_process_path "$pid" >/dev/null; then
      installed_pids+=("$pid")
    fi
  done < <(pgrep -x quotabot 2>/dev/null || true)

  if [ "${#installed_pids[@]}" -eq 0 ]; then
    ok 'No installed quotabot process is running'
    return 0
  fi
  for pid in "${installed_pids[@]}"; do
    if installed_process_path "$pid" >/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    remaining=0
    for pid in "${installed_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then remaining=1; fi
    done
    [ "$remaining" -eq 0 ] && break
    sleep 0.1
  done
  for pid in "${installed_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null && \
       installed_process_path "$pid" >/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  for pid in "${installed_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null && \
       installed_process_path "$pid" >/dev/null; then
      printf 'Installed quotabot process %s did not stop.\n' "$pid" >&2
      return 1
    fi
  done
  ok "Stopped ${#installed_pids[@]} installed process(es)"
}

remove_guarded_payload() {
  local target="$1"
  case "$target" in
    "$cli_wrapper" | "$cli_root" | "$cli_versions" | \
    "$linux_desktop" | "$linux_desktop_versions" | \
    "$macos_desktop" | "$macos_desktop_versions") ;;
    *)
      printf 'Refusing to remove an unexpected uninstall target: %s\n' "$target" >&2
      return 1
      ;;
  esac
  if [ -e "$target" ] || [ -L "$target" ]; then
    rm -rf -- "$target"
  fi
}

step 'Stopping installed quotabot processes'
stop_installed_quotabot_processes || uninstall_failed=1

step 'Removing CLI and desktop installations'
for payload in \
  "$cli_wrapper" "$cli_root" "$cli_versions" \
  "$linux_desktop" "$linux_desktop_versions" \
  "$macos_desktop" "$macos_desktop_versions"; do
  remove_guarded_payload "$payload" || uninstall_failed=1
done
if [ -e "$desktop_entry" ] || [ -L "$desktop_entry" ]; then
  rm -f -- "$desktop_entry" || uninstall_failed=1
fi

retained_payloads=()
for payload in \
  "$cli_wrapper" "$cli_root" "$cli_versions" \
  "$linux_desktop" "$linux_desktop_versions" \
  "$macos_desktop" "$macos_desktop_versions"; do
  if [ -e "$payload" ] || [ -L "$payload" ]; then
    retained_payloads+=("$payload")
  fi
done
if [ -e "$desktop_entry" ] || [ -L "$desktop_entry" ]; then
  retained_payloads+=("$desktop_entry")
fi
if [ "${#retained_payloads[@]}" -gt 0 ]; then
  printf 'Quotabot uninstall retained payloads:\n' >&2
  printf '  %s\n' "${retained_payloads[@]}" >&2
  uninstall_failed=1
fi

if [ "$purge" -eq 1 ]; then
  step 'Purging metadata, cache, and logs'
  if [ -d "$HOME/.cache/quotabot" ]; then
    rm -rf "$HOME/.cache/quotabot" || uninstall_failed=1
  fi
  # Resolve the data directory the way quotabot itself does: XDG_CONFIG_HOME
  # when set, otherwise ~/.config, on every POSIX platform including macOS.
  # Purging a macOS-looking Application Support path removed nothing while
  # still reporting success, and ignoring XDG_CONFIG_HOME left a relocated
  # directory behind. This root holds OAuth grants under auth/ as well as
  # profiles, manual entries, leases, and loopback tokens, so a purge that
  # misses it leaves credentials on disk.
  data_root="${XDG_CONFIG_HOME:-$HOME/.config}/quotabot"
  if [ -d "$data_root" ]; then
    rm -rf "$data_root" || uninstall_failed=1
  fi
  if [ -d "$data_root" ]; then
    printf 'Some files under %s could not be removed; delete it manually.\n' "$data_root" >&2
  else
    ok "Purged quotabot data directory ($data_root)"
  fi
fi

if [ "$uninstall_failed" -ne 0 ]; then
  echo 'quotabot uninstall was incomplete.' >&2
  exit 1
fi

printf '\n\033[32mquotabot has been successfully uninstalled.\033[0m\n'
