#!/bin/zsh
# Shared guest/manifest configuration helpers for one-click vphone scripts.

vphone_gc_log() { print -r -- "[*] $*"; }
vphone_gc_ok() { print -r -- "[+] $*"; }
vphone_gc_warn() { print -r -- "[!] $*"; }

vphone_gc_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

vphone_gc_falsey() {
  case "${1:-}" in
    0|false|FALSE|no|NO|n|N) return 0 ;;
    *) return 1 ;;
  esac
}

vphone_source_config_preserving_env() {
  local config_path="$1"
  shift
  [[ -f "$config_path" ]] || return 0

  local -A had_value saved_value
  local name
  for name in "$@"; do
    if (( ${+parameters[$name]} )); then
      had_value[$name]=1
      saved_value[$name]="${(P)name}"
    fi
  done

  source "$config_path"

  for name in "$@"; do
    if [[ -n "${had_value[$name]:-}" ]]; then
      typeset -g "${name}=${saved_value[$name]}"
    fi
  done
}

vphone_prompt_enabled() {
  vphone_gc_falsey "${VPHONE_INTERACTIVE_CONFIG:-1}" && return 1
  vphone_gc_truthy "${NONE_INTERACTIVE:-0}" && return 1
  [[ -t 0 ]] || return 1
  [[ -r /dev/tty ]] || return 1
  return 0
}

vphone_prompt_read() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""

  if [[ -n "$default_value" ]]; then
    printf "%s [%s]: " "$label" "$default_value" > /dev/tty
  else
    printf "%s: " "$label" > /dev/tty
  fi
  IFS= read -r answer < /dev/tty || answer=""
  [[ -n "$answer" ]] || answer="$default_value"
  print -r -- "$answer"
}

vphone_prompt_secret() {
  local label="$1"
  local answer=""

  printf "%s: " "$label" > /dev/tty
  IFS= read -r -s answer < /dev/tty || answer=""
  printf "\n" > /dev/tty
  print -r -- "$answer"
}


