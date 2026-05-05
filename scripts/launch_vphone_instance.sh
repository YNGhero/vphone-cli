#!/bin/zsh
# launch_vphone_instance.sh — boot one existing vphone VM directory and connect GUI/ports.
#
# Usage:
#   scripts/launch_vphone_instance.sh /absolute/or/relative/vm.dir
#
# This script is multi-instance safe: it only starts the specified VM_DIR and
# allocates per-instance local ports for SSH/VNC/RPC.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

VM_DIR_INPUT="${1:-}"
[[ -n "$VM_DIR_INPUT" ]] || { echo "Usage: $0 <vm-dir>" >&2; exit 1; }
VM_DIR_ABS="${VM_DIR_INPUT:A}"
[[ -f "${VM_DIR_ABS}/config.plist" ]] || { echo "[-] Missing VM config: ${VM_DIR_ABS}/config.plist" >&2; exit 1; }

INSTANCE_NAME="${VM_DIR_ABS:t}"
LOG_DIR="${VM_DIR_ABS}/logs"
ENV_FILE="${VM_DIR_ABS}/instance.env"
BOOT_LOG="${LOG_DIR}/boot.log"
BOOT_FIFO="${LOG_DIR}/boot.stdin"
BOOT_PID_FILE="${LOG_DIR}/boot.pid"
KEEPALIVE_PID_FILE="${LOG_DIR}/boot_stdin_keepalive.pid"
LOCK_DIR="${VM_DIR_ABS}/.launch.lock"
BUILD_LOCK_DIR="${PROJECT_ROOT}/.build/.vphone-boot-artifacts.lock"
VM_ALREADY_RUNNING=0
BUILD_LOCK_HELD=0

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

mkdir -p "$LOG_DIR"

PROJECT_ENV_FILE="${PROJECT_ROOT}/.env"
if [[ -f "$PROJECT_ENV_FILE" ]]; then
  vphone_source_config_preserving_env "$PROJECT_ENV_FILE" \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD VPHONE_INTERACTIVE_CONFIG VPHONE_SKIP_AMFIDONT
fi
PROJECT_LOCAL_CONFIG="${PROJECT_ROOT}/vphone_instance.conf"
if [[ -f "$PROJECT_LOCAL_CONFIG" ]]; then
  vphone_source_config_preserving_env "$PROJECT_LOCAL_CONFIG" \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD VPHONE_INTERACTIVE_CONFIG VPHONE_SKIP_AMFIDONT
fi

if [[ -f "$ENV_FILE" ]]; then
  vphone_source_config_preserving_env "$ENV_FILE" \
    VPHONE_SSH_PORT VPHONE_VNC_PORT VPHONE_RPC_PORT \
    SSH_LOCAL_PORT VNC_LOCAL_PORT RPC_LOCAL_PORT \
    VPHONE_VARIANT \
    VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES
fi
INSTANCE_NAME="${VM_DIR_ABS:t}"
if [[ -z "${NETWORK_MODE:-}" && -n "${VPHONE_NETWORK_MODE:-}" ]]; then
  NETWORK_MODE="$VPHONE_NETWORK_MODE"
fi
if [[ -z "${NETWORK_INTERFACE:-}" && -n "${VPHONE_NETWORK_INTERFACE:-}" ]]; then
  NETWORK_INTERFACE="$VPHONE_NETWORK_INTERFACE"
fi
if [[ -z "${VPHONE_VARIANT:-}" && -f "${VM_DIR_ABS}/.vphone_variant" ]]; then
  VPHONE_VARIANT="$(< "${VM_DIR_ABS}/.vphone_variant")"
fi
if [[ -z "${VPHONE_CYDIA_SOURCES:-}" && -n "${VPHONE_APT_SOURCES:-}" ]]; then
  VPHONE_CYDIA_SOURCES="$VPHONE_APT_SOURCES"
fi
VPHONE_VARIANT="$(vphone_variant_normalize "${VPHONE_VARIANT:-jb}")"

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

cleanup_launch_lock() {
  [[ -d "$LOCK_DIR" ]] || return 0
  local owner=""
  owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}

