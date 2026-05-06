#!/bin/zsh
# Build and install VPhoneProfileTweak into a running jailbroken vphone instance.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/install_profile_tweak_to_instance.sh <实例名|VM目录|SSH端口> <bundle-id> [bundle-id ...]

Examples:
  zsh scripts/install_profile_tweak_to_instance.sh instagram-01 com.burbn.instagram
  zsh scripts/install_profile_tweak_to_instance.sh vm.instances/instagram-01 com.burbn.instagram
  zsh scripts/install_profile_tweak_to_instance.sh 2224 com.burbn.instagram

Notes:
  - The tweak reads /var/mobile/vphone_app_profiles/<bundle-id>.json.
  - Reopen or relaunch the target app after installing.
USAGE
}

(( $# >= 2 )) || { usage; exit 1; }
TARGET="$1"
shift
SSH_PORT="$(vpa_resolve_ssh_port "$TARGET")"

bundles=("$@")
for b in "${bundles[@]}"; do
  vpa_validate_bundle_id "$b"
done

vpa_require_tools
zsh "${PROJECT_ROOT}/scripts/build_profile_tweak.sh" >/dev/null
DYLIB="${PROJECT_ROOT}/.build/vphone_profile_tweak/VPhoneProfileTweak.dylib"
[[ -f "$DYLIB" ]] || vpa_die "build did not produce $DYLIB"

TMP_PLIST="$(mktemp -t vphone-profile-tweak.XXXXXX).plist"
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
REMOTE_DYLIB="${REMOTE_DIR}/VPhoneProfileTweak.dylib"
REMOTE_PLIST="${REMOTE_DIR}/VPhoneProfileTweak.plist"
qdir="$(vpa_quote_args "$REMOTE_DIR")"
qdylib="$(vpa_quote_args "$REMOTE_DYLIB")"
qplist="$(vpa_quote_args "$REMOTE_PLIST")"

vpa_say "installing profile tweak to target=${TARGET} (SSH localhost:${SSH_PORT})"
vpa_ssh "$SSH_PORT" "mkdir -p ${qdir}" >/dev/null
vpa_ssh "$SSH_PORT" "cat > ${qdylib}" < "$DYLIB"
vpa_ssh "$SSH_PORT" "cat > ${qplist}" < "$TMP_PLIST"
vpa_ssh "$SSH_PORT" "chown 0:0 ${qdylib} ${qplist} 2>/dev/null || true; chmod 0755 ${qdylib}; chmod 0644 ${qplist}" >/dev/null 2>&1 || true
rm -f "$TMP_PLIST"

vpa_ok "installed VPhoneProfileTweak"
print -r -- "Dylib: ${REMOTE_DYLIB}"
print -r -- "Plist: ${REMOTE_PLIST}"
print -r -- "Bundles: ${bundles[*]}"
print -r -- "Next: close/reopen target app, or run app_new_device/app_restore with relaunch."
