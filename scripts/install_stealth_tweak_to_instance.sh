#!/bin/zsh
# Build and install VPhoneStealthTweak into a running jailbroken vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/install_stealth_tweak_to_instance.sh <实例名|VM目录|SSH端口> [bundle-id ...]

Defaults:
  bundle-id: com.burbn.instagram

Examples:
  zsh scripts/install_stealth_tweak_to_instance.sh instagram-01
  zsh scripts/install_stealth_tweak_to_instance.sh vm.instances/instagram-01 com.burbn.instagram
  zsh scripts/install_stealth_tweak_to_instance.sh 2224

Notes:
  - Hides common jailbreak/injection/debug probes from the target app.
  - Reopen or relaunch the target app after installing.
  - Runtime log: /tmp/vphone_stealth_tweak.log inside guest.
USAGE
}

stealth_ssh_retry() {
  local port="$1"
  shift
  local attempt max_attempts err_file err_text rc
  max_attempts="${VPHONE_SSH_ATTEMPTS:-5}"
  [[ "$max_attempts" == <-> && "$max_attempts" -ge 1 ]] || max_attempts=5
  err_file="$(mktemp "${TMPDIR:-/tmp}/vphone-stealth-ssh.XXXXXX")"
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    : > "$err_file"
    if vpa_ssh "$port" "$@" 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    rc=$?
    err_text="$(cat "$err_file" 2>/dev/null || true)"
    if (( attempt < max_attempts )) && vpa_is_transient_ssh_error "$err_text"; then
      vpa_warn "transient SSH failure on localhost:${port}; retry ${attempt}/${max_attempts}"
      sleep "$(vpa_retry_sleep "$attempt")"
      continue
    fi
    cat "$err_file" >&2 2>/dev/null || true
    rm -f "$err_file"
    return "$rc"
  done
  rm -f "$err_file"
  return 1
}

stealth_upload_retry() {
  local port="$1"
  local local_file="$2"
  local remote_file="$3"
  local attempt max_attempts err_file err_text rc qremote
  qremote="$(vpa_quote_args "$remote_file")"
  max_attempts="${VPHONE_SSH_ATTEMPTS:-5}"
  [[ "$max_attempts" == <-> && "$max_attempts" -ge 1 ]] || max_attempts=5
  err_file="$(mktemp "${TMPDIR:-/tmp}/vphone-stealth-upload.XXXXXX")"
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    : > "$err_file"
    if vpa_ssh "$port" "cat > ${qremote}" < "$local_file" 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    rc=$?
    err_text="$(cat "$err_file" 2>/dev/null || true)"
    if (( attempt < max_attempts )) && vpa_is_transient_ssh_error "$err_text"; then
      vpa_warn "transient SSH upload failure on localhost:${port}; retry ${attempt}/${max_attempts}"
      sleep "$(vpa_retry_sleep "$attempt")"
      continue
    fi
    cat "$err_file" >&2 2>/dev/null || true
    rm -f "$err_file"
    return "$rc"
  done
  rm -f "$err_file"
  return 1
}

(( $# >= 1 )) || { usage; exit 1; }
TARGET="$1"
shift
SSH_PORT="$(vpa_resolve_ssh_port "$TARGET")"

bundles=("$@")
if (( ${#bundles[@]} == 0 )); then
  bundles=(com.burbn.instagram)
fi
for b in "${bundles[@]}"; do
  vpa_validate_bundle_id "$b"
done

vpa_require_tools
zsh "${PROJECT_ROOT}/scripts/build_stealth_tweak.sh" >/dev/null
DYLIB="${PROJECT_ROOT}/.build/vphone_stealth_tweak/VPhoneStealthTweak.dylib"
[[ -f "$DYLIB" ]] || vpa_die "build did not produce $DYLIB"

TMP_PLIST="$(mktemp -t vphone-stealth-tweak.XXXXXX).plist"
{
  cat <<'XML_HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Filter</key>
  <dict>
    <key>Bundles</key>
    <array>
XML_HEAD
  for b in "${bundles[@]}"; do
    print -r -- "      <string>${b}</string>"
  done
  cat <<'XML_TAIL'
    </array>
  </dict>
</dict>
</plist>
XML_TAIL
} > "$TMP_PLIST"

REMOTE_DIR="/var/jb/Library/MobileSubstrate/DynamicLibraries"
REMOTE_DYLIB="${REMOTE_DIR}/VPhoneStealthTweak.dylib"
REMOTE_PLIST="${REMOTE_DIR}/VPhoneStealthTweak.plist"
qdir="$(vpa_quote_args "$REMOTE_DIR")"
qdylib="$(vpa_quote_args "$REMOTE_DYLIB")"
qplist="$(vpa_quote_args "$REMOTE_PLIST")"

vpa_say "installing stealth tweak to target=${TARGET} (SSH localhost:${SSH_PORT})"
stealth_ssh_retry "$SSH_PORT" "mkdir -p ${qdir}" >/dev/null
stealth_upload_retry "$SSH_PORT" "$DYLIB" "$REMOTE_DYLIB"
stealth_upload_retry "$SSH_PORT" "$TMP_PLIST" "$REMOTE_PLIST"
stealth_ssh_retry "$SSH_PORT" "chown 0:0 ${qdylib} ${qplist} 2>/dev/null || true; chmod 0755 ${qdylib}; chmod 0644 ${qplist}" >/dev/null 2>&1 || true
rm -f "$TMP_PLIST"

vpa_ok "installed VPhoneStealthTweak"
print -r -- "Dylib: ${REMOTE_DYLIB}"
print -r -- "Plist: ${REMOTE_PLIST}"
print -r -- "Bundles: ${bundles[*]}"
print -r -- "Next: close/reopen target app, or run app_new_device/app_restore with relaunch."
