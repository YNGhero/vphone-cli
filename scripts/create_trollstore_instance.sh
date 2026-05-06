#!/bin/zsh
# create_trollstore_instance.sh — create a brand-new independent TrollStore/JB vphone.
#
# Every run creates a new VM_DIR under vm.instances/<name>, then writes a
# per-instance launch_gui.command for quick future GUI/port connection.

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
    VPHONE_INTERACTIVE_CONFIG VPHONE_INSTANCE_NAME VPHONE_INSTANCES_DIR VPHONE_VARIANT \
    VPHONE_CREATE_COUNT VPHONE_AUTO_LAUNCH_CREATED \
    VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_MAC_ADDRESS MAC_ADDRESS \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD
fi

# Optional local sizing/port config for Finder double-click workflows.
# Copy vphone_instance.conf.example to vphone_instance.conf and edit it.
LOCAL_CONFIG="${PROJECT_ROOT}/vphone_instance.conf"
if [[ -f "$LOCAL_CONFIG" ]]; then
  vphone_source_config_preserving_env "$LOCAL_CONFIG" \
    CPU MEMORY MEMORY_GB DISK_SIZE \
    VPHONE_INTERACTIVE_CONFIG VPHONE_INSTANCE_NAME VPHONE_INSTANCES_DIR VPHONE_VARIANT \
    VPHONE_CREATE_COUNT VPHONE_AUTO_LAUNCH_CREATED \
    VPHONE_LANGUAGE VPHONE_LOCALE VPHONE_LANGUAGE_RESPRING \
    VPHONE_NETWORK_MODE VPHONE_NETWORK_INTERFACE NETWORK_MODE NETWORK_INTERFACE \
    VPHONE_MAC_ADDRESS MAC_ADDRESS \
    VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES \
    SUDO_PASSWORD VPHONE_SUDO_PASSWORD
fi

# Values loaded from vphone_instance.conf are shell variables, not exported by
# default. Export creation-time settings so the nested make/setup_machine flow
# receives them.
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
if [[ -z "${VPHONE_MAC_ADDRESS:-}" && -n "${MAC_ADDRESS:-}" ]]; then
  VPHONE_MAC_ADDRESS="$MAC_ADDRESS"
fi
[[ -n "${VPHONE_MAC_ADDRESS:-}" ]] && export VPHONE_MAC_ADDRESS
if [[ -z "${VPHONE_CYDIA_SOURCES:-}" && -n "${VPHONE_APT_SOURCES:-}" ]]; then
  VPHONE_CYDIA_SOURCES="$VPHONE_APT_SOURCES"
fi
[[ -n "${VPHONE_CYDIA_SOURCES:-}" ]] && export VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES="$VPHONE_CYDIA_SOURCES"

INSTANCES_DIR="${VPHONE_INSTANCES_DIR:-${PROJECT_ROOT}/vm.instances}"
CLI_INSTANCE_NAME="${1:-}"
REQUESTED_INSTANCE_NAME="${CLI_INSTANCE_NAME:-${VPHONE_INSTANCE_NAME:-}}"
CREATE_COUNT="${VPHONE_CREATE_COUNT:-1}"
BATCH_STAMP=""
INSTANCE_DIR=""
INSTANCE_NAME=""
CREATE_LOG=""
LOCK_DIR="${PROJECT_ROOT}/.multi_create_trollstore.lock"
PLANNED_INSTANCE_NAMES=()
PLANNED_INSTANCE_DIRS=()
CREATED_INSTANCE_DIRS=()
BATCH_LAUNCHER=""

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

