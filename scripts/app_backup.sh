#!/bin/zsh
# app_backup.sh — backup one installed app's data/preferences/app-groups/keychain slice from a running vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/app_backup.sh [SSH_PORT] <bundle-id> [backup-name]
  zsh scripts/app_backup.sh [SSH_PORT] <bundle-id> --output-dir <dir> [backup-name]

Options:
  --instance-name <name>  Override the instance name used in archive filename

Examples:
  zsh scripts/app_backup.sh 2224 com.example.app before-login
  zsh scripts/app_backup.sh com.example.app clean-state

Output:
  app_backups/<bundle-id>/<instance-name>-<timestamp>-<backup-name>.tar.gz
USAGE
}

SSH_PORT="${SSH_LOCAL_PORT:-2224}"
BUNDLE_ID=""
BACKUP_NAME="manual"
OUTPUT_DIR=""
INSTANCE_NAME=""

args=("$@")
if (( ${#args[@]} > 0 )) && [[ "${args[1]}" == <-> ]]; then
  SSH_PORT="${args[1]}"
  args=("${args[@]:1}")
fi

while (( ${#args[@]} > 0 )); do
  case "${args[1]}" in
    -h|--help)
      usage; exit 0 ;;
    --output-dir)
      (( ${#args[@]} >= 2 )) || vpa_die "--output-dir requires a path"
      OUTPUT_DIR="${args[2]}"
      args=("${args[@]:2}") ;;
    --output-dir=*)
      OUTPUT_DIR="${args[1]#--output-dir=}"
      args=("${args[@]:1}") ;;
    --instance-name)
      (( ${#args[@]} >= 2 )) || vpa_die "--instance-name requires a name"
      INSTANCE_NAME="${args[2]}"
      args=("${args[@]:2}") ;;
    --instance-name=*)
      INSTANCE_NAME="${args[1]#--instance-name=}"
      args=("${args[@]:1}") ;;
    --*)
      vpa_die "unknown option: ${args[1]}" ;;
    *)
      if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID="${args[1]}"
      else
        BACKUP_NAME="${args[1]}"
      fi
      args=("${args[@]:1}") ;;
  esac
done

[[ "$SSH_PORT" == <-> ]] || vpa_die "SSH_PORT must be numeric: $SSH_PORT"
vpa_validate_bundle_id "$BUNDLE_ID"
vpa_require_tools

safe_bundle="$(vpa_sanitize_name "$BUNDLE_ID")"
safe_name="$(vpa_sanitize_name "$BACKUP_NAME")"
if [[ -z "$INSTANCE_NAME" ]]; then
  INSTANCE_NAME="$(vpa_instance_name_for_port "$SSH_PORT")"
fi
safe_instance="$(vpa_sanitize_name "$INSTANCE_NAME")"
ts="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${VPA_BACKUP_ROOT}/${safe_bundle}"
fi
mkdir -p "$OUTPUT_DIR"
ARCHIVE="${OUTPUT_DIR:A}/${safe_instance}-${ts}-${safe_name}.tar.gz"
PARTIAL="${ARCHIVE}.partial"
STAGE="$(vpa_default_stage backup "$BUNDLE_ID")"

vpa_say "backup app: ${BUNDLE_ID} on ${INSTANCE_NAME} via SSH localhost:${SSH_PORT}"
vpa_say "remote stage: ${STAGE}"

# Run guest-side staging. stdout contains the staged path; stderr contains logs.
vpa_run_guest "$SSH_PORT" backup "$BUNDLE_ID" "$STAGE" "$BACKUP_NAME" "$INSTANCE_NAME" >/dev/null

qstage="$(vpa_quote_args "$STAGE")"
rm -f "$PARTIAL"
vpa_say "downloading archive -> ${ARCHIVE}"
if vpa_ssh "$SSH_PORT" "cd ${qstage} && tar -cf - ." | gzip -c > "$PARTIAL"; then
  mv "$PARTIAL" "$ARCHIVE"
else
  rm -f "$PARTIAL"
  vpa_die "failed to download backup archive"
fi

if [[ "${VPHONE_APP_KEEP_STAGE:-0}" != "1" ]]; then
  vpa_ssh "$SSH_PORT" "rm -rf ${qstage}" >/dev/null 2>&1 || true
fi

vpa_ok "backup complete"
print -r -- "$ARCHIVE"