vphone_run_with_timeout() {
  local timeout_seconds="${1:-5}"
  shift
  local max_ticks=$(( timeout_seconds * 5 ))
  local tick=0
  "$@" >/dev/null 2>&1 &
  local pid=$!
  while (( tick < max_ticks )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" >/dev/null 2>&1
      return $?
    fi
    sleep 0.2
    tick=$(( tick + 1 ))
  done
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.5
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" >/dev/null 2>&1 || true
  return 124
}

vphone_release_launchable() {
  local release_bin="$1"
  local timeout_seconds="${2:-${VPHONE_LAUNCH_CHECK_TIMEOUT:-4}}"
  [[ -x "$release_bin" ]] || return 1
  vphone_run_with_timeout "$timeout_seconds" "$release_bin" --help
}

vphone_setup_sudo_password() {
  local prompt="${1:-1}"

  if [[ -z "${SUDO_PASSWORD:-}" && -n "${VPHONE_SUDO_PASSWORD:-}" ]]; then
    SUDO_PASSWORD="$VPHONE_SUDO_PASSWORD"
  fi

  if [[ -z "${SUDO_PASSWORD:-}" ]] && vphone_gc_truthy "$prompt" && vphone_prompt_enabled; then
    print -r -- "" > /dev/tty
    print -r -- "=== macOS sudo 凭据 ===" > /dev/tty
    print -r -- "创建/刷机过程中 hdiutil、amfidont 等步骤需要管理员权限。" > /dev/tty
    print -r -- "这里输入一次即可；直接回车则保持系统 sudo 原始提示。" > /dev/tty
    SUDO_PASSWORD="$(vphone_prompt_secret "macOS 管理员密码（不会显示）")"
  fi

  [[ -n "${SUDO_PASSWORD:-}" ]] || return 0

  VPHONE_SUDO_PASSWORD="$SUDO_PASSWORD"
  export SUDO_PASSWORD VPHONE_SUDO_PASSWORD

  if [[ -z "${VPHONE_SUDO_ASKPASS_SCRIPT:-}" || ! -f "${VPHONE_SUDO_ASKPASS_SCRIPT:-}" ]]; then
    VPHONE_SUDO_ASKPASS_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/vphone-sudo-askpass.XXXXXX")"
    local password_literal
    printf -v password_literal '%q' "$SUDO_PASSWORD"
    cat > "$VPHONE_SUDO_ASKPASS_SCRIPT" <<EOF
#!/bin/sh
printf '%s\n' $password_literal
EOF
    chmod 700 "$VPHONE_SUDO_ASKPASS_SCRIPT"
  fi
  export SUDO_ASKPASS="$VPHONE_SUDO_ASKPASS_SCRIPT"

  if sudo -A -v >/dev/null 2>&1; then
    vphone_gc_ok "sudo credential cached for this run"
  else
    vphone_gc_warn "sudo credential validation failed; later sudo may still ask for password"
  fi
}

vphone_cleanup_sudo_password() {
  if [[ -n "${VPHONE_SUDO_ASKPASS_SCRIPT:-}" && -f "$VPHONE_SUDO_ASKPASS_SCRIPT" ]]; then
    rm -f "$VPHONE_SUDO_ASKPASS_SCRIPT" 2>/dev/null || true
  fi
  VPHONE_SUDO_ASKPASS_SCRIPT=""
}

vphone_host_ensure_amfidont() {
  local project_root="${1:-}"
  [[ -n "$project_root" ]] || project_root="$(pwd)"

  vphone_gc_truthy "${VPHONE_SKIP_AMFIDONT:-0}" && return 0

  local release_bin="${project_root}/.build/release/vphone-cli"
  if vphone_release_launchable "$release_bin"; then
    return 0
  fi

  local amfidont_bin
  amfidont_bin="$(command -v amfidont 2>/dev/null || true)"
  if [[ -z "$amfidont_bin" ]]; then
    vphone_gc_warn "signed vphone-cli is not launchable and amfidont is not on PATH"
    vphone_gc_warn "install it with: xcrun python3 -m pip install -U amfidont"
    return 1
  fi

  vphone_gc_warn "signed vphone-cli is not launchable yet; starting amfidont for ${project_root}"
  vphone_setup_sudo_password 1
  if [[ -x "${project_root}/scripts/start_amfidont_for_vphone.sh" ]]; then
    zsh "${project_root}/scripts/start_amfidont_for_vphone.sh" || return 1
  else
    local -a sudo_cmd
    sudo_cmd=(sudo)
    if [[ -n "${SUDO_ASKPASS:-}" ]]; then
      sudo_cmd=(sudo -A)
    fi
    "${sudo_cmd[@]}" "$amfidont_bin" daemon --path "$project_root" --spoof-apple || return 1
  fi

  if true; then
    sleep 1
    if vphone_release_launchable "$release_bin"; then
      vphone_gc_ok "amfidont active; signed vphone-cli can launch"
    else
      vphone_gc_warn "amfidont started, but signed vphone-cli still fails preflight"
      vphone_gc_warn "try manually: make amfidont_allow_vphone"
      return 1
    fi
  else
    vphone_gc_warn "failed to start amfidont; sudo may have failed"
    return 1
  fi
}

vphone_prompt_int() {
  local label="$1"
  local default_value="$2"
  local value

  while true; do
    value="$(vphone_prompt_read "$label" "$default_value")"
    value="${value//[[:space:]]/}"
    value="${value%,}"
    value="${value%，}"
    if [[ "$value" == <-> ]] && (( value > 0 )); then
      print -r -- "$value"
      return 0
    fi
    print -r -- "请输入正整数。" > /dev/tty
  done
}

vphone_default_cpu() {
  if [[ -n "${CPU:-}" && "$CPU" == <-> ]] && (( CPU > 0 )); then
    print -r -- "$CPU"
    return 0
  fi
  print -r -- "${VPHONE_DEFAULT_CPU:-4}"
}

vphone_default_memory_gb() {
  if [[ -n "${MEMORY_GB:-}" && "$MEMORY_GB" == <-> ]] && (( MEMORY_GB > 0 )); then
    print -r -- "$MEMORY_GB"
    return 0
  fi
  if [[ -n "${MEMORY:-}" && "$MEMORY" == <-> ]] && (( MEMORY > 0 )); then
    print -r -- $(( (MEMORY + 1023) / 1024 ))
    return 0
  fi
  print -r -- "${VPHONE_DEFAULT_MEMORY_GB:-4}"
}

vphone_prompt_memory_gb() {
  local memory_gb
  memory_gb="$(vphone_prompt_int "内存 GB" "$(vphone_default_memory_gb)")"
  MEMORY_GB="$memory_gb"
  MEMORY=$(( memory_gb * 1024 ))
}

vphone_default_disk_size() {
  if [[ -n "${DISK_SIZE:-}" && "$DISK_SIZE" == <-> ]] && (( DISK_SIZE > 0 )); then
    print -r -- "$DISK_SIZE"
    return 0
  fi
  print -r -- "${VPHONE_DEFAULT_DISK_SIZE:-32}"
}

vphone_prompt_optional_value() {
  local label="$1"
  local default_value="$2"
  local value
  value="$(vphone_prompt_read "$label" "$default_value")"
  case "${value:l}" in
    default|none|skip|no|0) print -r -- "" ;;
    *) print -r -- "$value" ;;
  esac
}