cleanup_lock() {
  [[ -d "$LOCK_DIR" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true
}

cleanup() {
  cleanup_lock
  vphone_cleanup_sudo_password
}
trap cleanup EXIT INT TERM

ensure_single_creator() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "another TrollStore instance creation is already running. Booting existing instances can still be done with their launch_gui.command scripts."
  fi
}

normalize_create_count() {
  CREATE_COUNT="${CREATE_COUNT//[[:space:]]/}"
  CREATE_COUNT="${CREATE_COUNT%,}"
  CREATE_COUNT="${CREATE_COUNT%，}"
  [[ -n "$CREATE_COUNT" ]] || CREATE_COUNT=1
  [[ "$CREATE_COUNT" == <-> ]] && (( CREATE_COUNT > 0 )) \
    || die "VPHONE_CREATE_COUNT must be a positive integer, got: ${CREATE_COUNT}"
  VPHONE_CREATE_COUNT="$CREATE_COUNT"
  export VPHONE_CREATE_COUNT
}

prompt_create_count() {
  if vphone_prompt_enabled; then
    print -r -- "=== 批量创建 ===" > /dev/tty
    CREATE_COUNT="$(vphone_prompt_int "创建数量" "${VPHONE_CREATE_COUNT:-1}")"
    print -r -- "CREATE_COUNT=${CREATE_COUNT}" > /dev/tty
    print -r -- "" > /dev/tty
  fi
  normalize_create_count
}

prompt_instance_name() {
  vphone_prompt_enabled || return 0
  # Command-line instance name is explicit and should not be overwritten by the
  # Finder-style interactive prompt. Finder double-clicks have no argv, so they
  # can name a clean base VM here.
  [[ -z "$CLI_INSTANCE_NAME" ]] || return 0

  local value lower
  print -r -- "=== 实例命名 ===" > /dev/tty
  print -r -- "留空/输入 auto 使用自动名称；创建多个时这里会作为前缀并自动追加 -01/-02。" > /dev/tty
  while true; do
    value="$(vphone_prompt_read "实例名称/前缀" "${REQUESTED_INSTANCE_NAME:-auto}")"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    lower="${value:l}"
    case "$lower" in
      ""|auto|default|none|skip|no|0)
        REQUESTED_INSTANCE_NAME=""
        unset VPHONE_INSTANCE_NAME 2>/dev/null || true
        break
        ;;
    esac
    if [[ "$value" =~ '^[A-Za-z0-9_-]+$' ]]; then
      REQUESTED_INSTANCE_NAME="$value"
      VPHONE_INSTANCE_NAME="$value"
      export VPHONE_INSTANCE_NAME
      break
    fi
    print -r -- "实例名只能包含英文、数字、下划线和中划线：[A-Za-z0-9_-]" > /dev/tty
  done
  print -r -- "INSTANCE_NAME=${REQUESTED_INSTANCE_NAME:-auto}" > /dev/tty
  print -r -- "" > /dev/tty
}

normalize_requested_instance_name() {
  local value="${REQUESTED_INSTANCE_NAME:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "${value:l}" in
    ""|auto|default|none|skip|no|0)
      REQUESTED_INSTANCE_NAME=""
      ;;
    *)
      REQUESTED_INSTANCE_NAME="$value"
      ;;
  esac
}

computed_instance_name() {
  local index="$1"
  local count="$2"
  local prefix suffix

  VPHONE_VARIANT="$(vphone_variant_normalize "${VPHONE_VARIANT:-jb}")"
  if [[ -n "$REQUESTED_INSTANCE_NAME" ]]; then
    if (( count > 1 )); then
      suffix="$(printf "%02d" "$index")"
      print -r -- "${REQUESTED_INSTANCE_NAME}-${suffix}"
    else
      print -r -- "$REQUESTED_INSTANCE_NAME"
    fi
    return 0
  fi

  prefix="$(vphone_variant_instance_prefix "$VPHONE_VARIANT")"
  if (( count > 1 )); then
    suffix="$(printf "%02d" "$index")"
    print -r -- "${prefix}-${BATCH_STAMP}-${suffix}"
  else
    print -r -- "${prefix}-${BATCH_STAMP}"
  fi
}

