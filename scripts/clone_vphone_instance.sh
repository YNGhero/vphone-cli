#!/bin/zsh
# clone_vphone_instance.sh — clone a clean vphone VM and reset ECID/UDID identity.
#
# Intended workflow:
#   1. Prepare one clean/stopped TrollStore-JB base instance.
#   2. Clone it with this script.
#   3. Each clone gets machineIdentifier cleared; first boot creates a new ECID/UDID.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

# Priority: current shell environment > .env > vphone_instance.conf.
ENV_CONFIG="${PROJECT_ROOT}/.env"
if [[ -f "$ENV_CONFIG" ]]; then
  vphone_source_config_preserving_env "$ENV_CONFIG" \
    VPHONE_CLONE_SOURCE VPHONE_CLONE_COUNT VPHONE_CLONE_NAME VPHONE_INSTANCES_DIR \
    VPHONE_AUTO_LAUNCH_CLONED VPHONE_INTERACTIVE_CONFIG \
    VPHONE_VARIANT VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES
fi
LOCAL_CONFIG="${PROJECT_ROOT}/vphone_instance.conf"
if [[ -f "$LOCAL_CONFIG" ]]; then
  vphone_source_config_preserving_env "$LOCAL_CONFIG" \
    VPHONE_CLONE_SOURCE VPHONE_CLONE_COUNT VPHONE_CLONE_NAME VPHONE_INSTANCES_DIR \
    VPHONE_AUTO_LAUNCH_CLONED VPHONE_INTERACTIVE_CONFIG \
    VPHONE_VARIANT VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES
fi

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

INSTANCES_DIR="${VPHONE_INSTANCES_DIR:-${PROJECT_ROOT}/vm.instances}"
SOURCE_INPUT="${1:-${VPHONE_CLONE_SOURCE:-}}"
REQUESTED_NAME="${2:-${VPHONE_CLONE_NAME:-}}"
CLONE_COUNT="${VPHONE_CLONE_COUNT:-1}"
AUTO_LAUNCH="${VPHONE_AUTO_LAUNCH_CLONED:-1}"
LOCK_DIR="${PROJECT_ROOT}/.multi_clone_vphone.lock"
BATCH_STAMP=""
SOURCE_DIR=""
PLANNED_INSTANCE_NAMES=()
PLANNED_INSTANCE_DIRS=()
CLONED_INSTANCE_DIRS=()

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage:
  zsh scripts/clone_vphone_instance.sh <source-vm-dir> [new-name-or-prefix]

Examples:
  zsh scripts/clone_vphone_instance.sh vm.instances/trollstore-clean
  VPHONE_CLONE_COUNT=5 zsh scripts/clone_vphone_instance.sh vm.instances/trollstore-clean phone

Environment:
  VPHONE_CLONE_COUNT=3          Number of clones, default 1
  VPHONE_CLONE_NAME=phone       Target name/prefix
  VPHONE_AUTO_LAUNCH_CLONED=0   Do not auto-launch after cloning
  VPHONE_INSTANCES_DIR=...      Target base directory
USAGE
}