vphone_prompt_network_mode() {
  local default_value="$1"
  local value
  [[ -n "$default_value" ]] || default_value="nat"

  while true; do
    value="$(vphone_prompt_read "网络模式 nat/bridged/none" "$default_value")"
    case "${value:l}" in
      nat|n) print -r -- "nat"; return 0 ;;
      bridge|bridged|b) print -r -- "bridged"; return 0 ;;
      none|offline|off|0) print -r -- "none"; return 0 ;;
      *) print -r -- "请输入 nat、bridged 或 none。" > /dev/tty ;;
    esac
  done
}

vphone_variant_normalize() {
  local value="${1:-jb}"
  case "${value:l}" in
    1|regular|base|normal|常规|常规版) print -r -- "regular" ;;
    2|dev|development|developer|开发|开发版) print -r -- "dev" ;;
    3|jb|jailbreak|trollstore|越狱|越狱版) print -r -- "jb" ;;
    *) print -r -- "jb" ;;
  esac
}

vphone_variant_label() {
  case "$(vphone_variant_normalize "${1:-jb}")" in
    regular) print -r -- "常规版" ;;
    dev) print -r -- "开发版" ;;
    jb) print -r -- "越狱版 / TrollStore-JB" ;;
  esac
}

vphone_variant_choice_number() {
  case "$(vphone_variant_normalize "${1:-jb}")" in
    regular) print -r -- "1" ;;
    dev) print -r -- "2" ;;
    jb) print -r -- "3" ;;
  esac
}

vphone_variant_instance_prefix() {
  case "$(vphone_variant_normalize "${1:-jb}")" in
    regular) print -r -- "regular" ;;
    dev) print -r -- "dev" ;;
    jb) print -r -- "trollstore" ;;
  esac
}

vphone_variant_backup_name() {
  case "$(vphone_variant_normalize "${1:-jb}")" in
    regular) print -r -- "${VPHONE_REGULAR_BACKUP_NAME:-vphone-regular}" ;;
    dev) print -r -- "${VPHONE_DEV_BACKUP_NAME:-vphone-dev}" ;;
    jb) print -r -- "${VPHONE_JB_BACKUP_NAME:-trollstore-jb}" ;;
  esac
}

vphone_variant_setup_arg() {
  case "$(vphone_variant_normalize "${1:-jb}")" in
    regular) print -r -- "" ;;
    dev) print -r -- "--dev" ;;
    jb) print -r -- "--jb" ;;
  esac
}

vphone_prompt_variant() {
  local default_variant="${VPHONE_VARIANT:-jb}"
  local default_choice value
  default_choice="$(vphone_variant_choice_number "$default_variant")"

  print -r -- "固件版本：" > /dev/tty
  print -r -- "  1) 常规版" > /dev/tty
  print -r -- "  2) 开发版" > /dev/tty
  print -r -- "  3) 越狱版 / TrollStore-JB" > /dev/tty

  while true; do
    value="$(vphone_prompt_read "请选择 1/2/3" "$default_choice")"
    case "${value:l}" in
      1|regular|base|normal|常规|常规版)
        VPHONE_VARIANT="regular"
        return 0
        ;;
      2|dev|development|developer|开发|开发版)
        VPHONE_VARIANT="dev"
        return 0
        ;;
      3|jb|jailbreak|trollstore|越狱|越狱版)
        VPHONE_VARIANT="jb"
        return 0
        ;;
      *)
        print -r -- "请输入 1、2 或 3。" > /dev/tty
        ;;
    esac
  done
}