cleanup_build_lock() {
  (( BUILD_LOCK_HELD )) || return 0
  [[ -d "$BUILD_LOCK_DIR" ]] || return 0
  local owner=""
  owner="$(cat "${BUILD_LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ "$owner" == "$$" ]]; then
    /bin/rm -rf "$BUILD_LOCK_DIR" 2>/dev/null || true
  fi
  BUILD_LOCK_HELD=0
}

cleanup_all() {
  cleanup_build_lock
  cleanup_launch_lock
}
trap cleanup_all EXIT INT TERM

ensure_single_launcher() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    print -r -- "$$" > "${LOCK_DIR}/pid"
    return 0
  fi

  local owner="" cmd=""
  owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
  if [[ "$owner" == <-> ]] && kill -0 "$owner" 2>/dev/null; then
    cmd="$(/bin/ps -p "$owner" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"launch_vphone_instance.sh"* && "$cmd" == *"$VM_DIR_ABS"* ]]; then
      die "another launch/open operation is already running for ${INSTANCE_NAME} (pid=${owner})"
    fi
  fi

  warn "removing stale launch lock: ${LOCK_DIR}"
  /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || die "another launch/open operation is already running for ${INSTANCE_NAME}"
  print -r -- "$$" > "${LOCK_DIR}/pid"
}

acquire_build_lock() {
  mkdir -p "${PROJECT_ROOT}/.build"

  local waited=0 owner="" cmd=""
  while true; do
    if mkdir "$BUILD_LOCK_DIR" 2>/dev/null; then
      print -r -- "$$" > "${BUILD_LOCK_DIR}/pid"
      BUILD_LOCK_HELD=1
      return 0
    fi

    owner="$(cat "${BUILD_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ "$owner" == <-> ]] && kill -0 "$owner" 2>/dev/null; then
      if (( waited == 0 )); then
        say "waiting for shared build/sign lock (pid=${owner})"
      fi
      sleep 1
      waited=$(( waited + 1 ))
      continue
    fi

    cmd=""
    [[ "$owner" == <-> ]] && cmd="$(/bin/ps -p "$owner" -o command= 2>/dev/null || true)"
    warn "removing stale shared build/sign lock: ${BUILD_LOCK_DIR}${cmd:+ (${cmd})}"
    /bin/rm -rf "$BUILD_LOCK_DIR" 2>/dev/null || true
  done
}

release_build_lock() {
  cleanup_build_lock
}

ensure_boot_artifacts() {
  acquire_build_lock
  say "preparing shared app bundle/vphoned for ${INSTANCE_NAME}"
  make VM_DIR="$VM_DIR_ABS" bundle vphoned boot_binary_check
  local shared_app="${PROJECT_ROOT}/.build/vphone-cli.app"
  local instance_app="${VM_DIR_ABS}/.vphone-cli.app"
  local tmp_app="${VM_DIR_ABS}/.vphone-cli.app.tmp.$$"
  /bin/rm -rf "$tmp_app"
  /usr/bin/ditto "$shared_app" "$tmp_app"
  /bin/rm -rf "$instance_app"
  /bin/mv "$tmp_app" "$instance_app"
  release_build_lock
}

has_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

