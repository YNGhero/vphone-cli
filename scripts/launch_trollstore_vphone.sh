#!/bin/zsh
# launch_trollstore_vphone.sh — one-click TrollStore/JB vphone bootstrap + GUI boot.
#
# First run:
#   - safely stops the active VM
#   - backs up the current non-JB vm/ to vm.backups/regular-before-trollstore-*
#   - creates a fresh jailbreak/TrollStore VM via make setup_machine JB=1
#   - saves it as vm.backups/trollstore-jb
# Subsequent runs:
#   - restores vm.backups/trollstore-jb if needed
#   - boots the native vphone GUI
#   - starts usbmux forwards for SSH/VNC/RPC

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

# Optional local secrets/config for Finder double-click workflows.
# Priority: current shell environment > .env > vphone_instance.conf.
ENV_CONFIG="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_CONFIG" ]]; then
  vphone_source_config_preserving_env "$ENV_CONFIG" \
    CPU MEMORY MEMORY_GB DISK_SIZE \
    VPHONE_INTERACTIVE_CONFIG VPHONE_VM_DIR VPHONE_BACKUPS_DIR \
    VPHONE_VARIANT VPHONE_JB_BACKUP_NAME VPHONE_DEV_BACKUP_NAME VPHONE_REGULAR_BACKUP_NAME VPHONE_REGULAR_BACKUP_PREFIX \
    VPHONE_SSH_PORT VPHONE_VNC_PORT VPHONE_RPC_PORT OPEN_VNC \
    VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD
fi

# Optional local sizing/port config for Finder double-click workflows.
# Copy vphone_instance.conf.example to vphone_instance.conf and edit it.
LOCAL_CONFIG="${PROJECT_ROOT}/vphone_instance.conf"
if [[ -f "$LOCAL_CONFIG" ]]; then
  vphone_source_config_preserving_env "$LOCAL_CONFIG" \
    CPU MEMORY MEMORY_GB DISK_SIZE \
    VPHONE_INTERACTIVE_CONFIG VPHONE_VM_DIR VPHONE_BACKUPS_DIR \
    VPHONE_VARIANT VPHONE_JB_BACKUP_NAME VPHONE_DEV_BACKUP_NAME VPHONE_REGULAR_BACKUP_NAME VPHONE_REGULAR_BACKUP_PREFIX \
    VPHONE_SSH_PORT VPHONE_VNC_PORT VPHONE_RPC_PORT OPEN_VNC \
    VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD
fi

# Values loaded from vphone_instance.conf are shell variables, not exported by
# default. Export creation-time settings so nested make/setup_machine receives
# them when a fresh TrollStore/JB VM must be created.
[[ -n "${CPU:-}" ]] && export CPU
[[ -n "${MEMORY_GB:-}" && "$MEMORY_GB" == <-> ]] && MEMORY=$(( MEMORY_GB * 1024 ))
[[ -n "${MEMORY:-}" ]] && export MEMORY
[[ -n "${MEMORY_GB:-}" ]] && export MEMORY_GB
[[ -n "${DISK_SIZE:-}" ]] && export DISK_SIZE
if [[ -z "${NETWORK_MODE:-}" && -n "${VPHONE_NETWORK_MODE:-}" ]]; then
  NETWORK_MODE="$VPHONE_NETWORK_MODE"
fi
if [[ -z "${NETWORK_INTERFACE:-}" && -n "${VPHONE_NETWORK_INTERFACE:-}" ]]; then
  NETWORK_INTERFACE="$VPHONE_NETWORK_INTERFACE"
fi
[[ -n "${NETWORK_MODE:-}" ]] && export NETWORK_MODE
[[ -n "${NETWORK_INTERFACE:-}" ]] && export NETWORK_INTERFACE
if [[ -z "${VPHONE_CYDIA_SOURCES:-}" && -n "${VPHONE_APT_SOURCES:-}" ]]; then
  VPHONE_CYDIA_SOURCES="$VPHONE_APT_SOURCES"
fi
[[ -n "${VPHONE_CYDIA_SOURCES:-}" ]] && export VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES="$VPHONE_CYDIA_SOURCES"