validate_instance_name() {
  local name="$1"
  # Keep names safe for Makefile paths, shell scripts, and Finder .command files.
  if [[ ! "$name" =~ '^[A-Za-z0-9_-]+$' ]]; then
    die "Instance name must match [A-Za-z0-9_-]+, got: ${name}"
  fi
}

prepare_instance_plan() {
  local i name dir
  PLANNED_INSTANCE_NAMES=()
  PLANNED_INSTANCE_DIRS=()
  normalize_requested_instance_name
  mkdir -p "$INSTANCES_DIR"
  BATCH_STAMP="$(date '+%Y%m%d-%H%M%S')"

  for (( i = 1; i <= CREATE_COUNT; i++ )); do
    name="$(computed_instance_name "$i" "$CREATE_COUNT")"
    validate_instance_name "$name"
    dir="${INSTANCES_DIR}/${name}"
    [[ ! -e "$dir" ]] || die "instance already exists: ${dir}"
    PLANNED_INSTANCE_NAMES+=("$name")
    PLANNED_INSTANCE_DIRS+=("$dir")
  done
}

select_planned_instance() {
  local index="$1"
  INSTANCE_NAME="${PLANNED_INSTANCE_NAMES[$index]}"
  INSTANCE_DIR="${PLANNED_INSTANCE_DIRS[$index]}"
  CREATE_LOG="${INSTANCE_DIR}/create.log"
}

ensure_xcode_sdk() {
  say "checking Xcode/iPhoneOS SDK"
  local dev
  dev="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$dev" != "/Applications/Xcode.app/Contents/Developer" ]]; then
    warn "switching xcode-select to full Xcode; sudo may ask for your password"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  fi
  xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
    || die "iPhoneOS SDK not found. Install full Xcode, then rerun."
  ok "Xcode SDK available: $(xcrun --sdk iphoneos --show-sdk-path)"
}

ensure_amfidont() {
  if pgrep -f "amfidont.*--path ${PROJECT_ROOT}" >/dev/null 2>&1; then
    ok "amfidont already running"
    return
  fi

  if ! command -v amfidont >/dev/null 2>&1; then
    warn "installing amfidont"
    xcrun python3 -m pip install -U amfidont
  fi

  local amfidont_bin
  amfidont_bin="$(command -v amfidont 2>/dev/null || true)"
  [[ -n "$amfidont_bin" ]] || die "amfidont is still not on PATH after install"

  warn "starting amfidont; sudo may ask for your password"
  sudo "$amfidont_bin" daemon --path "$PROJECT_ROOT" --spoof-apple >/dev/null 2>&1
  ok "amfidont started"
}

can_skip_project_setup() {
  [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]] || return 1
  "${PROJECT_ROOT}/.venv/bin/python3" -c 'import pymobiledevice3, capstone, keystone, pyimg4' >/dev/null 2>&1 || return 1
  [[ -f "${PROJECT_ROOT}/.build/release/vphone-cli" ]] || return 1
  return 0
}

write_instance_launcher() {
  local launcher="${INSTANCE_DIR}/launch_gui.command"
  cat > "$launcher" <<LAUNCH
#!/bin/zsh
set -euo pipefail
cd "${PROJECT_ROOT}"
export VPHONE_LAUNCH_CLOSE_TERMINAL="\${VPHONE_LAUNCH_CLOSE_TERMINAL:-1}"
exec zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${INSTANCE_DIR}"
LAUNCH
  chmod +x "$launcher"

  cat > "${INSTANCE_DIR}/README_INSTANCE.txt" <<INFO
${INSTANCE_NAME}

Quick GUI connect:
  Double-click: ${launcher}

CLI:
  zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "${INSTANCE_DIR}"

After launch, current ports are written to:
  ${INSTANCE_DIR}/connection_info.txt
INFO
}