close_terminal_on_success_if_requested() {
  has_truthy "${VPHONE_LAUNCH_CLOSE_TERMINAL:-0}" || return 0
  [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0

  local tty_path
  tty_path="$(tty 2>/dev/null || true)"
  [[ "$tty_path" == /dev/ttys* ]] || return 0

  # Run after this script exits so Terminal does not warn about terminating
  # the still-running shell. Match by tty to avoid closing the wrong window.
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

read_udid() {
  awk -F= '/^UDID=/{print $2; exit}' "${VM_DIR_ABS}/udid-prediction.txt" 2>/dev/null || true
}

find_free_port() {
  local port="$1"
  [[ "$port" == <-> ]] || port=20000
  while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    port=$(( port + 1 ))
  done
  print -r -- "$port"
}

kill_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  if [[ -n "$pid" && "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
}

kill_stale_forward_for_port() {
  local port="$1"
  local udid="$2"
  local pid cmd
  [[ -n "$udid" ]] || return 0
  for pid in ${(f)$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)}; do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"pymobiledevice3 usbmux forward"* && "$cmd" == *"$udid"* ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

load_or_allocate_ports() {
  local old_instance=""
  local old_vm=""
  local old_ssh=""
  local old_vnc=""
  local old_rpc=""

  if [[ -f "$ENV_FILE" ]]; then
    old_instance="$(awk -F= '/^INSTANCE_NAME=/{gsub(/"/,"",$2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    old_vm="$(awk -F= '/^VM_DIR=/{sub(/^VM_DIR=/,""); gsub(/^"|"$/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true)"
    old_ssh="$(awk -F= '/^SSH_LOCAL_PORT=/{gsub(/"/,"",$2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    old_vnc="$(awk -F= '/^VNC_LOCAL_PORT=/{gsub(/"/,"",$2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
    old_rpc="$(awk -F= '/^RPC_LOCAL_PORT=/{gsub(/"/,"",$2); print $2; exit}' "$ENV_FILE" 2>/dev/null || true)"
  fi

  SSH_LOCAL_PORT="${VPHONE_SSH_PORT:-${old_ssh:-}}"
  VNC_LOCAL_PORT="${VPHONE_VNC_PORT:-${old_vnc:-}}"
  RPC_LOCAL_PORT="${VPHONE_RPC_PORT:-${old_rpc:-}}"

  [[ -n "$SSH_LOCAL_PORT" && "$SSH_LOCAL_PORT" == <-> ]] || SSH_LOCAL_PORT="$(find_free_port 2222)"
  [[ -n "$VNC_LOCAL_PORT" && "$VNC_LOCAL_PORT" == <-> ]] || VNC_LOCAL_PORT="$(find_free_port 5901)"
  [[ -n "$RPC_LOCAL_PORT" && "$RPC_LOCAL_PORT" == <-> ]] || RPC_LOCAL_PORT="$(find_free_port 5910)"
}

write_env_file() {
  cat > "$ENV_FILE" <<ENV
INSTANCE_NAME="${INSTANCE_NAME}"
VM_DIR="${VM_DIR_ABS}"
SSH_LOCAL_PORT="${SSH_LOCAL_PORT}"
VNC_LOCAL_PORT="${VNC_LOCAL_PORT}"
RPC_LOCAL_PORT="${RPC_LOCAL_PORT}"
VPHONE_VARIANT="${VPHONE_VARIANT:-jb}"
VPHONE_LANGUAGE="${VPHONE_LANGUAGE:-}"
VPHONE_LOCALE="${VPHONE_LOCALE:-}"
VPHONE_LANGUAGE_RESPRING="${VPHONE_LANGUAGE_RESPRING:-1}"
VPHONE_NETWORK_MODE="${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-}}"
VPHONE_NETWORK_INTERFACE="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"
NETWORK_MODE="${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-}}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"
ENV
  printf 'VPHONE_CYDIA_SOURCES=%q\n' "${VPHONE_CYDIA_SOURCES:-}" >> "$ENV_FILE"
  printf 'VPHONE_APT_SOURCES=%q\n' "${VPHONE_APT_SOURCES:-${VPHONE_CYDIA_SOURCES:-}}" >> "$ENV_FILE"
}

pid_owns_instance_path() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  /usr/sbin/lsof -p "$pid" 2>/dev/null | /usr/bin/grep -F "$VM_DIR_ABS" >/dev/null 2>&1
}

pid_is_instance_vm_process() {
  local pid="$1"
  local cmd=""
  [[ "$pid" == <-> ]] || return 1
  cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  if [[ "$cmd" == *"vphone-cli"* && "$cmd" == *"--config"* && "$cmd" != *" manager "* ]]; then
    pid_owns_instance_path "$pid" && return 0
  fi
  if [[ "$cmd" == *"com.apple.Virtualization.VirtualMachine"* ]]; then
    pid_owns_instance_path "$pid" && return 0
  fi
  return 1
}