JB_BACKUP_NAME="${VPHONE_JB_BACKUP_NAME:-trollstore-jb}"
REGULAR_BACKUP_PREFIX="${VPHONE_REGULAR_BACKUP_PREFIX:-regular-before-trollstore}"
TARGET_BACKUP_NAME=""
TARGET_VARIANT_LABEL=""
VM_DIR="${VPHONE_VM_DIR:-vm}"
BACKUPS_DIR="${VPHONE_BACKUPS_DIR:-vm.backups}"
LOG_DIR="${PROJECT_ROOT}/setup_logs"
SETUP_LOG="${LOG_DIR}/trollstore_setup.log"
BOOT_LOG="${LOG_DIR}/trollstore_boot.log"
BOOT_FIFO="${LOG_DIR}/trollstore_boot.stdin"
BOOT_PID_FILE="${LOG_DIR}/trollstore_boot.pid"
KEEPALIVE_PID_FILE="${LOG_DIR}/trollstore_boot_stdin_keepalive.pid"
SSH_LOCAL_PORT="${VPHONE_SSH_PORT:-2222}"
VNC_LOCAL_PORT="${VPHONE_VNC_PORT:-5901}"
RPC_LOCAL_PORT="${VPHONE_RPC_PORT:-5910}"
OPEN_VNC="${OPEN_VNC:-0}"

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

mkdir -p "$LOG_DIR"

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

cleanup() {
  vphone_cleanup_sudo_password
}
trap cleanup EXIT INT TERM

has_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

run_logged() {
  local label="$1"
  shift
  say "$label"
  print -r -- "\n===== $(date '+%F %T') :: $label =====" >> "$SETUP_LOG"
  "$@" 2>&1 | tee -a "$SETUP_LOG"
}

