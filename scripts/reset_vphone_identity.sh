#!/bin/zsh
# reset_vphone_identity.sh — reset host-side vphone ECID/UDID identity for a stopped VM.
#
# This clears config.plist:machineIdentifier and regenerates networkConfig.macAddress.
# On next boot, vphone-cli creates a fresh VZMacMachineIdentifier, which changes
# the predicted ECID/UDID, while the VM also gets a new stable virtual NIC MAC.
# Guest user data is intentionally left untouched.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

VM_DIR_INPUT=""
YES=0

usage() {
  cat <<USAGE
Usage:
  zsh scripts/reset_vphone_identity.sh <vm-dir> [--yes]

Example:
  zsh scripts/reset_vphone_identity.sh vm.instances/trollstore-clean-clone --yes

Effect:
  - requires the VM to be stopped
  - backs up config.plist
  - clears config.plist machineIdentifier
  - regenerates config.plist networkConfig.macAddress
  - removes stale host-side identity/connection files
  - does NOT modify Disk.img user data or SEPStorage
USAGE
}

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$VM_DIR_INPUT" ]] || die "only one <vm-dir> is supported"
      VM_DIR_INPUT="$1"
      shift
      ;;
  esac
done

[[ -n "$VM_DIR_INPUT" ]] || { usage >&2; exit 1; }
VM_DIR="${VM_DIR_INPUT:A}"
CONFIG="${VM_DIR}/config.plist"

[[ -d "$VM_DIR" ]] || die "VM dir not found: ${VM_DIR}"
[[ -f "$CONFIG" ]] || die "config.plist not found: ${CONFIG}"

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

if vm_is_running; then
  die "VM appears to be running. Stop/close this instance before changing machineIdentifier: ${VM_DIR}"
fi

if (( YES == 0 )); then
  print -r -- "将重置这个实例的 ECID/UDID 身份：" > /dev/tty
  print -r -- "  ${VM_DIR}" > /dev/tty
  print -r -- "会清空 machineIdentifier 并重新生成虚拟网卡 MAC；不会修改 Disk.img 用户数据，也不会重置 SEPStorage。" > /dev/tty
  printf "继续？输入 yes: " > /dev/tty
  answer=""
  IFS= read -r answer < /dev/tty || answer=""
  [[ "$answer" == "yes" ]] || die "cancelled"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${CONFIG}.bak.${STAMP}"
cp "$CONFIG" "$BACKUP"
ok "backup: ${BACKUP}"

/usr/bin/python3 - "$CONFIG" <<'PY'
from __future__ import annotations
import plistlib
import secrets
import sys
from pathlib import Path


def random_local_mac() -> str:
    return "02:" + ":".join(f"{b:02x}" for b in secrets.token_bytes(5))

path = Path(sys.argv[1])
with path.open("rb") as f:
    manifest = plistlib.load(f)
old_len = len(manifest.get("machineIdentifier", b"") or b"")
old_mac = (manifest.get("networkConfig", {}) or {}).get("macAddress", "")
manifest["machineIdentifier"] = b""
network = manifest.setdefault("networkConfig", {})
network["macAddress"] = random_local_mac()
with path.open("wb") as f:
    plistlib.dump(manifest, f, sort_keys=False)
print(f"cleared machineIdentifier; old_length={old_len}; old_mac={old_mac}; new_mac={network['macAddress']}")
PY

plutil -lint "$CONFIG" >/dev/null

rm -f \
  "${VM_DIR}/udid-prediction.txt" \
  "${VM_DIR}/connection_info.txt" \
  "${VM_DIR}/connect_ssh.command" \
  "${VM_DIR}/vphone.sock" \
  "${VM_DIR}/logs/boot.pid" \
  "${VM_DIR}/logs/boot.stdin" \
  "${VM_DIR}/logs/boot_stdin_keepalive.pid" 2>/dev/null || true

ok "identity reset staged"
print -r -- ""
print -r -- "下一步启动后会自动生成新的 ECID/UDID："
print -r -- "  zsh scripts/launch_vphone_instance.sh '${VM_DIR}'"
print -r -- "  cat '${VM_DIR}/udid-prediction.txt'"