vphone_prompt_language_locale() {
  local language locale

  language="$(vphone_prompt_optional_value "系统语言，如 zh-Hans/en/ja；输入 default 跳过" "${VPHONE_LANGUAGE:-default}")"
  locale="$(vphone_prompt_optional_value "地区/区域，如 zh_CN/en_US/ja_JP；输入 default 跳过" "${VPHONE_LOCALE:-default}")"

  if [[ -n "$language" && -z "$locale" ]]; then
    locale="$(vphone_guest_infer_locale "$language")"
  elif [[ -z "$language" && -n "$locale" ]]; then
    language="$(vphone_guest_infer_language_from_locale "$locale")"
  fi

  if [[ -n "$language" && -n "$locale" ]] && ! vphone_guest_validate_language_locale "$language" "$locale"; then
    print -r -- "语言/地区格式不合法，本次跳过语言设置。" > /dev/tty
    language=""
    locale=""
  fi

  VPHONE_LANGUAGE="$language"
  VPHONE_LOCALE="$locale"
}

vphone_prompt_runtime_config() {
  local include_size="${1:-1}"
  local include_variant="${2:-0}"
  vphone_prompt_enabled || return 0

  print -r -- "" > /dev/tty
  print -r -- "=== vphone 启动配置 ===" > /dev/tty
  print -r -- "直接回车使用括号内默认值；语言输入 default/none 可跳过语言修改。" > /dev/tty

  if vphone_gc_truthy "$include_variant"; then
    vphone_prompt_variant
  fi

  if vphone_gc_truthy "$include_size"; then
    CPU="$(vphone_prompt_int "CPU 核心数" "$(vphone_default_cpu)")"
    vphone_prompt_memory_gb
    DISK_SIZE="$(vphone_prompt_int "硬盘 GB" "$(vphone_default_disk_size)")"
  fi

  vphone_prompt_language_locale

  local mode interface
  mode="$(vphone_prompt_network_mode "${NETWORK_MODE:-${VPHONE_NETWORK_MODE:-nat}}")"
  interface="${NETWORK_INTERFACE:-${VPHONE_NETWORK_INTERFACE:-}}"
  if [[ "$mode" == "bridged" ]]; then
    interface="$(vphone_prompt_read "桥接宿主机网卡 BSD 名称" "${interface:-en0}")"
  else
    interface=""
  fi

  NETWORK_MODE="$mode"
  VPHONE_NETWORK_MODE="$mode"
  NETWORK_INTERFACE="$interface"
  VPHONE_NETWORK_INTERFACE="$interface"

  print -r -- "=== 配置确认 ===" > /dev/tty
  if vphone_gc_truthy "$include_variant"; then
    print -r -- "VARIANT=$(vphone_variant_label "${VPHONE_VARIANT:-jb}")" > /dev/tty
  fi
  if vphone_gc_truthy "$include_size"; then
    print -r -- "CPU=${CPU} MEMORY=${MEMORY_GB:-$(( MEMORY / 1024 ))}GB (${MEMORY}MB) DISK_SIZE=${DISK_SIZE}GB" > /dev/tty
  else
    print -r -- "CPU/内存/硬盘：沿用已有 VM 配置" > /dev/tty
  fi
  print -r -- "LANGUAGE=${VPHONE_LANGUAGE:-default} LOCALE=${VPHONE_LOCALE:-default}" > /dev/tty
  print -r -- "NETWORK=${NETWORK_MODE}${NETWORK_INTERFACE:+ (${NETWORK_INTERFACE})}" > /dev/tty
  print -r -- "" > /dev/tty
}