python_for_pmd3() {
  local candidate
  for candidate in \
    "${PROJECT_ROOT}/.venv/bin/python3" \
    "$(command -v python3 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" -c 'import pymobiledevice3' >/dev/null 2>&1; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_xcode_sdk() {
  say "checking Xcode/iPhoneOS SDK"
  local dev
  dev="$(xcode-select -p 2>/dev/null || true)"
  [[ "$dev" == "/Applications/Xcode.app/Contents/Developer" ]] || {
    warn "xcode-select is '$dev'"
    warn "switching to full Xcode; sudo may ask for your password"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  }
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iPhoneOS SDK not found. Install full Xcode, then rerun this script."
  ok "Xcode SDK available: $(xcrun --sdk iphoneos --show-sdk-path)"
}

ensure_amfidont() {
  if pgrep -f "amfidont.*--path ${PROJECT_ROOT}" >/dev/null 2>&1; then
    ok "amfidont already running for this project"
    return
  fi

  if ! command -v amfidont >/dev/null 2>&1; then
    warn "amfidont command not found; installing with xcrun python3 -m pip"
    xcrun python3 -m pip install -U amfidont
  fi

  local amfidont_bin
  amfidont_bin="$(command -v amfidont 2>/dev/null || true)"
  [[ -n "$amfidont_bin" ]] || die "amfidont install completed but command is still not on PATH"

  warn "starting amfidont; sudo may ask for your password"
  sudo "$amfidont_bin" daemon --path "$PROJECT_ROOT" --spoof-apple >/dev/null 2>&1
  ok "amfidont started"
}

kill_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

kill_pmd3_listener_on_port() {
  local port="$1"
  local pid cmd
  for pid in ${(f)$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)}; do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"pymobiledevice3 usbmux forward"* ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

stop_forwards() {
  say "stopping old local usbmux forwards if any"
  kill_pmd3_listener_on_port "$SSH_LOCAL_PORT"
  kill_pmd3_listener_on_port "$VNC_LOCAL_PORT"
  kill_pmd3_listener_on_port "$RPC_LOCAL_PORT"
}

try_halt_guest() {
  local port="$1"
  command -v sshpass >/dev/null 2>&1 || return 0
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    sshpass -p alpine ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o ConnectTimeout=3 \
      -p "$port" root@127.0.0.1 \
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin; halt || shutdown -h now" \
      >/dev/null 2>&1 || true
  fi
}

stop_vm() {
  say "stopping active vphone VM if any"
  kill_pid_file "$KEEPALIVE_PID_FILE"

  # Also clean up keepalive files from previous manual runs.
  for f in "$LOG_DIR"/*stdin_keepalive.pid(N); do
    kill_pid_file "$f"
  done

  try_halt_guest "$SSH_LOCAL_PORT"

  local waited=0
  while pgrep -f "${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli --config ./config.plist" >/dev/null 2>&1 && (( waited < 25 )); do
    sleep 1
    waited=$(( waited + 1 ))
  done

  if pgrep -f "${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli --config ./config.plist" >/dev/null 2>&1; then
    warn "VM did not halt quickly; terminating host process"
    pkill -TERM -f "${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli --config ./config.plist" 2>/dev/null || true
    sleep 3
    pkill -KILL -f "${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli --config ./config.plist" 2>/dev/null || true
  fi

  pkill -TERM -f "make boot" 2>/dev/null || true
  rm -f "$BOOT_FIFO"
}

configure_variant_state() {
  VPHONE_VARIANT="$(vphone_variant_normalize "${VPHONE_VARIANT:-jb}")"
  TARGET_BACKUP_NAME="$(vphone_variant_backup_name "$VPHONE_VARIANT")"
  TARGET_VARIANT_LABEL="$(vphone_variant_label "$VPHONE_VARIANT")"
}

active_vm_matches_target() {
  [[ -n "$TARGET_BACKUP_NAME" ]] || configure_variant_state
  [[ -f "${VM_DIR}/.vphone_variant" && "$(< "${VM_DIR}/.vphone_variant")" == "$VPHONE_VARIANT" ]] && return 0
  [[ -f "${VM_DIR}/.vm_name" && "$(< "${VM_DIR}/.vm_name")" == "$TARGET_BACKUP_NAME" ]] && return 0
  return 1
}

backup_active_if_needed() {
  [[ -d "$VM_DIR" && -f "${VM_DIR}/config.plist" ]] || return 0
  active_vm_matches_target && return 0

  local stamp name
  stamp="$(date '+%Y%m%d-%H%M%S')"
  name="${REGULAR_BACKUP_PREFIX}-before-${TARGET_BACKUP_NAME}-${stamp}"
  say "saving current VM as backup: ${name}"
  BACKUP_INCLUDE_IPSW=0 make vm_backup NAME="$name"
}

can_skip_project_setup() {
  [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]] || return 1
  "${PROJECT_ROOT}/.venv/bin/python3" -c 'import pymobiledevice3, capstone, keystone, pyimg4' >/dev/null 2>&1 || return 1
  [[ -f "${PROJECT_ROOT}/.build/release/vphone-cli" ]] || return 1
  return 0
}

create_target_vm() {
  say "creating fresh ${TARGET_VARIANT_LABEL} VM; this is long on first run"
  warn "setup log: ${SETUP_LOG}"

  backup_active_if_needed
  rm -rf "$VM_DIR"

  local make_args
  make_args=(setup_machine NONE_INTERACTIVE=1)
  case "$VPHONE_VARIANT" in
    dev) make_args+=(DEV=1) ;;
    jb) make_args+=(JB=1) ;;
  esac
  if can_skip_project_setup; then
    make_args+=(SKIP_PROJECT_SETUP=1)
  fi

  export BOOT_ANALYSIS_TIMEOUT="${BOOT_ANALYSIS_TIMEOUT:-600}"
  export BOOT_PROMPT_FALLBACK_TIMEOUT="${BOOT_PROMPT_FALLBACK_TIMEOUT:-120}"
  export RAMDISK_SSH_TIMEOUT="${RAMDISK_SSH_TIMEOUT:-120}"
  export SKIP_BOOT_ANALYSIS="${SKIP_BOOT_ANALYSIS:-1}"
  run_logged "make ${make_args[*]}" make "${make_args[@]}"

  [[ -d "$VM_DIR" && -f "${VM_DIR}/config.plist" ]] || die "${TARGET_VARIANT_LABEL} setup finished but ${VM_DIR}/config.plist is missing"

  print -r -- "$TARGET_BACKUP_NAME" > "${VM_DIR}/.vm_name"
  print -r -- "$VPHONE_VARIANT" > "${VM_DIR}/.vphone_variant"
  date '+%F %T' > "${VM_DIR}/.vphone_${VPHONE_VARIANT}_created_at"

  say "saving ${TARGET_VARIANT_LABEL} VM backup: ${TARGET_BACKUP_NAME}"
  BACKUP_INCLUDE_IPSW=0 make vm_backup NAME="$TARGET_BACKUP_NAME"
  ok "${TARGET_VARIANT_LABEL} VM created and saved"
}

ensure_target_vm_active() {
  configure_variant_state
  if active_vm_matches_target; then
    ok "active VM is already ${TARGET_BACKUP_NAME} (${TARGET_VARIANT_LABEL})"
    return
  fi

  if [[ -f "${BACKUPS_DIR}/${TARGET_BACKUP_NAME}/config.plist" ]]; then
    backup_active_if_needed
    say "restoring ${TARGET_VARIANT_LABEL} backup: ${TARGET_BACKUP_NAME}"
    FORCE=1 make vm_restore NAME="$TARGET_BACKUP_NAME"
    print -r -- "$VPHONE_VARIANT" > "${VM_DIR}/.vphone_variant"
    print -r -- "$TARGET_BACKUP_NAME" > "${VM_DIR}/.vm_name"
    ok "${TARGET_VARIANT_LABEL} backup restored"
    return
  fi

  create_target_vm
}

read_udid() {
  awk -F= '/^UDID=/{print $2; exit}' "${VM_DIR}/udid-prediction.txt" 2>/dev/null || true
}

wait_for_host_socket() {
  local socket_path="${VM_DIR}/vphone.sock"
  local waited=0
  say "waiting for native GUI/control socket"
  while (( waited < 180 )); do
    if [[ -S "$socket_path" ]]; then
      if /usr/bin/python3 - "$socket_path" <<'PY' >/dev/null 2>&1
import socket, sys
s=socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])
s.close()
PY
      then
        ok "GUI/control socket ready: ${socket_path}"
        return 0
      fi
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  warn "GUI socket not confirmed within timeout; VM may still be booting. Log: ${BOOT_LOG}"
  return 1
}

wait_for_usbmux_device() {
  local udid="$1"
  local pmd3_py="$2"
  local waited=0
  [[ -n "$udid" ]] || return 1
  say "waiting for usbmux device ${udid}"
  while (( waited < 180 )); do
    if "$pmd3_py" -m pymobiledevice3 usbmux list 2>/dev/null | grep -q "$udid"; then
      ok "usbmux device visible"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  warn "usbmux device not visible yet; forwards may be unavailable"
  return 1
}

start_forward() {
  local pmd3_py="$1"
  local udid="$2"
  local local_port="$3"
  local remote_port="$4"
  local label="$5"

  if lsof -nP -iTCP:"$local_port" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "localhost:${local_port} already listening; skip ${label} forward"
    return 0
  fi

  say "starting ${label} forward: localhost:${local_port} -> guest:${remote_port}"
  "$pmd3_py" -m pymobiledevice3 usbmux forward --daemonize --serial "$udid" "$local_port" "$remote_port" || {
    warn "failed to start ${label} forward"
    return 1
  }
}

wait_for_ssh() {
  command -v sshpass >/dev/null 2>&1 || {
    warn "sshpass not found; skip SSH readiness checks"
    return 1
  }
  local waited=0
  say "waiting for root SSH on localhost:${SSH_LOCAL_PORT}"
  while (( waited < 90 )); do
    if sshpass -p alpine ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o ConnectTimeout=3 \
      -q -p "$SSH_LOCAL_PORT" root@127.0.0.1 'echo ready' >/dev/null 2>&1; then
      ok "SSH ready: sshpass -p alpine ssh -p ${SSH_LOCAL_PORT} root@127.0.0.1"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  warn "SSH not ready yet; it may still be booting/finalizing"
  return 1
}

boot_gui() {
  stop_forwards
  stop_vm

  vphone_vm_apply_network_config "${VM_DIR}/config.plist" "${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-}}" "${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}" \
    || die "failed to update VM network config"

  say "booting native vphone GUI"
  rm -f "$BOOT_FIFO"
  mkfifo "$BOOT_FIFO"
  : > "$BOOT_LOG"

  nohup tail -f /dev/null > "$BOOT_FIFO" 2>/dev/null &
  print -r -- "$!" > "$KEEPALIVE_PID_FILE"

  nohup zsh -c 'cd "$1" && make boot < "$2" > "$3" 2>&1' _ "$PROJECT_ROOT" "$BOOT_FIFO" "$BOOT_LOG" >/dev/null 2>&1 &
  print -r -- "$!" > "$BOOT_PID_FILE"

  ok "boot started (pid=$(cat "$BOOT_PID_FILE"), log=${BOOT_LOG})"
  sleep 3
  if ! kill -0 "$(cat "$BOOT_PID_FILE")" 2>/dev/null; then
    tail -n 80 "$BOOT_LOG" 2>/dev/null || true
    die "make boot exited early"
  fi

  wait_for_host_socket || true

  local udid pmd3_py
  udid="$(read_udid)"
  pmd3_py="$(python_for_pmd3)" || die "pymobiledevice3 is not importable. Run: make setup_tools"

  if wait_for_usbmux_device "$udid" "$pmd3_py"; then
    start_forward "$pmd3_py" "$udid" "$SSH_LOCAL_PORT" 22222 "SSH/dropbear" || true
    start_forward "$pmd3_py" "$udid" "$VNC_LOCAL_PORT" 5901 "VNC" || true
    start_forward "$pmd3_py" "$udid" "$RPC_LOCAL_PORT" 5910 "RPC" || true
    if wait_for_ssh; then
      vphone_guest_apply_language "$SSH_LOCAL_PORT" "$VM_DIR" "${VPHONE_LANGUAGE:-}" "${VPHONE_LOCALE:-}" "${VPHONE_LANGUAGE_RESPRING:-1}" || true
    fi
  fi

  osascript -e 'tell application "System Events" to set frontmost of every process whose name is "vphone-cli" to true' >/dev/null 2>&1 || true

  if has_truthy "$OPEN_VNC"; then
    open "vnc://127.0.0.1:${VNC_LOCAL_PORT}" >/dev/null 2>&1 || true
  fi

  ok "GUI is launching/active"
  print -r -- ""
  print -r -- "Useful endpoints:"
  print -r -- "  Native automation socket: ${VM_DIR}/vphone.sock"
  print -r -- "  SSH:  sshpass -p alpine ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${SSH_LOCAL_PORT} root@127.0.0.1"
  print -r -- "  VNC:  vnc://127.0.0.1:${VNC_LOCAL_PORT}"
  print -r -- "  RPC:  127.0.0.1:${RPC_LOCAL_PORT}"
  print -r -- "  Boot log: ${BOOT_LOG}"
  print -r -- "  Variant: ${TARGET_VARIANT_LABEL}"
  print -r -- "  Language: ${VPHONE_LANGUAGE:-default} / locale ${VPHONE_LOCALE:-auto/default}"
  print -r -- "  Network: ${NETWORK_MODE:-manifest}${NETWORK_INTERFACE:+ (${NETWORK_INTERFACE})}"
  print -r -- ""
  if [[ "$VPHONE_VARIANT" == "jb" ]]; then
    print -r -- "If TrollStore/Sileo are not visible immediately, wait for JB finalization:"
    print -r -- "  sshpass -p alpine ssh -p ${SSH_LOCAL_PORT} root@127.0.0.1 'tail -f /var/log/vphone_jb_setup.log'"
  fi
}

main() {
  if vphone_prompt_enabled; then
    print -r -- "" > /dev/tty
    print -r -- "=== vphone 固件版本 ===" > /dev/tty
    vphone_prompt_variant
  fi

  configure_variant_state

  local prompt_size=0
  if ! active_vm_matches_target && [[ ! -f "${BACKUPS_DIR}/${TARGET_BACKUP_NAME}/config.plist" ]]; then
    prompt_size=1
  fi
  vphone_prompt_runtime_config "$prompt_size" 0
  vphone_export_runtime_config
  configure_variant_state

  vphone_setup_sudo_password "$prompt_size"
  ensure_xcode_sdk
  ensure_amfidont
  # Stop the currently running regular/dev VM before backup/restore/create.
  # This avoids inconsistent sparse-disk snapshots and vm_restore lock errors.
  stop_forwards
  stop_vm
  ensure_target_vm_active
  boot_gui
}

main "$@"