write_initial_instance_env() {
  cat > "${INSTANCE_DIR}/instance.env" <<ENV
INSTANCE_NAME="${INSTANCE_NAME}"
VM_DIR="${INSTANCE_DIR}"
SSH_LOCAL_PORT=""
VNC_LOCAL_PORT=""
RPC_LOCAL_PORT=""
VPHONE_VARIANT="${VPHONE_VARIANT:-jb}"
VPHONE_LANGUAGE="${VPHONE_LANGUAGE:-}"
VPHONE_LOCALE="${VPHONE_LOCALE:-}"
VPHONE_LANGUAGE_RESPRING="${VPHONE_LANGUAGE_RESPRING:-1}"
VPHONE_NETWORK_MODE="${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-nat}}"
VPHONE_NETWORK_INTERFACE="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"
NETWORK_MODE="${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-nat}}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"
ENV
  [[ -n "${VPHONE_MAC_ADDRESS:-}" ]] && printf 'VPHONE_MAC_ADDRESS=%q\n' "${VPHONE_MAC_ADDRESS}" >> "${INSTANCE_DIR}/instance.env"
  printf 'VPHONE_CYDIA_SOURCES=%q\n' "${VPHONE_CYDIA_SOURCES:-}" >> "${INSTANCE_DIR}/instance.env"
  printf 'VPHONE_APT_SOURCES=%q\n' "${VPHONE_APT_SOURCES:-${VPHONE_CYDIA_SOURCES:-}}" >> "${INSTANCE_DIR}/instance.env"
}

clear_fixed_mac_for_batch_create() {
  (( CREATE_COUNT > 1 )) || return 0
  [[ -n "${VPHONE_MAC_ADDRESS:-${MAC_ADDRESS:-}}" ]] || return 0
  warn "批量创建数量为 ${CREATE_COUNT}，已忽略固定 VPHONE_MAC_ADDRESS，避免多个实例使用相同 MAC。"
  unset VPHONE_MAC_ADDRESS MAC_ADDRESS
}

create_instance() {
  local index="${1:-1}"
  local total="${2:-1}"
  [[ ! -e "$INSTANCE_DIR" ]] || die "instance already exists: ${INSTANCE_DIR}"
  mkdir -p "$INSTANCE_DIR"

  if (( total > 1 )); then
    say "batch progress: ${index}/${total}"
  fi
  say "creating new $(vphone_variant_label "$VPHONE_VARIANT") instance: ${INSTANCE_NAME}"
  say "VM_DIR=${INSTANCE_DIR}"
  local memory_label="${MEMORY:-Makefile default}"
  if [[ -n "${MEMORY_GB:-}" ]]; then
    memory_label="${MEMORY_GB} GB (${MEMORY:-$(( MEMORY_GB * 1024 ))} MB)"
  elif [[ -n "${MEMORY:-}" && "$MEMORY" == <-> && "$MEMORY" -gt 0 ]]; then
    memory_label="$(( (MEMORY + 1023) / 1024 )) GB (${MEMORY} MB)"
  fi
  say "size: CPU=${CPU:-Makefile default}, MEMORY=${memory_label}, DISK_SIZE=${DISK_SIZE:-Makefile default} GB"
  say "network: ${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-nat}}${NETWORK_INTERFACE:+ (${NETWORK_INTERFACE})}"
  say "language: ${VPHONE_LANGUAGE:-default}, locale: ${VPHONE_LOCALE:-auto/default}"
  say "log=${CREATE_LOG}"

  local setup_args
  setup_args=()
  local variant_arg
  variant_arg="$(vphone_variant_setup_arg "$VPHONE_VARIANT")"
  [[ -n "$variant_arg" ]] && setup_args+=("$variant_arg")
  if can_skip_project_setup; then
    setup_args+=(--skip-project-setup)
  fi

  export BOOT_ANALYSIS_TIMEOUT="${BOOT_ANALYSIS_TIMEOUT:-600}"
  export BOOT_PROMPT_FALLBACK_TIMEOUT="${BOOT_PROMPT_FALLBACK_TIMEOUT:-120}"
  export RAMDISK_SSH_TIMEOUT="${RAMDISK_SSH_TIMEOUT:-120}"
  export SKIP_BOOT_ANALYSIS="${SKIP_BOOT_ANALYSIS:-1}"
  export NONE_INTERACTIVE=1
  export VM_DIR="$INSTANCE_DIR"

  set +e
  zsh "${PROJECT_ROOT}/scripts/setup_machine.sh" "${setup_args[@]}" 2>&1 | tee "$CREATE_LOG"
  local rc=${pipestatus[1]}
  set -e
  (( rc == 0 )) || die "setup_machine failed for ${INSTANCE_NAME}; see ${CREATE_LOG}"

  print -r -- "$VPHONE_VARIANT" > "${INSTANCE_DIR}/.vphone_variant"
  print -r -- "$INSTANCE_NAME" > "${INSTANCE_DIR}/.vm_name"
  date '+%F %T' > "${INSTANCE_DIR}/.created_at"
  write_instance_launcher
  write_initial_instance_env
  ok "created ${INSTANCE_NAME}"
}

