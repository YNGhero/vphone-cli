#!/bin/zsh
# launch_vphone_manager.sh — open the standalone local vphone instance manager.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  vphone_source_config_preserving_env "${PROJECT_ROOT}/.env"
fi

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

LOG_DIR="${PROJECT_ROOT}/setup_logs"
LOG_FILE="${LOG_DIR}/vphone_manager.log"
mkdir -p "$LOG_DIR"

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }

close_terminal_on_success_if_requested() {
  case "${VPHONE_MANAGER_CLOSE_TERMINAL:-0}" in
    1|true|TRUE|yes|YES|y|Y) ;;
    *) return 0 ;;
  esac
  [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0

  local tty_path
  tty_path="$(tty 2>/dev/null || true)"
  [[ "$tty_path" == /dev/ttys* ]] || return 0

  /usr/bin/osascript >/dev/null 2>&1 <<OSA &
delay 1.0
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (tty of t) is "${tty_path}" then
          if (count of tabs of w) is 1 then
            close w
          else
            close t
          end if
          return
        end if
      end try
    end repeat
  end repeat
end tell
OSA
}

say "building vphone-cli manager"
if ! make build >> "$LOG_FILE" 2>&1; then
  warn "build failed; log=${LOG_FILE}"
  tail -120 "$LOG_FILE" >&2 || true
  exit 1
fi

if ! vphone_release_launchable "${PROJECT_ROOT}/.build/release/vphone-cli"; then
  warn "signed vphone-cli is not launchable yet; trying amfidont"
  vphone_setup_sudo_password 0 >> "$LOG_FILE" 2>&1 || true
  if ! zsh "${PROJECT_ROOT}/scripts/start_amfidont_for_vphone.sh" >> "$LOG_FILE" 2>&1; then
    warn "amfidont setup failed; log=${LOG_FILE}"
    tail -120 "$LOG_FILE" >&2 || true
    exit 1
  fi
  sleep 1
  if ! vphone_release_launchable "${PROJECT_ROOT}/.build/release/vphone-cli"; then
    warn "signed vphone-cli still not launchable after amfidont; log=${LOG_FILE}"
    tail -120 "$LOG_FILE" >&2 || true
    exit 1
  fi
fi

say "launching standalone manager"
"${PROJECT_ROOT}/.build/release/vphone-cli" manager --project-root "$PROJECT_ROOT" >> "$LOG_FILE" 2>&1 &
manager_pid="$!"

sleep 1
if ! kill -0 "$manager_pid" 2>/dev/null; then
  warn "manager exited immediately; log=${LOG_FILE}"
  tail -120 "$LOG_FILE" >&2 || true
  exit 1
fi

disown "$manager_pid" 2>/dev/null || true
ok "vphone manager started (pid=${manager_pid}, log=${LOG_FILE})"
close_terminal_on_success_if_requested
