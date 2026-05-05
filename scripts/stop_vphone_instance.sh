#!/bin/zsh
# stop_vphone_instance.sh — stop one existing vphone VM and its local forwards.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

VM_DIR_INPUT="${1:-}"
[[ -n "$VM_DIR_INPUT" ]] || { echo "Usage: $0 <vm-dir>" >&2; exit 1; }
VM_DIR="${VM_DIR_INPUT:A}"
[[ -f "${VM_DIR}/config.plist" ]] || { echo "[-] Missing VM config: ${VM_DIR}/config.plist" >&2; exit 1; }

ENV_FILE="${VM_DIR}/instance.env"
LOG_DIR="${VM_DIR}/logs"
STOP_LOG="${LOG_DIR}/stop.log"
BOOT_PID_FILE="${LOG_DIR}/boot.pid"
KEEPALIVE_PID_FILE="${LOG_DIR}/boot_stdin_keepalive.pid"

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

mkdir -p "$LOG_DIR"

if [[ -f "$ENV_FILE" ]]; then
  vphone_source_config_preserving_env "$ENV_FILE" \
    SSH_LOCAL_PORT VNC_LOCAL_PORT RPC_LOCAL_PORT VPHONE_SSH_PORT VPHONE_VNC_PORT VPHONE_RPC_PORT
fi

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

child_pids() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 0
  pgrep -P "$pid" 2>/dev/null || true
}

kill_process_tree() {
  local signal="$1"
  local pid="$2"
  local child
  [[ "$pid" == <-> ]] || return 0
  for child in ${(f)$(child_pids "$pid")}; do
    kill_process_tree "$signal" "$child"
  done
  kill "-${signal}" "$pid" 2>/dev/null || true
}

pid_owns_instance_path() {
  local pid="$1"
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  /usr/sbin/lsof -p "$pid" 2>/dev/null | /usr/bin/grep -F "$VM_DIR" >/dev/null 2>&1
}

