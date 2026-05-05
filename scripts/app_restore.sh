#!/bin/zsh
# app_restore.sh — restore one app backup into a running vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/app_restore.sh [SSH_PORT] <bundle-id> <backup.tar.gz> [options]

Options:
  --yes          Do not ask for destructive confirmation
  --no-relaunch  Do not attempt to relaunch app after restore
  --respring     Restart SpringBoard after restore

Examples:
  zsh scripts/app_restore.sh 2224 com.example.app app_backups/com.example.app/20260506-120000-manual.tar.gz --yes
USAGE
}

SSH_PORT="${SSH_LOCAL_PORT:-2224}"
BUNDLE_ID=""
ARCHIVE=""
ASSUME_YES=0
RELAUNCH=1
RESPRING=0

args=("$@")
if (( ${#args[@]} > 0 )) && [[ "${args[1]}" == <-> ]]; then
  SSH_PORT="${args[1]}"
  args=("${args[@]:1}")
fi

while (( ${#args[@]} > 0 )); do
  case "${args[1]}" in
    -h|--help) usage; exit 0 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --no-relaunch) RELAUNCH=0 ;;
    --respring) RESPRING=1 ;;
    --*) vpa_die "unknown option: ${args[1]}" ;;
    *)
      if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID="${args[1]}"
      elif [[ -z "$ARCHIVE" ]]; then
        ARCHIVE="${args[1]}"
      else
        vpa_die "unexpected argument: ${args[1]}"
      fi ;;
  esac
  args=("${args[@]:1}")
done

[[ "$SSH_PORT" == <-> ]] || vpa_die "SSH_PORT must be numeric: $SSH_PORT"
vpa_validate_bundle_id "$BUNDLE_ID"
[[ -n "$ARCHIVE" ]] || vpa_die "missing backup archive"
ARCHIVE="${ARCHIVE:A}"
[[ -f "$ARCHIVE" ]] || vpa_die "backup archive not found: $ARCHIVE"
vpa_require_tools

if [[ "$ASSUME_YES" != "1" ]]; then
  vpa_prompt_confirm "即将用备份还原 ${BUNDLE_ID}：当前 App 数据、App Group、Preferences、该 App keychain 会先被清理。"
fi

STAGE="$(vpa_default_stage restore "$BUNDLE_ID")"
qstage="$(vpa_quote_args "$STAGE")"
vpa_say "upload backup -> remote stage: ${STAGE}"
vpa_ssh "$SSH_PORT" "rm -rf ${qstage} && mkdir -p ${qstage}" >/dev/null

case "${ARCHIVE:l}" in
  *.tar.gz|*.tgz|*.gz)
    gzip -dc "$ARCHIVE" | vpa_ssh "$SSH_PORT" "cd ${qstage} && tar -xpf -" ;;
  *.tar)
    cat "$ARCHIVE" | vpa_ssh "$SSH_PORT" "cd ${qstage} && tar -xpf -" ;;
  *)
    vpa_die "unsupported archive extension; expected .tar.gz/.tgz/.tar: $ARCHIVE" ;;
esac

vpa_say "restoring app: ${BUNDLE_ID} via SSH localhost:${SSH_PORT}"
vpa_run_guest "$SSH_PORT" restore "$BUNDLE_ID" "$STAGE" "$RELAUNCH" "$RESPRING"

if [[ "${VPHONE_APP_KEEP_STAGE:-0}" != "1" ]]; then
  vpa_ssh "$SSH_PORT" "rm -rf ${qstage}" >/dev/null 2>&1 || true
fi
vpa_ok "restore complete: ${BUNDLE_ID}"