locked_vm_pids() {
  local path
  for path in \
    "${VM_DIR_ABS}/Disk.img" \
    "${VM_DIR_ABS}/SEPStorage" \
    "${VM_DIR_ABS}/nvram.bin" \
    "${VM_DIR_ABS}/vphone.sock"; do
    [[ -e "$path" ]] || continue
    /usr/sbin/lsof -t -- "$path" 2>/dev/null || true
  done | /usr/bin/sort -u | while IFS= read -r pid; do
    pid_is_instance_vm_process "$pid" && print -r -- "$pid"
  done
}

host_app_pids() {
  local pid cmd
  for pid in ${(f)$(/usr/sbin/lsof -t +d "$VM_DIR_ABS" 2>/dev/null || true)}; do
    [[ "$pid" == <-> ]] || continue
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"vphone-cli"* && "$cmd" == *"--config"* && "$cmd" != *" manager "* ]]; then
      print -r -- "$pid"
    fi
  done
}

vm_is_running() {
  [[ -n "$(locked_vm_pids)" || -n "$(host_app_pids)" ]]
}

boot_vm_if_needed() {
  if vm_is_running; then
    VM_ALREADY_RUNNING=1
    ok "VM already running: ${INSTANCE_NAME}"
    return 0
  fi

  VM_ALREADY_RUNNING=0
  say "booting GUI for ${INSTANCE_NAME}"
  if [[ -n "${VPHONE_INSTALL_IPA:-}" ]]; then
    say "will auto-install IPA/TIPA after guest connects: ${VPHONE_INSTALL_IPA}"
  fi
  ensure_boot_artifacts
  kill_pid_file "$KEEPALIVE_PID_FILE"
  rm -f "$BOOT_FIFO"
  mkfifo "$BOOT_FIFO"
  : > "$BOOT_LOG"

  nohup tail -f /dev/null > "$BOOT_FIFO" 2>/dev/null &
  print -r -- "$!" > "$KEEPALIVE_PID_FILE"

  local boot_binary="${VM_DIR_ABS}/.vphone-cli.app/Contents/MacOS/vphone-cli"
  nohup zsh -c '
    cd "$2"
    args=(--config ./config.plist)
    if [[ -n "$5" ]]; then
      args+=(--install-ipa "$5")
    fi
    exec "$1" "${args[@]}" < "$3" > "$4" 2>&1
  ' _ "$boot_binary" "$VM_DIR_ABS" "$BOOT_FIFO" "$BOOT_LOG" "${VPHONE_INSTALL_IPA:-}" >/dev/null 2>&1 &
  print -r -- "$!" > "$BOOT_PID_FILE"

  sleep 3
  if ! kill -0 "$(cat "$BOOT_PID_FILE")" 2>/dev/null; then
    tail -n 100 "$BOOT_LOG" 2>/dev/null || true
    die "make boot exited early for ${INSTANCE_NAME}"
  fi

  ok "boot started: pid=$(cat "$BOOT_PID_FILE"), log=${BOOT_LOG}"
}

wait_for_host_socket() {
  local socket_path="${VM_DIR_ABS}/vphone.sock"
  local waited=0
  local max_wait=180
  local socket_len
  socket_len="$(/usr/bin/python3 - "$socket_path" <<'PY'
import sys
print(len(sys.argv[1].encode()) + 1)
PY
)"
  if [[ "$socket_len" == <-> ]] && (( socket_len > 103 )); then
    warn "GUI/control socket path is too long for macOS AF_UNIX (${socket_len} bytes): ${socket_path}"
    warn "skipping host-control socket wait; GUI and SSH forwarding are unaffected"
    return 1
  fi

  if (( VM_ALREADY_RUNNING )); then
    max_wait="${VPHONE_RUNNING_SOCKET_WAIT_SECONDS:-5}"
    if [[ ! -S "$socket_path" ]]; then
      warn "VM is running but host-control socket is missing: ${socket_path}"
      warn "This is usually an old GUI process or a stale socket state; use Stop then Start once to upgrade it."
      return 1
    fi
  fi

  say "waiting for GUI/control socket: ${socket_path}"
  while (( waited < max_wait )); do
    if [[ -S "$socket_path" ]]; then
      if /usr/bin/python3 - "$socket_path" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])