vphone_export_runtime_config() {
  if [[ -z "${NETWORK_MODE:-}" && -n "${VPHONE_NETWORK_MODE:-}" ]]; then
    NETWORK_MODE="$VPHONE_NETWORK_MODE"
  fi
  if [[ -z "${NETWORK_INTERFACE:-}" && -n "${VPHONE_NETWORK_INTERFACE:-}" ]]; then
    NETWORK_INTERFACE="$VPHONE_NETWORK_INTERFACE"
  fi
  if [[ -z "${VPHONE_CYDIA_SOURCES:-}" && -n "${VPHONE_APT_SOURCES:-}" ]]; then
    VPHONE_CYDIA_SOURCES="$VPHONE_APT_SOURCES"
  fi
  if [[ -z "${VPHONE_APT_SOURCES:-}" && -n "${VPHONE_CYDIA_SOURCES:-}" ]]; then
    VPHONE_APT_SOURCES="$VPHONE_CYDIA_SOURCES"
  fi
  if [[ -z "${VPHONE_MAC_ADDRESS:-}" && -n "${MAC_ADDRESS:-}" ]]; then
    VPHONE_MAC_ADDRESS="$MAC_ADDRESS"
  fi
  VPHONE_VARIANT="$(vphone_variant_normalize "${VPHONE_VARIANT:-jb}")"
  if [[ -n "${MEMORY_GB:-}" && "$MEMORY_GB" == <-> ]] && (( MEMORY_GB > 0 )); then
    MEMORY=$(( MEMORY_GB * 1024 ))
  elif [[ -n "${MEMORY:-}" && "$MEMORY" == <-> ]] && (( MEMORY > 0 )); then
    MEMORY_GB=$(( (MEMORY + 1023) / 1024 ))
  fi

  [[ -n "${CPU:-}" ]] && export CPU
  [[ -n "${VPHONE_VARIANT:-}" ]] && export VPHONE_VARIANT
  [[ -n "${MEMORY_GB:-}" ]] && export MEMORY_GB
  [[ -n "${MEMORY:-}" ]] && export MEMORY
  [[ -n "${DISK_SIZE:-}" ]] && export DISK_SIZE
  [[ -n "${VPHONE_LANGUAGE:-}" ]] && export VPHONE_LANGUAGE
  [[ -n "${VPHONE_LOCALE:-}" ]] && export VPHONE_LOCALE
  [[ -n "${VPHONE_LANGUAGE_RESPRING:-}" ]] && export VPHONE_LANGUAGE_RESPRING
  [[ -n "${NETWORK_MODE:-}" ]] && export NETWORK_MODE VPHONE_NETWORK_MODE="$NETWORK_MODE"
  [[ -n "${NETWORK_INTERFACE:-}" ]] && export NETWORK_INTERFACE VPHONE_NETWORK_INTERFACE="$NETWORK_INTERFACE"
  [[ -n "${VPHONE_MAC_ADDRESS:-}" ]] && export VPHONE_MAC_ADDRESS
  [[ -n "${VPHONE_CYDIA_SOURCES:-}" ]] && export VPHONE_CYDIA_SOURCES VPHONE_APT_SOURCES="$VPHONE_CYDIA_SOURCES"
  return 0
}

vphone_guest_infer_language_from_locale() {
  local locale="${1:-}"
  case "$locale" in
    zh_CN|zh-Hans*|zh_*CN*) print -r -- "zh-Hans" ;;
    zh_TW|zh_HK|zh-Hant*|zh_*TW*|zh_*HK*) print -r -- "zh-Hant" ;;
    ja*|ja_JP) print -r -- "ja" ;;
    ko*|ko_KR) print -r -- "ko" ;;
    en*|en_US) print -r -- "en" ;;
    *) print -r -- "${locale%%[_-]*}" ;;
  esac
}

vphone_guest_infer_locale() {
  local language="${1:-}"
  case "$language" in
    zh-Hans|zh_CN|zh-Hans*) print -r -- "zh_CN" ;;
    zh-Hant|zh_TW|zh-Hant*) print -r -- "zh_TW" ;;
    ja|ja-*) print -r -- "ja_JP" ;;
    ko|ko-*) print -r -- "ko_KR" ;;
    en|en-*) print -r -- "en_US" ;;
    *) print -r -- "${language}_US" ;;
  esac
}

