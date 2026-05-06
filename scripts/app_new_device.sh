#!/bin/zsh
# app_new_device.sh — reset one app to a fresh/new-device state in a running vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/app_new_device.sh [实例名|VM目录|SSH端口] <bundle-id> [options]

Options:
  --yes              Do not ask for destructive confirmation
  --backup-before    Create a backup before cleaning
  --no-pasteboard    Do not clear guest pasteboard cache
  --no-relaunch      Do not attempt to relaunch app after reset
  --respring         Restart SpringBoard after reset

Examples:
  zsh scripts/app_new_device.sh instagram-01 com.example.app --backup-before --yes
  zsh scripts/app_new_device.sh vm.instances/instagram-01 com.example.app --yes
  zsh scripts/app_new_device.sh 2224 com.example.app --backup-before --yes
  zsh scripts/app_new_device.sh com.example.app --yes
USAGE
}

SSH_PORT="${SSH_LOCAL_PORT:-2224}"
BUNDLE_ID=""
ASSUME_YES=0
BACKUP_BEFORE=0
CLEAN_PASTEBOARD=1
RELAUNCH=1
RESPRING=0

args=("$@")
if (( ${#args[@]} > 0 )); then
  if [[ "${args[1]}" == <-> ]]; then
    SSH_PORT="${args[1]}"
    args=("${args[@]:1}")
  elif vpa_resolve_vm_dir "${args[1]}" >/dev/null 2>&1; then
    SSH_PORT="$(vpa_resolve_ssh_port "${args[1]}")"
    args=("${args[@]:1}")
  fi
fi

while (( ${#args[@]} > 0 )); do
  case "${args[1]}" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --backup-before) BACKUP_BEFORE=1 ;;
    --no-pasteboard) CLEAN_PASTEBOARD=0 ;;
    --no-relaunch) RELAUNCH=0 ;;
    --respring) RESPRING=1 ;;
    --*) vpa_die "unknown option: ${args[1]}" ;;
    *)
      if [[ -z "$BUNDLE_ID" ]]; then BUNDLE_ID="${args[1]}"; else vpa_die "unexpected argument: ${args[1]}"; fi ;;
  esac
  args=("${args[@]:1}")
done

[[ "$SSH_PORT" == <-> ]] || vpa_die "SSH_PORT must be numeric: $SSH_PORT"
vpa_validate_bundle_id "$BUNDLE_ID"
vpa_require_tools

if [[ "$ASSUME_YES" != "1" ]]; then
  vpa_prompt_confirm "即将对 ${BUNDLE_ID} 执行一键新机：清空 App 数据、App Group、Preferences，并清理该 App keychain。"
fi

if [[ "$BACKUP_BEFORE" == "1" ]]; then
  vpa_say "backup-before enabled"
  zsh "${PROJECT_ROOT}/scripts/app_backup.sh" "$SSH_PORT" "$BUNDLE_ID" "before-new-device"
fi

STAGE="$(vpa_default_stage new "$BUNDLE_ID")"
vpa_say "new-device app: ${BUNDLE_ID} via SSH localhost:${SSH_PORT}"
vpa_run_guest "$SSH_PORT" new "$BUNDLE_ID" "$STAGE" "$CLEAN_PASTEBOARD" "$RELAUNCH" "$RESPRING"

if [[ "${VPHONE_APP_KEEP_STAGE:-0}" != "1" ]]; then
  qstage="$(vpa_quote_args "$STAGE")"
  vpa_ssh "$SSH_PORT" "rm -rf ${qstage}" >/dev/null 2>&1 || true
fi
vpa_ok "new-device complete: ${BUNDLE_ID}"