write_batch_launcher() {
  (( ${#CREATED_INSTANCE_DIRS[@]} > 1 )) || return 0
  BATCH_LAUNCHER="${INSTANCES_DIR}/launch_batch_${BATCH_STAMP}.command"
  cat > "$BATCH_LAUNCHER" <<LAUNCH
#!/bin/zsh
set -euo pipefail
cd "${PROJECT_ROOT}"

print -r -- "[*] launching ${#CREATED_INSTANCE_DIRS[@]} vphone instances sequentially"
delay_seconds="\${VPHONE_BATCH_LAUNCH_DELAY_SECONDS:-3}"
LAUNCH

  local dir index total
  total="${#CREATED_INSTANCE_DIRS[@]}"
  index=0
  for dir in "${CREATED_INSTANCE_DIRS[@]}"; do
    index=$(( index + 1 ))
    printf 'zsh "%s/scripts/launch_vphone_instance.sh" "%s"\n' "$PROJECT_ROOT" "$dir" >> "$BATCH_LAUNCHER"
    if (( index < total )); then
      cat >> "$BATCH_LAUNCHER" <<'LAUNCH'
if [[ "$delay_seconds" == <-> && "$delay_seconds" -gt 0 ]]; then
  print -r -- "[*] cooldown ${delay_seconds}s before launching next instance"
  sleep "$delay_seconds"
fi
LAUNCH
    fi
  done
  chmod +x "$BATCH_LAUNCHER"
  ok "batch launcher written: ${BATCH_LAUNCHER}"
}

launch_created_instances() {
  if ! vphone_gc_truthy "${VPHONE_AUTO_LAUNCH_CREATED:-1}"; then
    say "auto launch disabled; use each launch_gui.command later"
    return 0
  fi

  local dir rc
  rc=0
  if (( ${#CREATED_INSTANCE_DIRS[@]} == 1 )); then
    say "launching new instance GUI"
  else
    say "launching ${#CREATED_INSTANCE_DIRS[@]} created instance GUIs sequentially"
  fi

  for dir in "${CREATED_INSTANCE_DIRS[@]}"; do
    if ! zsh "${PROJECT_ROOT}/scripts/launch_vphone_instance.sh" "$dir"; then
      warn "failed to launch GUI for ${dir}"
      rc=1
    fi
  done
  return "$rc"
}

main() {
  ensure_single_creator
  vphone_setup_sudo_password 1
  vphone_prompt_runtime_config 1 1
  prompt_instance_name
  prompt_create_count
  vphone_export_runtime_config
  clear_fixed_mac_for_batch_create
  prepare_instance_plan
  ensure_xcode_sdk
  ensure_amfidont
  local i
  for (( i = 1; i <= CREATE_COUNT; i++ )); do
    select_planned_instance "$i"
    create_instance "$i" "$CREATE_COUNT"
    CREATED_INSTANCE_DIRS+=("$INSTANCE_DIR")
  done
  write_batch_launcher

  launch_created_instances || true
}

main "$@"