vphone_guest_validate_language_locale() {
  local language="$1"
  local locale="$2"
  [[ "$language" =~ '^[A-Za-z]{2,3}([-_][A-Za-z0-9]+)*$' ]] || {
    vphone_gc_warn "invalid VPHONE_LANGUAGE: ${language}"
    return 1
  }
  [[ "$locale" =~ '^[A-Za-z]{2,3}([-_][A-Za-z0-9]+)*$' ]] || {
    vphone_gc_warn "invalid VPHONE_LOCALE: ${locale}"
    return 1
  }
  return 0
}

vphone_guest_ssh() {
  local port="$1"
  shift
  local -a ssh_args
  ssh_args=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o PasswordAuthentication=yes
    -o PubkeyAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o ConnectionAttempts=1
    -o ConnectTimeout=5
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=1
    -o LogLevel=ERROR
    -q
    -p "$port"
    root@127.0.0.1
  )
  sshpass -p "${VPHONE_SSH_PASSWORD:-alpine}" ssh "${ssh_args[@]}" "$@"
}

vphone_guest_update_plist_file() {
  local plist_path="$1"
  local language="$2"
  local locale="$3"

  /usr/bin/python3 - "$plist_path" "$language" "$locale" <<'PY'
from __future__ import annotations

import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
language = sys.argv[2]
locale = sys.argv[3]

try:
    with path.open("rb") as f:
        prefs = plistlib.load(f)
    if not isinstance(prefs, dict):
        prefs = {}
except Exception:
    prefs = {}

languages = [language]
if language != "en":
    languages.append("en")

prefs["AppleLanguages"] = languages
prefs["AppleLocale"] = locale
prefs["AppleLanguagesDidMigrate"] = True

with path.open("wb") as f:
    plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)
PY
}

vphone_guest_upload_file() {
  local port="$1"
  local local_path="$2"
  local remote_path="$3"
  cat "$local_path" | vphone_guest_ssh "$port" "cat > '${remote_path}'"
}

vphone_guest_apply_language() {
  local port="$1"
  local vm_dir="$2"
  local language="${3:-}"
  local locale="${4:-}"
  local respring="${5:-1}"

  [[ -n "$language" || -n "$locale" ]] || return 0

  if ! command -v sshpass >/dev/null 2>&1; then
    vphone_gc_warn "sshpass not found; skip guest language configuration"
    return 1
  fi

  if [[ -z "$language" ]]; then
    language="$(vphone_guest_infer_language_from_locale "$locale")"
  fi
  if [[ -z "$locale" ]]; then
    locale="$(vphone_guest_infer_locale "$language")"
  fi
  vphone_guest_validate_language_locale "$language" "$locale" || return 1

  local signature="language=${language};locale=${locale}"
  local current_signature
  current_signature="$(vphone_guest_ssh "$port" "cat /var/mobile/.vphone_language_applied 2>/dev/null || true" 2>/dev/null || true)"
  if [[ "$current_signature" == "$signature" ]]; then
    vphone_gc_ok "guest language already applied: ${language}/${locale}"
    return 0
  fi

  vphone_gc_log "applying guest language: ${language}, locale: ${locale}"

  local tmpdir mobile_plist root_plist
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/vphone-language.XXXXXX")"
  mobile_plist="${tmpdir}/mobile.GlobalPreferences.plist"
  root_plist="${tmpdir}/root.GlobalPreferences.plist"

  vphone_guest_ssh "$port" "mkdir -p /var/mobile/Library/Preferences /var/root/Library/Preferences" >/dev/null || {
    vphone_gc_warn "failed to prepare guest preference directories"
    rm -rf "$tmpdir"
    return 1
  }

  vphone_guest_ssh "$port" "cat /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true" > "$mobile_plist" || true
  vphone_guest_ssh "$port" "cat /var/root/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true" > "$root_plist" || true

  vphone_guest_update_plist_file "$mobile_plist" "$language" "$locale"
  vphone_guest_update_plist_file "$root_plist" "$language" "$locale"

  vphone_guest_upload_file "$port" "$mobile_plist" "/var/mobile/Library/Preferences/.GlobalPreferences.plist" || {
    vphone_gc_warn "failed to upload mobile language preferences"
    rm -rf "$tmpdir"
    return 1
  }
  vphone_guest_upload_file "$port" "$root_plist" "/var/root/Library/Preferences/.GlobalPreferences.plist" || {
    vphone_gc_warn "failed to upload root language preferences"
    rm -rf "$tmpdir"
    return 1
  }

  vphone_guest_ssh "$port" "
    chown mobile:mobile /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true
    chmod 600 /var/mobile/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true
    chown root:wheel /var/root/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true
    chmod 600 /var/root/Library/Preferences/.GlobalPreferences.plist 2>/dev/null || true
    printf '%s' '${signature}' > /var/mobile/.vphone_language_applied
    chown mobile:mobile /var/mobile/.vphone_language_applied 2>/dev/null || true
    (/iosbinpack64/usr/bin/killall cfprefsd || /usr/bin/killall cfprefsd || true) >/dev/null 2>&1
  " >/dev/null || true

  if vphone_gc_truthy "$respring"; then
    vphone_guest_ssh "$port" "(/iosbinpack64/usr/bin/killall SpringBoard || /usr/bin/killall SpringBoard || true) >/dev/null 2>&1" >/dev/null || true
    vphone_gc_ok "guest language applied; SpringBoard restart requested"
  else
    vphone_gc_ok "guest language applied; reboot/respring later to fully refresh UI"
  fi

  mkdir -p "$vm_dir"
  print -r -- "$signature" > "${vm_dir}/.vphone_language_applied_host" 2>/dev/null || true
  rm -rf "$tmpdir"
}

