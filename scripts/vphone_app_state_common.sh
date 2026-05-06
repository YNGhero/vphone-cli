#!/bin/zsh
# Common host-side helpers for vphone per-app backup/new-device/restore scripts.

set -euo pipefail

VPA_COMMON_DIR="${0:A:h}"
# When sourced, ${0} is caller script under scripts/. Keep PROJECT_ROOT stable.
PROJECT_ROOT="${PROJECT_ROOT:-${VPA_COMMON_DIR:h}}"
export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

VPA_GUEST_SCRIPT="${PROJECT_ROOT}/scripts/vphone_app_state_guest.sh"
VPA_BACKUP_ROOT="${VPHONE_APP_BACKUP_ROOT:-${PROJECT_ROOT}/app_backups}"
VPA_SSH_PASSWORD="${VPHONE_SSH_PASSWORD:-alpine}"
VPA_HOST="${VPHONE_SSH_HOST:-127.0.0.1}"

vpa_say() { print -r -- "[*] $*"; }
vpa_ok() { print -r -- "[+] $*"; }
vpa_warn() { print -r -- "[!] $*"; }
vpa_die() { print -r -- "[-] $*" >&2; exit 1; }

vpa_require_tools() {
  command -v sshpass >/dev/null 2>&1 || vpa_die "sshpass not found; install with: brew install sshpass"
  command -v python3 >/dev/null 2>&1 || vpa_die "python3 not found"
  [[ -f "$VPA_GUEST_SCRIPT" ]] || vpa_die "missing guest helper: $VPA_GUEST_SCRIPT"
}

vpa_sanitize_name() {
  python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1].strip()
s = re.sub(r'[^A-Za-z0-9._-]+', '-', s)
s = s.strip('.-')
print(s or 'backup')
PY
}

vpa_validate_bundle_id() {
  local bundle="$1"
  [[ -n "$bundle" ]] || vpa_die "missing bundle id"
  [[ "$bundle" =~ "^[A-Za-z0-9._-]+$" ]] || vpa_die "invalid bundle id: $bundle"
}

vpa_quote_args() {
  python3 - "$@" <<'PY'
import shlex, sys
print(' '.join(shlex.quote(x) for x in sys.argv[1:]))
PY
}

vpa_ssh() {
  local port="$1"
  shift
  local -a opts
  opts=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o ConnectTimeout=8
    -p "$port"
    "root@${VPA_HOST}"
  )
  local remote_path='export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/var/jb/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/sbin:/usr/sbin:/iosbinpack64/sbin:/iosbinpack64/usr/sbin:$PATH; '
  if (( $# == 0 )); then
    sshpass -p "$VPA_SSH_PASSWORD" ssh "${opts[@]}"
  else
    sshpass -p "$VPA_SSH_PASSWORD" ssh "${opts[@]}" "${remote_path}$*"
  fi
}

vpa_run_guest() {
  local port="$1"
  shift
  local args
  args="$(vpa_quote_args "$@")"
  vpa_ssh "$port" "if [ -x /var/jb/usr/bin/bash ]; then /var/jb/usr/bin/bash -s -- ${args}; else /bin/bash -s -- ${args}; fi" < "$VPA_GUEST_SCRIPT"
}

vpa_prompt_confirm() {
  local prompt="$1"
  print -r -- "$prompt" > /dev/tty
  print -n -- "确认请输入 YES: " > /dev/tty
  local reply
  read -r reply < /dev/tty
  [[ "$reply" == "YES" ]] || vpa_die "cancelled"
}

vpa_default_stage() {
  local action="$1"
  local bundle="$2"
  local ts="$(date +%Y%m%d-%H%M%S)"
  local safe="$(vpa_sanitize_name "$bundle")"
  print -r -- "/var/mobile/Library/vphone_app_state/staging/${action}-${safe}-${ts}-$$"
}

vpa_instance_name_for_port() {
  local port="$1"
  if [[ -n "${VPHONE_INSTANCE_NAME:-}" ]]; then
    print -r -- "$VPHONE_INSTANCE_NAME"
    return 0
  fi
  local env p n
  for env in "${PROJECT_ROOT}"/vm.instances/*/instance.env(N); do
    p="$(
      (
        emulate -L zsh
        setopt no_unset
        source "$env"
        print -r -- "${SSH_LOCAL_PORT:-}"
      )
    )"
    if [[ "$p" == "$port" ]]; then
      n="$(
        (
          emulate -L zsh
          setopt no_unset
          source "$env"
          print -r -- "${INSTANCE_NAME:-${env:h:t}}"
        )
      )"
      print -r -- "${n:-${env:h:t}}"
      return 0
    fi
  done
  print -r -- "ssh-${port}"
}

vpa_read_env_value() {
  local env_file="$1"
  local key="$2"
  [[ -f "$env_file" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"/, "")
      gsub(/"$/, "")
      print
      exit
    }
  ' "$env_file" 2>/dev/null || true
}

vpa_resolve_vm_dir() {
  local target="$1"
  if [[ -d "$target" && -f "$target/config.plist" ]]; then
    print -r -- "${target:A}"
    return 0
  fi
  if [[ -f "${PROJECT_ROOT}/vm.instances/${target}/config.plist" ]]; then
    print -r -- "${PROJECT_ROOT}/vm.instances/${target}"
    return 0
  fi
  return 1
}

vpa_resolve_vm_dir_from_port() {
  local port="$1"
  local env_file value
  for env_file in "${PROJECT_ROOT}"/vm.instances/*/instance.env(N); do
    value="$(vpa_read_env_value "$env_file" SSH_LOCAL_PORT)"
    [[ -n "$value" ]] || value="$(vpa_read_env_value "$env_file" VPHONE_SSH_PORT)"
    if [[ "$value" == "$port" ]]; then
      print -r -- "${env_file:h}"
      return 0
    fi
  done
  return 1
}

vpa_resolve_ssh_port() {
  local target="$1"
  local vm_dir env_file port
  if [[ "$target" == <-> ]]; then
    print -r -- "$target"
    return 0
  fi
  vm_dir="$(vpa_resolve_vm_dir "$target")" || vpa_die "instance not found: $target"
  env_file="${vm_dir}/instance.env"
  port="$(vpa_read_env_value "$env_file" SSH_LOCAL_PORT)"
  [[ -n "$port" ]] || port="$(vpa_read_env_value "$env_file" VPHONE_SSH_PORT)"
  [[ -n "$port" ]] || vpa_die "SSH_LOCAL_PORT not found in ${env_file}; start the instance first"
  [[ "$port" == <-> ]] || vpa_die "invalid SSH port in ${env_file}: ${port}"
  print -r -- "$port"
}

vpa_parse_port_first() {
  local first="${1:-}"
  if [[ "$first" == <-> ]]; then
    print -r -- "$first"
  else
    print -r -- "${SSH_LOCAL_PORT:-2224}"
  fi
}
