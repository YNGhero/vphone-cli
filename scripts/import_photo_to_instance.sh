#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/import_photo_to_instance.sh IMAGE_PATH [SSH_PORT] [ALBUM]

Defaults:
  SSH_PORT: ${SSH_LOCAL_PORT:-2224}
  ALBUM:    ${VPHONE_PHOTO_ALBUM:-VPhoneImports}
USAGE
}

[[ ${1:-} != "-h" && ${1:-} != "--help" ]] || { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }

IMAGE_PATH="$1"
SSH_PORT="${2:-${SSH_LOCAL_PORT:-2224}}"
ALBUM="${3:-${VPHONE_PHOTO_ALBUM:-VPhoneImports}}"

[[ -f "$IMAGE_PATH" ]] || { echo "[-] image not found: $IMAGE_PATH" >&2; exit 2; }
[[ "$SSH_PORT" == <-> ]] || { echo "[-] SSH_PORT must be numeric: $SSH_PORT" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "[-] sshpass not found" >&2; exit 2; }
command -v xcrun >/dev/null 2>&1 || { echo "[-] xcrun not found; install/select full Xcode" >&2; exit 2; }
command -v ldid >/dev/null 2>&1 || { echo "[-] ldid not found; run make setup_tools or brew install ldid" >&2; exit 2; }

BUILD_DIR="${PROJECT_ROOT}/.build/photo_import"
IMPORTER="${BUILD_DIR}/vphone_photo_import"
ENTITLEMENTS="${BUILD_DIR}/photo_import.entitlements.plist"
mkdir -p "$BUILD_DIR"

python3 - "$PROJECT_ROOT/scripts/vphoned/entitlements.plist" "$ENTITLEMENTS" <<'PY'
import plistlib, sys
src, dst = sys.argv[1:]
with open(src, 'rb') as f:
    ent = plistlib.load(f)
ent['com.apple.private.tcc.allow'] = ['kTCCServicePhotos', 'kTCCServicePhotosAdd']
ent['com.apple.private.tcc.allow.overridable'] = ['kTCCServicePhotos', 'kTCCServicePhotosAdd']
with open(dst, 'wb') as f:
    plistlib.dump(ent, f)
PY

if [[ ! -x "$IMPORTER" || "$PROJECT_ROOT/scripts/photo_import/vphone_photo_import.m" -nt "$IMPORTER" || "$PROJECT_ROOT/scripts/photo_import/Info.plist" -nt "$IMPORTER" ]]; then
  echo "[*] building PhotoKit importer"
  xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc -miphoneos-version-min=16.0 \
    "$PROJECT_ROOT/scripts/photo_import/vphone_photo_import.m" \
    -o "$IMPORTER" \
    -framework Foundation \
    -framework Photos \
    -Wl,-sectcreate,__TEXT,__info_plist,"$PROJECT_ROOT/scripts/photo_import/Info.plist"
  ldid -S"$ENTITLEMENTS" -M "-K$PROJECT_ROOT/scripts/vphoned/signcert.p12" "$IMPORTER"
fi

image_base="$(basename "$IMAGE_PATH")"
safe_base="$(printf '%s' "$image_base" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
remote_image="/var/mobile/Documents/vphone-photo-imports/${safe_base}"
remote_importer="/var/root/vphone_photo_import"

q() {
  python3 - "$1" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
}

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -p "$SSH_PORT"
  root@127.0.0.1
)

ssh_remote() {
  sshpass -p alpine ssh "${SSH_OPTS[@]}" "$@"
}

echo "[*] installing importer -> ${remote_importer}"
ssh_remote "/var/jb/usr/bin/cat > $(q "$remote_importer") && /var/jb/usr/bin/chmod 0755 $(q "$remote_importer")" < "$IMPORTER"

echo "[*] uploading image -> ${remote_image}"
ssh_remote "/var/jb/usr/bin/mkdir -p /var/mobile/Documents/vphone-photo-imports && /var/jb/usr/bin/cat > $(q "$remote_image") && /var/jb/usr/bin/chown mobile:mobile $(q "$remote_image")" < "$IMAGE_PATH"

echo "[*] importing into Photos album: ${ALBUM}"
ssh_remote "$(q "$remote_importer") $(q "$remote_image") $(q "$ALBUM"); rc=\$?; /var/jb/usr/bin/killall Photos 2>/dev/null || true; /var/jb/usr/bin/killall assetsd 2>/dev/null || true; exit \$rc"