vphone_vm_apply_network_config() {
  local config_path="$1"
  local mode="${2:-}"
  local interface="${3:-}"
  local mac_address="${4:-${VPHONE_MAC_ADDRESS:-${MAC_ADDRESS:-}}}"

  [[ -n "$mode" || -n "$interface" || -n "$mac_address" ]] || return 0
  [[ -n "$mode" ]] || mode="bridged"

  case "$mode" in
    nat|bridged|none|hostOnly) ;;
    *)
      vphone_gc_warn "unsupported network mode: ${mode} (expected nat, bridged, none)"
      return 1
      ;;
  esac

  /usr/bin/python3 - "$config_path" "$mode" "$interface" "$mac_address" <<'PY'
from __future__ import annotations

import plistlib
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
interface = sys.argv[3]
requested_mac = sys.argv[4]


def random_local_mac() -> str:
    return "02:" + ":".join(f"{b:02x}" for b in secrets.token_bytes(5))


def normalize_mac(value: str) -> str:
    text = (value or "").strip().lower().replace("-", ":")
    parts = text.split(":")
    if len(parts) != 6:
        raise ValueError(f"invalid MAC address: {value}")
    nums = []
    for part in parts:
        if len(part) != 2:
            raise ValueError(f"invalid MAC address: {value}")
        nums.append(int(part, 16))
    if nums[0] & 1:
        raise ValueError(f"multicast MAC is not valid for a VM: {value}")
    nums[0] |= 0x02
    nums[0] &= 0xFE
    return ":".join(f"{n:02x}" for n in nums)

with path.open("rb") as f:
    manifest = plistlib.load(f)

network = manifest.setdefault("networkConfig", {})
old_mode = network.get("mode")
old_interface = network.get("bridgedInterface", "")
old_mac = network.get("macAddress", "")

network["mode"] = mode
if requested_mac:
    network["macAddress"] = normalize_mac(requested_mac)
elif not network.get("macAddress"):
    network["macAddress"] = random_local_mac()
if interface:
    network["bridgedInterface"] = interface
elif mode != "bridged":
    network.pop("bridgedInterface", None)

changed = (
    old_mode != network.get("mode")
    or old_interface != network.get("bridgedInterface", "")
    or old_mac != network.get("macAddress", "")
)

with path.open("wb") as f:
    plistlib.dump(manifest, f)

if changed:
    suffix = f" ({network['bridgedInterface']})" if network.get("bridgedInterface") else ""
    print(f"[+] updated VM network config: {mode}{suffix}, mac={network.get('macAddress', '')}")
else:
    suffix = f" ({network['bridgedInterface']})" if network.get("bridgedInterface") else ""
    print(f"[*] VM network config already: {mode}{suffix}, mac={network.get('macAddress', '')}")
PY
}