s.close()
PY
      then
        ok "control socket ready"
        return 0
      fi
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  warn "control socket not ready yet; VM may still be booting"
  return 1
}

show_gui_window_if_possible() {
  local socket_path="${VM_DIR_ABS}/vphone.sock"
  [[ -S "$socket_path" ]] || return 1

  /usr/bin/python3 - "$socket_path" <<'PY'
import json
import socket
import sys

socket_path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(socket_path)
s.sendall(json.dumps({"t": "show_window", "screen": False}).encode("utf-8") + b"\n")
buf = b""
try:
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
except Exception:
    raise SystemExit(1)
if buf:
    resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    if not resp.get("ok"):
        raise SystemExit(resp.get("error") or str(resp))
PY
}

focus_host_process_if_possible() {
  local pid
  for pid in ${(f)$(host_app_pids)}; do
    [[ "$pid" == <-> ]] || continue
    /usr/bin/osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events"
  set frontmost of first process whose unix id is ${pid} to true
end tell
OSA
    return 0
  done
  return 1
}

wait_for_udid_file() {
  local waited=0
  while (( waited < 120 )); do
    UDID="$(read_udid)"
    [[ -n "$UDID" ]] && return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

wait_for_usbmux_device() {
  local pmd3_py="$1"
  local waited=0
  [[ -n "$UDID" ]] || return 1
  say "waiting for usbmux device ${UDID}"
  while (( waited < 180 )); do
    if "$pmd3_py" -m pymobiledevice3 usbmux list 2>/dev/null | grep -q "$UDID"; then
      ok "usbmux device visible"
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  warn "usbmux device not visible yet"
  return 1
}

port_busy_by_other() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

start_forward() {
  local pmd3_py="$1"
  local local_port="$2"
  local remote_port="$3"
  local label="$4"

  kill_stale_forward_for_port "$local_port" "$UDID"
  sleep 0.2

  if port_busy_by_other "$local_port"; then
    local new_port
    new_port="$(find_free_port $(( local_port + 1 )))"
    warn "localhost:${local_port} busy; ${label} moved to ${new_port}"
    case "$label" in
      SSH*) SSH_LOCAL_PORT="$new_port" ;;
      VNC*) VNC_LOCAL_PORT="$new_port" ;;
      RPC*) RPC_LOCAL_PORT="$new_port" ;;
    esac
    local_port="$new_port"
  fi

  say "forward ${label}: localhost:${local_port} -> guest:${remote_port}"
  "$pmd3_py" -m pymobiledevice3 usbmux forward --daemonize --serial "$UDID" "$local_port" "$remote_port" \
    || warn "failed to start ${label} forward"
}

wait_for_ssh() {
  command -v sshpass >/dev/null 2>&1 || {
    warn "sshpass not found; skip SSH readiness checks"
    return 1
  }
  local waited=0
  say "waiting for SSH on localhost:${SSH_LOCAL_PORT}"
  while (( waited < 120 )); do
    if sshpass -p alpine ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o ConnectTimeout=3 \
      -q -p "$SSH_LOCAL_PORT" root@127.0.0.1 'echo ready' >/dev/null 2>&1; then
      ok "SSH ready"
      return 0
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
  warn "SSH not ready yet; JB finalization may still be running"
  return 1
}

