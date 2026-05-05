#!/bin/zsh
# finalize_vphone_instance.sh — write per-instance launch metadata after setup_machine completed.
#
# Useful if creation was interrupted after "Setup completed" but before the
# one-click wrapper wrote launch_gui.command / instance.env.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

VM_DIR_INPUT="${1:-}"
VARIANT_INPUT="${2:-}"
[[ -n "$VM_DIR_INPUT" ]] || { echo "Usage: $0 <vm-dir> [regular|dev|jb]" >&2; exit 1; }
VM_DIR="${VM_DIR_INPUT:A}"
[[ -f "${VM_DIR}/config.plist" ]] || { echo "[-] Missing config.plist: ${VM_DIR}/config.plist" >&2; exit 1; }
INSTANCE_NAME="${VM_DIR:t}"

if [[ -n "$VARIANT_INPUT" ]]; then
  VPHONE_VARIANT="$(vphone_variant_normalize "$VARIANT_INPUT")"
elif [[ -f "${VM_DIR}/.vphone_variant" ]]; then
  VPHONE_VARIANT="$(vphone_variant_normalize "$(< "${VM_DIR}/.vphone_variant")")"
else
  VPHONE_VARIANT="jb"
fi

NETWORK_MODE="$(/usr/bin/python3 - "${VM_DIR}/config.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('networkConfig', {}).get('mode', 'nat'))
PY
)"
NETWORK_INTERFACE="$(/usr/bin/python3 - "${VM_DIR}/config.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('networkConfig', {}).get('bridgedInterface', '') or '')
PY
)"

cat > "${VM_DIR}/launch_gui.command" <<LAUNCH
#!/bin/zsh
set -euo pipefail
cd "${PROJECT_ROOT}"
export VPHONE_LAUNCH_CLOSE_TERMINAL="\${VPHONE_LAUNCH_CLOSE_TERMINAL:-1}"
exec zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${VM_DIR}"
LAUNCH
chmod +x "${VM_DIR}/launch_gui.command"

cat > "${VM_DIR}/instance.env" <<ENV
INSTANCE_NAME="${INSTANCE_NAME}"
VM_DIR="${VM_DIR}"
SSH_LOCAL_PORT=""
VNC_LOCAL_PORT=""
RPC_LOCAL_PORT=""
VPHONE_VARIANT="${VPHONE_VARIANT}"
VPHONE_LANGUAGE="${VPHONE_LANGUAGE:-}"
VPHONE_LOCALE="${VPHONE_LOCALE:-}"
VPHONE_LANGUAGE_RESPRING="${VPHONE_LANGUAGE_RESPRING:-1}"
VPHONE_NETWORK_MODE="${NETWORK_MODE:-nat}"
VPHONE_NETWORK_INTERFACE="${NETWORK_INTERFACE:-}"
NETWORK_MODE="${NETWORK_MODE:-nat}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-}"
ENV
printf 'VPHONE_CYDIA_SOURCES=%q\n' "${VPHONE_CYDIA_SOURCES:-}" >> "${VM_DIR}/instance.env"
printf 'VPHONE_APT_SOURCES=%q\n' "${VPHONE_APT_SOURCES:-${VPHONE_CYDIA_SOURCES:-}}" >> "${VM_DIR}/instance.env"

print -r -- "$VPHONE_VARIANT" > "${VM_DIR}/.vphone_variant"
print -r -- "$INSTANCE_NAME" > "${VM_DIR}/.vm_name"
[[ -f "${VM_DIR}/.created_at" ]] || date '+%F %T' > "${VM_DIR}/.created_at"

cat > "${VM_DIR}/README_INSTANCE.txt" <<INFO
${INSTANCE_NAME}

Quick GUI connect:
  Double-click: ${VM_DIR}/launch_gui.command

CLI:
  zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${VM_DIR}"

After launch, current ports are written to:
  ${VM_DIR}/connection_info.txt
INFO

echo "[+] finalized instance metadata: ${VM_DIR}"
echo "    Double-click: ${VM_DIR}/launch_gui.command"
