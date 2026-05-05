#!/bin/zsh
# install_ipa_to_instance.sh — install an IPA/TIPA into a vphone instance.
#
# Usage:
#   zsh scripts/install_ipa_to_instance.sh /path/app.ipa vm.instances/name
#   zsh scripts/install_ipa_to_instance.sh vm.instances/name /path/app.ipa
#
# If the VM is running and <vm-dir>/vphone.sock is reachable, installation is
# sent to the existing GUI process. If the VM is stopped, the script boots it
# with vphone-cli --install-ipa and the install runs after vphoned connects.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

IPA_INPUT=""
VM_INPUT=""

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  zsh scripts/install_ipa_to_instance.sh <ipa-or-tipa-path> <vm-dir>
  zsh scripts/install_ipa_to_instance.sh <vm-dir> <ipa-or-tipa-path>

Examples:
  zsh scripts/install_ipa_to_instance.sh ~/Downloads/App.ipa vm.instances/phone-01
  zsh scripts/install_ipa_to_instance.sh vm.instances/phone-01 ~/Downloads/App.tipa
USAGE
}

looks_like_ipa() {
  local path="${1:l}"
  [[ "$path" == *.ipa || "$path" == *.tipa ]]
}

latest_instance_dir() {
  [[ -d "${PROJECT_ROOT}/vm.instances" ]] || return 0
  find "${PROJECT_ROOT}/vm.instances" -maxdepth 2 -name config.plist -print 2>/dev/null \
    | while IFS= read -r cfg; do stat -f '%m %N' "$cfg" 2>/dev/null; done \
    | sort -rn \
    | head -1 \
    | sed 's/^[0-9][0-9]* //' \
    | xargs -I{} dirname "{}" 2>/dev/null || true
}

parse_args_or_prompt() {
  case "$#" in
    0)
      if vphone_prompt_enabled; then
        print -r -- "" > /dev/tty
        print -r -- "=== 安装 IPA/TIPA 到 vphone 实例 ===" > /dev/tty
        IPA_INPUT="$(vphone_prompt_read "IPA/TIPA 文件路径" "${VPHONE_INSTALL_IPA:-}")"
        VM_INPUT="$(vphone_prompt_read "目标实例目录" "$(latest_instance_dir)")"
      else
        usage >&2
        exit 1
      fi
      ;;
    1)
      if looks_like_ipa "$1"; then
        IPA_INPUT="$1"
        if vphone_prompt_enabled; then
          VM_INPUT="$(vphone_prompt_read "目标实例目录" "$(latest_instance_dir)")"
        else
          usage >&2
          exit 1
        fi
      else
        VM_INPUT="$1"
        if vphone_prompt_enabled; then
          IPA_INPUT="$(vphone_prompt_read "IPA/TIPA 文件路径" "${VPHONE_INSTALL_IPA:-}")"
        else
          usage >&2
          exit 1
        fi
      fi
      ;;
    *)
      if looks_like_ipa "$1"; then
        IPA_INPUT="$1"
        VM_INPUT="$2"
      elif looks_like_ipa "$2"; then
        VM_INPUT="$1"
        IPA_INPUT="$2"
      else
        IPA_INPUT="$1"
        VM_INPUT="$2"
      fi
      ;;
  esac
}

path_len_with_nul() {
  /usr/bin/python3 - "$1" <<'PY'
import sys
print(len(sys.argv[1].encode()) + 1)
PY
}

socket_install() {
  local socket_path="$1"
  local ipa_path="$2"
  /usr/bin/python3 - "$socket_path" "$ipa_path" <<'PY'
from __future__ import annotations
import json
import socket
import sys

socket_path = sys.argv[1]
ipa_path = sys.argv[2]

req = {"t": "install_ipa", "path": ipa_path, "screen": False}
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3600)
s.connect(socket_path)
s.sendall(json.dumps(req).encode("utf-8") + b"\n")

buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk

if not buf:
    print("no response from vphone host-control socket", file=sys.stderr)
    sys.exit(2)

line = buf.split(b"\n", 1)[0]
try:
    resp = json.loads(line.decode("utf-8"))
except Exception as e:
    print(f"invalid response: {e}: {line!r}", file=sys.stderr)
    sys.exit(2)

if not resp.get("ok"):
    print(resp.get("error") or resp, file=sys.stderr)
    sys.exit(1)

print(resp.get("msg") or resp.get("path") or "installed")
PY
}

vm_is_running() {
  local path
  for path in \
    "${VM_DIR}/Disk.img" \
    "${VM_DIR}/SEPStorage" \
    "${VM_DIR}/nvram.bin" \
    "${VM_DIR}/vphone.sock"; do
    [[ -e "$path" ]] || continue
    if lsof -t -- "$path" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  parse_args_or_prompt "$@"

  [[ -n "$IPA_INPUT" ]] || die "missing IPA/TIPA path"
  [[ -n "$VM_INPUT" ]] || die "missing target VM dir"

  IPA_PATH="${IPA_INPUT:A}"
  VM_DIR="${VM_INPUT:A}"
  SOCKET_PATH="${VM_DIR}/vphone.sock"

  [[ -f "$IPA_PATH" ]] || die "IPA/TIPA not found: ${IPA_PATH}"
  looks_like_ipa "$IPA_PATH" || die "unsupported file extension; expected .ipa or .tipa: ${IPA_PATH}"
  [[ -f "${VM_DIR}/config.plist" ]] || die "target VM config not found: ${VM_DIR}/config.plist"

  say "IPA/TIPA=${IPA_PATH}"
  say "VM_DIR=${VM_DIR}"

  local socket_len
  socket_len="$(path_len_with_nul "$SOCKET_PATH")"

  if [[ "$socket_len" == <-> ]] && (( socket_len <= 103 )) && [[ -S "$SOCKET_PATH" ]]; then
    say "installing through running vphone GUI host-control socket"
    socket_install "$SOCKET_PATH" "$IPA_PATH"
    ok "install request completed"
    return 0
  fi

  if vm_is_running; then
    if [[ "$socket_len" == <-> ]] && (( socket_len > 103 )); then
      die "VM is running, but vphone.sock path is too long (${socket_len} bytes). GUI can work, but host-control install cannot. Use a shorter instance directory name, or shut down the VM and rerun this script so it can boot with --install-ipa."
    fi
    die "VM is running but host-control socket is not ready: ${SOCKET_PATH}. Wait until GUI/control socket is ready, or restart the instance and rerun."
  fi

  say "VM is stopped; booting GUI with one-shot --install-ipa"
  VPHONE_INSTALL_IPA="$IPA_PATH" zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "$VM_DIR"
  ok "boot/install request sent"
  print -r -- "Monitor install log:"
  print -r -- "  tail -f '${VM_DIR}/logs/boot.log'"
}

main "$@"
