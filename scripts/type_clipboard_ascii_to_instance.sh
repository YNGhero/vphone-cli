#!/bin/zsh
# type_clipboard_ascii_to_instance.sh — type macOS clipboard/text into the focused vphone field.
#
# This uses the running vphone GUI host-control socket and injects ASCII through
# the VM keyboard path, matching the GUI menu "按键 -> 从剪贴板输入 ASCII".

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

VM_INPUT=""
TEXT_INPUT=""
TEXT_SET=0
FILE_INPUT=""
READ_STDIN=0
WANT_SCREEN=0
DELAY_MS=100
POSITIONAL=()

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/type_clipboard_ascii_to_instance.sh <vm-dir>
  zsh scripts/type_clipboard_ascii_to_instance.sh <vm-dir> --text 'hello123'
  printf 'hello123' | zsh scripts/type_clipboard_ascii_to_instance.sh <vm-dir> --stdin
  zsh scripts/type_clipboard_ascii_to_instance.sh --vm <vm-dir> --file /tmp/input.txt

Default text source:
  macOS clipboard via pbpaste.

Options:
  --vm <dir>       Target vphone instance directory.
  --text <text>    Type this text instead of pbpaste.
  --file <path>    Read text from file.
  --stdin          Read text from stdin.
  --screen         Ask host-control to return a compact screenshot after typing.
  --delay <ms>     Screenshot delay hint, default 100.

Notes:
  - The target VM GUI must already be running and <vm-dir>/vphone.sock must exist.
  - This types into the currently focused field. Tap/click the field first.
  - Only ASCII characters supported by VPhoneKeyHelper are typed; Chinese/emoji are skipped.
USAGE
}

latest_instance_dir() {
  [[ -d "${PROJECT_ROOT}/vm.instances" ]] || return 0
  find "${PROJECT_ROOT}/vm.instances" -maxdepth 2 -name config.plist -print 2>/dev/null \
    | while IFS= read -r cfg; do stat -f '%m %N' "$cfg" 2>/dev/null; done \
    | sort -rn \
    | head -1 \
    | sed 's/^[0-9][0-9]* //' \
    | xargs -I{} dirname "{}" 2>/dev/null || true
}

path_len_with_nul() {
  /usr/bin/python3 - "$1" <<'PY'
import sys
print(len(sys.argv[1].encode()) + 1)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --vm)
      [[ $# -ge 2 ]] || die "--vm requires a value"
      VM_INPUT="$2"
      shift 2
      ;;
    --text)
      [[ $# -ge 2 ]] || die "--text requires a value"
      TEXT_INPUT="$2"
      TEXT_SET=1
      shift 2
      ;;
    --file)
      [[ $# -ge 2 ]] || die "--file requires a value"
      FILE_INPUT="$2"
      shift 2
      ;;
    --stdin)
      READ_STDIN=1
      shift
      ;;
    --screen)
      WANT_SCREEN=1
      shift
      ;;
    --delay)
      [[ $# -ge 2 ]] || die "--delay requires a value"
      DELAY_MS="$2"
      shift 2
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$VM_INPUT" && ${#POSITIONAL[@]} -ge 1 ]]; then
  VM_INPUT="${POSITIONAL[1]}"
fi

if (( TEXT_SET == 0 )) && [[ -z "$FILE_INPUT" && "$READ_STDIN" != "1" && ${#POSITIONAL[@]} -ge 2 ]]; then
  TEXT_INPUT="${(j: :)POSITIONAL[2,-1]}"
  TEXT_SET=1
fi

if [[ -z "$VM_INPUT" ]]; then
  VM_INPUT="$(latest_instance_dir)"
fi

[[ -n "$VM_INPUT" ]] || die "missing <vm-dir>"
VM_DIR="${VM_INPUT:A}"
SOCKET_PATH="${VM_DIR}/vphone.sock"

[[ -f "${VM_DIR}/config.plist" ]] || die "target VM config not found: ${VM_DIR}/config.plist"

if [[ -n "$FILE_INPUT" ]]; then
  FILE_PATH="${FILE_INPUT:A}"
  [[ -f "$FILE_PATH" ]] || die "text file not found: ${FILE_PATH}"
  TEXT_INPUT="$(cat "$FILE_PATH")"
  TEXT_SET=1
elif [[ "$READ_STDIN" == "1" ]]; then
  TEXT_INPUT="$(cat)"
  TEXT_SET=1
elif (( TEXT_SET == 0 )); then
  command -v pbpaste >/dev/null 2>&1 || die "pbpaste not found; use --text/--file/--stdin"
  TEXT_INPUT="$(pbpaste)"
  TEXT_SET=1
fi

[[ "$DELAY_MS" == <-> ]] || die "--delay must be numeric: ${DELAY_MS}"

socket_len="$(path_len_with_nul "$SOCKET_PATH")"
if [[ "$socket_len" == <-> ]] && (( socket_len > 103 )); then
  die "vphone.sock path is too long (${socket_len} bytes): ${SOCKET_PATH}; use a shorter instance directory name"
fi
[[ -S "$SOCKET_PATH" ]] || die "host-control socket not found. Start the GUI first: ${SOCKET_PATH}"

say "VM_DIR=${VM_DIR}"
say "socket=${SOCKET_PATH}"
say "typing ${#TEXT_INPUT} characters into the focused guest field"

/usr/bin/python3 - "$SOCKET_PATH" "$TEXT_INPUT" "$WANT_SCREEN" "$DELAY_MS" <<'PY'
from __future__ import annotations
import json
import socket
import sys

socket_path = sys.argv[1]
text = sys.argv[2]
want_screen = sys.argv[3] == "1"
delay_ms = int(sys.argv[4])

req = {
    "t": "type_ascii",
    "text": text,
    "screen": want_screen,
    "delay": delay_ms,
}

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(60)
s.connect(socket_path)
s.sendall(json.dumps(req).encode("utf-8") + b"\n")

buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk:
        break
    buf += chunk

if not buf:
    print("no response from vphone host-control socket", file=sys.stderr)
    sys.exit(2)

line = buf.split(b"\n", 1)[0]
try:
    resp = json.loads(line.decode("utf-8"))
except Exception as e:
    print(f"invalid response: {e}: {line!r}", file=sys.stderr)
    sys.exit(2)

if not resp.get("ok"):
    print(resp.get("error") or resp, file=sys.stderr)
    sys.exit(1)

print(resp.get("msg") or "typed")
PY

ok "type_ascii request completed"