cleanup_lock() {
  [[ -d "$LOCK_DIR" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

ensure_single_cloner() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another clone operation is already running"
  fi
}

validate_instance_name() {
  local name="$1"
  [[ "$name" =~ '^[A-Za-z0-9_-]+$' ]] || die "Instance name must match [A-Za-z0-9_-]+, got: ${name}"
}

normalize_count() {
  CLONE_COUNT="${CLONE_COUNT//[[:space:]]/}"
  CLONE_COUNT="${CLONE_COUNT%,}"
  CLONE_COUNT="${CLONE_COUNT%，}"
  [[ -n "$CLONE_COUNT" ]] || CLONE_COUNT=1
  [[ "$CLONE_COUNT" == <-> ]] && (( CLONE_COUNT > 0 )) || die "VPHONE_CLONE_COUNT must be a positive integer, got: ${CLONE_COUNT}"
}

default_clone_source() {
  [[ -d "$INSTANCES_DIR" ]] || return 0
  find "$INSTANCES_DIR" -maxdepth 2 -name config.plist -print 2>/dev/null \
    | while IFS= read -r cfg; do stat -f '%m %N' "$cfg" 2>/dev/null; done \
    | sort -rn \
    | head -1 \
    | sed 's/^[0-9][0-9]* //' \
    | xargs -I{} dirname "{}" 2>/dev/null || true
}

prompt_clone_config() {
  vphone_prompt_enabled || return 0
  local default_source default_name
  default_source="$(default_clone_source)"
  [[ -n "$SOURCE_INPUT" ]] || SOURCE_INPUT="$default_source"
  default_name="${REQUESTED_NAME:-}"

  print -r -- "" > /dev/tty
  print -r -- "=== vphone 克隆配置 ===" > /dev/tty
  print -r -- "来源实例必须已经关机；脚本会给克隆体生成新的 ECID/UDID。" > /dev/tty
  SOURCE_INPUT="$(vphone_prompt_read "复制来源实例目录" "$SOURCE_INPUT")"
  CLONE_COUNT="$(vphone_prompt_int "克隆数量" "$CLONE_COUNT")"
  REQUESTED_NAME="$(vphone_prompt_read "新实例名/前缀，留空自动" "$default_name")"
  print -r -- "" > /dev/tty
}

resolve_source() {
  [[ -n "$SOURCE_INPUT" ]] || { usage >&2; die "missing source VM dir"; }
  SOURCE_DIR="${SOURCE_INPUT:A}"
  [[ -d "$SOURCE_DIR" ]] || die "source VM dir not found: ${SOURCE_DIR}"
  [[ -f "${SOURCE_DIR}/config.plist" ]] || die "source config.plist not found: ${SOURCE_DIR}/config.plist"
  [[ -f "${SOURCE_DIR}/Disk.img" ]] || die "source Disk.img not found: ${SOURCE_DIR}/Disk.img"
  [[ -f "${SOURCE_DIR}/SEPStorage" ]] || die "source SEPStorage not found: ${SOURCE_DIR}/SEPStorage"

  if [[ -z "${VPHONE_VARIANT:-}" && -f "${SOURCE_DIR}/.vphone_variant" ]]; then
    VPHONE_VARIANT="$(< "${SOURCE_DIR}/.vphone_variant")"
  fi
  VPHONE_VARIANT="$(vphone_variant_normalize "${VPHONE_VARIANT:-jb}")"
}

source_is_running() {
  local path
  for path in \
    "${SOURCE_DIR}/Disk.img" \
    "${SOURCE_DIR}/SEPStorage" \
    "${SOURCE_DIR}/nvram.bin" \
    "${SOURCE_DIR}/vphone.sock"; do
    [[ -e "$path" ]] || continue
    if lsof -t -- "$path" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

computed_instance_name() {
  local index="$1"
  local count="$2"
  local prefix suffix

  if [[ -n "$REQUESTED_NAME" ]]; then
    if (( count > 1 )); then
      suffix="$(printf "%02d" "$index")"
      print -r -- "${REQUESTED_NAME}-${suffix}"
    else
      print -r -- "$REQUESTED_NAME"
    fi
    return 0
  fi

  # Keep the default clone name short.  macOS AF_UNIX socket paths are limited
  # to ~103 bytes, and vphone creates <vm-dir>/vphone.sock for host control.
  prefix="$(vphone_variant_instance_prefix "${VPHONE_VARIANT:-jb}")-clone-${BATCH_STAMP}"
  if (( count > 1 )); then
    suffix="$(printf "%02d" "$index")"
    print -r -- "${prefix}-${suffix}"
  else
    print -r -- "$prefix"
  fi
}

warn_if_socket_path_too_long() {
  local target_dir="$1"
  local socket_path="${target_dir}/vphone.sock"
  local socket_len
  socket_len="$(/usr/bin/python3 - "$socket_path" <<'PY'
import sys
print(len(sys.argv[1].encode()) + 1)
PY
)"
  if [[ "$socket_len" == <-> ]] && (( socket_len > 103 )); then
    warn "target path is long; host-control socket may be disabled (${socket_len} bytes): ${socket_path}"
    warn "SSH/VNC/RPC forwarding can still work; use a shorter clone name if you need vphone.sock"
  fi
}

prepare_plan() {
  local i name dir
  mkdir -p "$INSTANCES_DIR"
  BATCH_STAMP="$(date '+%Y%m%d-%H%M%S')"
  PLANNED_INSTANCE_NAMES=()
  PLANNED_INSTANCE_DIRS=()

  for (( i = 1; i <= CLONE_COUNT; i++ )); do
    name="$(computed_instance_name "$i" "$CLONE_COUNT")"
    validate_instance_name "$name"
    dir="${INSTANCES_DIR}/${name}"
    [[ ! -e "$dir" ]] || die "target instance already exists: ${dir}"
    warn_if_socket_path_too_long "$dir"
    PLANNED_INSTANCE_NAMES+=("$name")
    PLANNED_INSTANCE_DIRS+=("$dir")
  done
}

copy_file_fast() {
  local src="$1"
  local dst="$2"
  mkdir -p "${dst:h}"
  rm -f "$dst"

  # APFS clonefile is fastest and avoids duplicating a clean base immediately.
  if cp -c "$src" "$dst" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback preserves sparse Disk.img reasonably well.
  if command -v rsync >/dev/null 2>&1; then
    rsync -aS "$src" "$dst"
    return 0
  fi
  cp -p "$src" "$dst"
}

reset_target_machine_identifier() {
  local target_dir="$1"
  /usr/bin/python3 - "${target_dir}/config.plist" <<'PY'
from __future__ import annotations
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as f:
    manifest = plistlib.load(f)
manifest["machineIdentifier"] = b""
with path.open("wb") as f:
    plistlib.dump(manifest, f, sort_keys=False)
PY
  plutil -lint "${target_dir}/config.plist" >/dev/null
}

write_instance_launcher() {
  local target_dir="$1"
  local name="$2"
  local launcher="${target_dir}/launch_gui.command"
  cat > "$launcher" <<LAUNCH
#!/bin/zsh
set -euo pipefail
cd "${PROJECT_ROOT}"
export VPHONE_LAUNCH_CLOSE_TERMINAL="\${VPHONE_LAUNCH_CLOSE_TERMINAL:-1}"
exec zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${target_dir}"
LAUNCH
  chmod +x "$launcher"

  cat > "${target_dir}/README_INSTANCE.txt" <<INFO
${name}

Cloned from:
  ${SOURCE_DIR}

Quick GUI connect:
  Double-click: ${launcher}

CLI:
  zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${target_dir}"

After first launch, new ECID/UDID are written to:
  ${target_dir}/udid-prediction.txt
INFO
}

write_initial_instance_env() {
  local target_dir="$1"
  local name="$2"
  local source_network_mode source_network_interface
  source_network_mode="${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-}}"
  source_network_interface="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"

  if [[ -z "$source_network_mode" ]]; then
    source_network_mode="$(/usr/bin/python3 - "${target_dir}/config.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
print(d.get('networkConfig', {}).get('mode', 'nat'))
PY
)"
  fi

  cat > "${target_dir}/instance.env" <<ENV
INSTANCE_NAME="${name}"
VM_DIR="${target_dir}"
SSH_LOCAL_PORT=""
VNC_LOCAL_PORT=""
RPC_LOCAL_PORT=""
VPHONE_VARIANT="${VPHONE_VARIANT:-jb}"
VPHONE_LANGUAGE="${VPHONE_LANGUAGE:-}"
VPHONE_LOCALE="${VPHONE_LOCALE:-}"
VPHONE_LANGUAGE_RESPRING="${VPHONE_LANGUAGE_RESPRING:-1}"
VPHONE_NETWORK_MODE="${source_network_mode:-nat}"
VPHONE_NETWORK_INTERFACE="${source_network_interface:-}"
NETWORK_MODE="${source_network_mode:-nat}"
NETWORK_INTERFACE="${source_network_interface:-}"
ENV
  printf 'VPHONE_CYDIA_SOURCES=%q\n' "${VPHONE_CYDIA_SOURCES:-}" >> "${target_dir}/instance.env"
  printf 'VPHONE_APT_SOURCES=%q\n' "${VPHONE_APT_SOURCES:-${VPHONE_CYDIA_SOURCES:-}}" >> "${target_dir}/instance.env"
}

clone_one() {
  local index="$1"
  local total="$2"
  local name="$3"
  local target_dir="$4"
  local file

  if (( total > 1 )); then
    say "clone progress: ${index}/${total}"
  fi
  say "cloning ${SOURCE_DIR:t} -> ${name}"
  mkdir -p "$target_dir"

  for file in \
    config.plist \
    Disk.img \
    SEPStorage \
    nvram.bin \
    AVPBooter.vresearch1.bin \
    AVPSEPBooter.vresearch1.bin \
    .vphone_variant; do
    [[ -e "${SOURCE_DIR}/${file}" ]] || continue
    copy_file_fast "${SOURCE_DIR}/${file}" "${target_dir}/${file}"
  done

  reset_target_machine_identifier "$target_dir"
  rm -f \
    "${target_dir}/udid-prediction.txt" \
    "${target_dir}/connection_info.txt" \
    "${target_dir}/connect_ssh.command" \
    "${target_dir}/vphone.sock" 2>/dev/null || true
  rm -rf "${target_dir}/logs" 2>/dev/null || true

  print -r -- "$VPHONE_VARIANT" > "${target_dir}/.vphone_variant"
  print -r -- "$name" > "${target_dir}/.vm_name"
  date '+%F %T' > "${target_dir}/.created_at"
  {
    print -r -- "source=${SOURCE_DIR}"
    print -r -- "cloned_at=$(date '+%F %T')"
    print -r -- "machineIdentifier=cleared; regenerated on first boot"
  } > "${target_dir}/.cloned_from"

  write_instance_launcher "$target_dir" "$name"
  write_initial_instance_env "$target_dir" "$name"
  ok "cloned: ${target_dir}"
}

launch_cloned_instances() {
  vphone_gc_truthy "$AUTO_LAUNCH" || {
    say "auto launch disabled; use each launch_gui.command later"
    return 0
  }

  local dir
  for dir in "${CLONED_INSTANCE_DIRS[@]}"; do
    zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "$dir" || warn "failed to launch ${dir}"
  done
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  ensure_single_cloner
  prompt_clone_config
  normalize_count
  resolve_source
  if source_is_running; then
    die "source VM appears to be running. Shut it down before cloning: ${SOURCE_DIR}"
  fi
  prepare_plan

  print -r -- "=== 克隆确认 ==="
  print -r -- "SOURCE=${SOURCE_DIR}"
  print -r -- "COUNT=${CLONE_COUNT}"
  print -r -- "TARGETS:"
  local i
  for (( i = 1; i <= CLONE_COUNT; i++ )); do
    print -r -- "  - ${PLANNED_INSTANCE_DIRS[$i]}"
  done
  print -r -- ""

  for (( i = 1; i <= CLONE_COUNT; i++ )); do
    clone_one "$i" "$CLONE_COUNT" "${PLANNED_INSTANCE_NAMES[$i]}" "${PLANNED_INSTANCE_DIRS[$i]}"
    CLONED_INSTANCE_DIRS+=("${PLANNED_INSTANCE_DIRS[$i]}")
  done

  launch_cloned_instances
}

main "$@"
