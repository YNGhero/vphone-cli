#!/bin/zsh
# Build and install InstagramAuditTweak into a running jailbroken vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/install_instagram_audit_tweak_to_instance.sh <SSH_PORT> [bundle-id ...]

Examples:
  zsh scripts/install_instagram_audit_tweak_to_instance.sh 2224
  zsh scripts/install_instagram_audit_tweak_to_instance.sh 2224 com.burbn.instagram

Notes:
  - Default bundle is com.burbn.instagram.
  - Output JSON is /tmp/instagram_account.json inside the guest.
  - This tweak is audit-only: it fills a single account JSON with whatever fields are captured, and does not modify values.
USAGE
}

(( $# >= 1 )) || { usage; exit 1; }
SSH_PORT="$1"
shift
[[ "$SSH_PORT" == <-> ]] || vpa_die "SSH_PORT must be numeric: $SSH_PORT"

bundles=("$@")
if (( ${#bundles[@]} == 0 )); then
  bundles=(com.burbn.instagram)
fi
for b in "${bundles[@]}"; do
  vpa_validate_bundle_id "$b"
done

vpa_require_tools
zsh "${PROJECT_ROOT}/scripts/build_instagram_audit_tweak.sh" >/dev/null
DYLIB="${PROJECT_ROOT}/.build/instagram_audit_tweak/InstagramAuditTweak.dylib"
TEMPLATE="${PROJECT_ROOT}/tweaks/instagram_audit_tweak/InstagramAuditTweak.plist.template"
[[ -f "$DYLIB" ]] || vpa_die "build did not produce $DYLIB"
[[ -f "$TEMPLATE" ]] || vpa_die "missing plist template: $TEMPLATE"

TMP_PLIST="$(mktemp -t instagram-audit-tweak.XXXXXX).plist"
bundle_args=("${bundles[@]}")
/usr/bin/python3 - "$TEMPLATE" "$TMP_PLIST" "${bundle_args[@]}" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
entries = "\n".join(f"      <string>{bundle}</string>" for bundle in sys.argv[3:])
out = src.replace('__BUNDLE_ENTRIES__', entries)
Path(sys.argv[2]).write_text(out)
PY

REMOTE_DIR="/var/jb/Library/MobileSubstrate/DynamicLibraries"
REMOTE_DYLIB="${REMOTE_DIR}/InstagramAuditTweak.dylib"
REMOTE_PLIST="${REMOTE_DIR}/InstagramAuditTweak.plist"
qdir="$(vpa_quote_args "$REMOTE_DIR")"
qdylib="$(vpa_quote_args "$REMOTE_DYLIB")"
qplist="$(vpa_quote_args "$REMOTE_PLIST")"

vpa_say "installing InstagramAuditTweak to localhost:${SSH_PORT}"
vpa_ssh "$SSH_PORT" "mkdir -p ${qdir}" >/dev/null
vpa_ssh "$SSH_PORT" "cat > ${qdylib}" < "$DYLIB"
vpa_ssh "$SSH_PORT" "cat > ${qplist}" < "$TMP_PLIST"
vpa_ssh "$SSH_PORT" "rm -f /tmp/instagram_audit.jsonl /tmp/instagram_account.json; chown 0:0 ${qdylib} ${qplist} 2>/dev/null || true; chmod 0755 ${qdylib}; chmod 0644 ${qplist}" >/dev/null 2>&1 || true
rm -f "$TMP_PLIST"

vpa_ok "installed InstagramAuditTweak"
print -r -- "Dylib: ${REMOTE_DYLIB}"
print -r -- "Plist: ${REMOTE_PLIST}"
print -r -- "Bundles: ${bundles[*]}"
print -r -- "JSON: /tmp/instagram_account.json"
print -r -- "Next: close/reopen target app, then tail the log via SSH."