write_connection_info() {
  cat > "${VM_DIR_ABS}/connection_info.txt" <<INFO
Instance: ${INSTANCE_NAME}
VM_DIR: ${VM_DIR_ABS}
UDID: ${UDID:-unknown}

Native GUI/control socket:
  ${VM_DIR_ABS}/vphone.sock

SSH:
  sshpass -p alpine ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${SSH_LOCAL_PORT} root@127.0.0.1
  Double-click helper: ${VM_DIR_ABS}/connect_ssh.command

VNC:
  vnc://127.0.0.1:${VNC_LOCAL_PORT}

RPC:
  127.0.0.1:${RPC_LOCAL_PORT}

Logs:
  ${BOOT_LOG}

Guest configuration:
  Variant: $(vphone_variant_label "${VPHONE_VARIANT:-jb}")
  Language: ${VPHONE_LANGUAGE:-default}
  Locale: ${VPHONE_LOCALE:-auto/default}
  Network: ${NETWORK_MODE:-manifest}${NETWORK_INTERFACE:+ (${NETWORK_INTERFACE})}
INFO

  cat > "${VM_DIR_ABS}/connect_ssh.command" <<EOF
#!/bin/zsh
set -euo pipefail
exec sshpass -p alpine ssh -tt \\
  -o StrictHostKeyChecking=no \\
  -o UserKnownHostsFile=/dev/null \\
  -p ${SSH_LOCAL_PORT} root@127.0.0.1
EOF
  chmod +x "${VM_DIR_ABS}/connect_ssh.command"
}

main() {
  ensure_single_launcher
  load_or_allocate_ports
  vphone_vm_apply_network_config "${VM_DIR_ABS}/config.plist" "${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-}}" "${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}" \
    || die "failed to update VM network config"
  vphone_host_ensure_amfidont "$PROJECT_ROOT" || true
  boot_vm_if_needed
  local host_socket_ready=0
  local gui_shown=0
  if wait_for_host_socket; then
    host_socket_ready=1
  fi
  if (( host_socket_ready )); then
    if show_gui_window_if_possible >/dev/null 2>&1; then
      gui_shown=1
    else
      warn "host-control socket exists but show_window failed"
    fi
  fi

  if (( VM_ALREADY_RUNNING )); then
    if (( gui_shown )); then
      ok "GUI window requested for already-running instance"
    else
      focus_host_process_if_possible || true
      warn "already-running instance could not be unhidden through host-control"
      warn "If the GUI does not appear, stop this instance once and start it again with the rebuilt vphone-cli."
    fi
    UDID="$(read_udid)"
    write_env_file
    write_connection_info
    ok "instance open request finished: ${INSTANCE_NAME}"
    print -r -- ""
    cat "${VM_DIR_ABS}/connection_info.txt"
    close_terminal_on_success_if_requested
    return 0
  fi

  wait_for_udid_file || die "UDID file was not created: ${VM_DIR_ABS}/udid-prediction.txt"

  local pmd3_py
  pmd3_py="$(python_for_pmd3)" || die "pymobiledevice3 not available. Run: make setup_tools"

  if wait_for_usbmux_device "$pmd3_py"; then
    start_forward "$pmd3_py" "$SSH_LOCAL_PORT" 22222 "SSH/dropbear"
    start_forward "$pmd3_py" "$VNC_LOCAL_PORT" 5901 "VNC"
    start_forward "$pmd3_py" "$RPC_LOCAL_PORT" 5910 "RPC"
    write_env_file
    if wait_for_ssh; then
      vphone_guest_apply_language "$SSH_LOCAL_PORT" "$VM_DIR_ABS" "${VPHONE_LANGUAGE:-}" "${VPHONE_LOCALE:-}" "${VPHONE_LANGUAGE_RESPRING:-1}" || true
    fi
  else
    write_env_file
  fi

  write_connection_info
  osascript -e 'tell application "System Events" to set frontmost of every process whose name is "vphone-cli" to true' >/dev/null 2>&1 || true
  if has_truthy "${OPEN_VNC:-0}"; then
    open "vnc://127.0.0.1:${VNC_LOCAL_PORT}" >/dev/null 2>&1 || true
  fi

  ok "instance ready: ${INSTANCE_NAME}"
  print -r -- ""
  cat "${VM_DIR_ABS}/connection_info.txt"
  print -r -- ""
  if [[ "${VPHONE_VARIANT:-}" == "jb" ]]; then
    print -r -- "TrollStore/Sileo first-boot progress:"
    print -r -- "  sshpass -p alpine ssh -p ${SSH_LOCAL_PORT} root@127.0.0.1 'tail -f /var/log/vphone_jb_setup.log'"
  fi
  close_terminal_on_success_if_requested
}

main "$@"