pid_is_instance_related() {
  local pid="$1"
  local cmd=""
  [[ "$pid" == <-> ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"

  # Direct script/make invocations include the absolute VM path.
  [[ "$cmd" == *"$VM_DIR"* ]] && return 0

  # The GUI app is often launched from inside VM_DIR with "--config ./config.plist",
  # so the command line alone is not enough to disambiguate instances.
  if [[ "$cmd" == *"vphone-cli"* && "$cmd" == *"--config"* && "$cmd" != *" manager "* ]]; then
    pid_owns_instance_path "$pid" && return 0
  fi

  # Virtualization XPC services do not mention the VM path in argv, but they keep
  # Disk.img/SEPStorage/nvram.bin open.  Only kill them when lsof ties them to
  # this exact instance directory.
  if [[ "$cmd" == *"com.apple.Virtualization.VirtualMachine"* ]]; then
    pid_owns_instance_path "$pid" && return 0
  fi

  return 1
}

kill_pid_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local pid
  pid="$(cat "$file" 2>/dev/null || true)"
  if [[ "$pid" == <-> ]] && kill -0 "$pid" 2>/dev/null; then
    if pid_is_instance_related "$pid"; then
      kill_process_tree TERM "$pid"
    else
      warn "pid file is stale or unrelated, not killing pid=${pid}: ${file}"
    fi
  fi
  rm -f "$file"
}

kill_listener_on_port() {
  local port="$1"
  local pid cmd
  [[ "$port" == <-> ]] || return 0
  for pid in ${(f)$(/usr/sbin/lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)}; do
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"pymobiledevice3 usbmux forward"* ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

try_halt_guest() {
  local port="${SSH_LOCAL_PORT:-${VPHONE_SSH_PORT:-}}"
  [[ "$port" == <-> ]] || return 1
  command -v sshpass >/dev/null 2>&1 || return 1

  say "requesting guest halt over SSH localhost:${port}"
  sshpass -p alpine ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o ConnectTimeout=3 \
    -q -p "$port" root@127.0.0.1 \
    "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:\$PATH; halt || shutdown -h now" \
    >/dev/null 2>&1 || return 1
}

try_terminate_host_control() {
  local socket_path="${VM_DIR}/vphone.sock"
  [[ -S "$socket_path" ]] || return 1

  say "requesting vphone host process termination over ${socket_path}"
  /usr/bin/python3 - "$socket_path" <<'PY'
from __future__ import annotations
import json
import socket
import sys

socket_path = sys.argv[1]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(socket_path)
    s.sendall(json.dumps({"t": "terminate_host", "screen": False}).encode("utf-8") + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    if not buf:
        raise RuntimeError("no response from host-control")
    resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    if not resp.get("ok"):
        raise RuntimeError(resp.get("error") or str(resp))
    print(resp.get("msg") or "terminating")
except Exception as exc:
    raise SystemExit(f"host-control request failed: {exc}")
PY
}

locked_pids() {
  local path
  for path in \
    "${VM_DIR}/Disk.img" \
    "${VM_DIR}/SEPStorage" \
    "${VM_DIR}/nvram.bin" \
    "${VM_DIR}/vphone.sock"; do
    [[ -e "$path" ]] || continue
    /usr/sbin/lsof -t -- "$path" 2>/dev/null || true
  done | /usr/bin/sort -u | while IFS= read -r pid; do
    pid_is_instance_related "$pid" && print -r -- "$pid"
  done
}

host_app_pids() {
  local pid cmd
  # The vphone-cli app runs with cwd=<VM_DIR> and owns vphone.sock.  It may be
  # orphaned under launchd after the double-click launcher exits, so boot.pid is
  # not enough to find it.
  for pid in ${(f)$(/usr/sbin/lsof -t +d "$VM_DIR" 2>/dev/null || true)}; do
    [[ "$pid" == <-> ]] || continue
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$cmd" == *"vphone-cli"* && "$cmd" != *" manager "* ]]; then
      print -r -- "$pid"
    fi
  done
}

instance_launcher_pids() {
  local pid cmd
  /bin/ps ax -o pid= -o command= | while read -r pid cmd; do
    [[ "$pid" == <-> ]] || continue
    [[ "$pid" == "$$" ]] && continue
    [[ "$cmd" == *"$VM_DIR"* ]] || continue
    if [[ "$cmd" == *"launch_vphone_instance.sh"* || "$cmd" == *"make VM_DIR="* || "$cmd" == *" make "*"boot"* ]]; then
      print -r -- "$pid"
    fi
  done
}

instance_host_pids() {
  {
    instance_launcher_pids
    host_app_pids
    locked_pids
  } | /usr/bin/sort -u
}

wait_for_instance_stopped() {
  local waited=0
  while (( waited < ${1:-15} )); do
    if [[ -z "$(instance_host_pids)" ]]; then
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  return 1
}

stop_host_processes() {
  local pids pid
  pids=("${(@f)$(instance_host_pids)}")
  pids=("${(@)pids:#}")
  (( ${#pids[@]} > 0 )) || return 0

  warn "terminating host VM process(es): ${pids[*]}"
  for pid in "${pids[@]}"; do
    [[ "$pid" == <-> ]] || continue
    kill_process_tree TERM "$pid"
  done
  sleep 3

  pids=("${(@f)$(instance_host_pids)}")
  pids=("${(@)pids:#}")
  (( ${#pids[@]} > 0 )) || return 0
  warn "force killing host VM process(es): ${pids[*]}"
  for pid in "${pids[@]}"; do
    [[ "$pid" == <-> ]] || continue
    kill_process_tree KILL "$pid"
  done
  sleep 1

  pids=("${(@f)$(instance_host_pids)}")
  pids=("${(@)pids:#}")
  (( ${#pids[@]} == 0 ))
}

stop_launcher_processes() {
  local pids pid
  pids=("${(@f)$(instance_launcher_pids)}")
  pids=("${(@)pids:#}")
  (( ${#pids[@]} > 0 )) || return 0

  warn "terminating launcher/helper process(es): ${pids[*]}"
  for pid in "${pids[@]}"; do
    [[ "$pid" == <-> ]] || continue
    kill_process_tree TERM "$pid"
  done
  sleep 1
}

main() {
  {
    print -r -- "=== $(date '+%F %T') stop ${VM_DIR:t} ==="
    stop_launcher_processes
    try_halt_guest || warn "guest halt over SSH skipped/failed"
    try_terminate_host_control || warn "host-control termination skipped/failed"

    wait_for_instance_stopped 15 || true
    kill_pid_file "$KEEPALIVE_PID_FILE"
    kill_pid_file "$BOOT_PID_FILE"
    stop_host_processes || warn "some host process(es) survived termination attempt"

    kill_listener_on_port "${SSH_LOCAL_PORT:-${VPHONE_SSH_PORT:-}}"
    kill_listener_on_port "${VNC_LOCAL_PORT:-${VPHONE_VNC_PORT:-}}"
    kill_listener_on_port "${RPC_LOCAL_PORT:-${VPHONE_RPC_PORT:-}}"

    if wait_for_instance_stopped 3; then
      rm -f "${VM_DIR}/vphone.sock" 2>/dev/null || true
      ok "stopped ${VM_DIR:t}"
    else
      warn "instance still has host process(es): $(instance_host_pids | tr '\n' ' ')"
      die "failed to stop ${VM_DIR:t}"
    fi
  } 2>&1 | tee -a "$STOP_LOG"
}

main "$@"
