#!/bin/zsh
# Build InstagramAuditTweak rootless iOS dylib.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SRC="${PROJECT_ROOT}/tweaks/instagram_audit_tweak/InstagramAuditTweak.m"
OUT_DIR="${PROJECT_ROOT}/.build/instagram_audit_tweak"
OUT="${OUT_DIR}/InstagramAuditTweak.dylib"

export PATH="${PROJECT_ROOT}/.tools/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

[[ -f "$SRC" ]] || { print -r -- "[-] missing source: $SRC" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { print -r -- "[-] xcrun not found" >&2; exit 1; }
command -v ldid >/dev/null 2>&1 || { print -r -- "[-] ldid not found; install ldid first" >&2; exit 1; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
mkdir -p "$OUT_DIR"

print -r -- "[*] building InstagramAuditTweak"
"$CC" -isysroot "$SDK" \
  -arch arm64 -arch arm64e \
  -miphoneos-version-min=15.0 \
  -dynamiclib \
  -fobjc-arc -O2 \
  -framework Foundation \
  -framework CoreFoundation \
  -o "$OUT" \
  "$SRC"

ldid -S "$OUT"
print -r -- "[+] built: $OUT"
