#!/bin/zsh
# set_location_by_ip.sh — query ipapi.co for an IP and apply that coordinate to a running vphone instance.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"

export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

VM_INPUT=""
TARGET_IP=""
WANT_SCREEN=0
DELAY_MS=200
WAIT_SECONDS=30
ALTITUDE=0
HACC=1000
VACC=50
SPEED=0
COURSE=-1
POSITIONAL=()

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/set_location_by_ip.sh <vm-dir-or-name> <ip>
  zsh scripts/set_location_by_ip.sh <ip> --vm <vm-dir-or-name>
  zsh scripts/set_location_by_ip.sh <ip>              # use latest running instance with vphone.sock

Examples:
  zsh scripts/set_location_by_ip.sh vm.instances/phone-01 8.8.8.8
  zsh scripts/set_location_by_ip.sh trollstore-clean 8.8.8.8
  zsh scripts/set_location_by_ip.sh 8.8.8.8 --vm trollstore-clone-20260505-182858

Options:
  --vm <dir|name>     Target instance directory or name under vm.instances/
  --ip <ip>           Target IP to locate via https://ipapi.co/<ip>/json/
  --screen            Ask host-control to return a compact screenshot after setting location
  --delay <ms>        Screenshot delay hint, default 200
  --wait <seconds>    Wait/retry for host-control and guest location support, default 30
  --alt <meters>      Altitude, default 0
  --hacc <meters>     Horizontal accuracy, default 1000
  --vacc <meters>     Vertical accuracy, default 50
  --speed <m/s>       Speed, default 0
  --course <degrees>  Course, default -1

Notes:
  - The target instance must already be running and <vm-dir>/vphone.sock must exist.
  - This uses vphone-cli's built-in location simulation through the local host-control socket.
USAGE
}

looks_like_vm_input() {
  local value="$1"
  [[ -z "$value" ]] && return 1
  [[ -f "${value:A}/config.plist" ]] && return 0
  [[ -f "${PROJECT_ROOT}/${value}/config.plist" ]] && return 0
  [[ -f "${PROJECT_ROOT}/vm.instances/${value}/config.plist" ]] && return 0
  [[ "$value" == */* ]] && return 0
  return 1
}

latest_running_instance_dir() {
  [[ -d "${PROJECT_ROOT}/vm.instances" ]] || return 0
  find "${PROJECT_ROOT}/vm.instances" -maxdepth 2 -name vphone.sock -type s -print 2>/dev/null \
    | while IFS= read -r sock; do stat -f '%m %N' "$sock" 2>/dev/null; done \
    | sort -rn \
    | head -1 \
    | sed 's/^[0-9][0-9]* //' \
    | xargs -I{} dirname "{}" 2>/dev/null || true
}

resolve_vm_dir() {
  local input="$1"
  local candidate=""

  if [[ -z "$input" ]]; then
    candidate="$(latest_running_instance_dir)"
  elif [[ -f "${input:A}/config.plist" ]]; then
    candidate="${input:A}"
  elif [[ -f "${PROJECT_ROOT}/${input}/config.plist" ]]; then
    candidate="${PROJECT_ROOT}/${input}"
  elif [[ -f "${PROJECT_ROOT}/vm.instances/${input}/config.plist" ]]; then
    candidate="${PROJECT_ROOT}/vm.instances/${input}"
  else
    candidate="${input:A}"
  fi

  [[ -n "$candidate" ]] || die "missing target VM dir; pass --vm <dir|name>"
  [[ -f "${candidate}/config.plist" ]] || die "target VM config not found: ${candidate}/config.plist"
  print -r -- "$candidate"
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
    --ip)
      [[ $# -ge 2 ]] || die "--ip requires a value"
      TARGET_IP="$2"
      shift 2
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
    --wait)
      [[ $# -ge 2 ]] || die "--wait requires a value"
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --alt|--altitude)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ALTITUDE="$2"
      shift 2
      ;;
    --hacc|--horizontal-accuracy)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      HACC="$2"
      shift 2
      ;;
    --vacc|--vertical-accuracy)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      VACC="$2"
      shift 2
      ;;
    --speed)
      [[ $# -ge 2 ]] || die "--speed requires a value"
      SPEED="$2"
      shift 2
      ;;
    --course)
      [[ $# -ge 2 ]] || die "--course requires a value"
      COURSE="$2"
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

if [[ -z "$TARGET_IP" && ${#POSITIONAL[@]} -ge 1 ]]; then
  if looks_like_vm_input "${POSITIONAL[1]}"; then
    VM_INPUT="${VM_INPUT:-${POSITIONAL[1]}}"
    (( ${#POSITIONAL[@]} >= 2 )) && TARGET_IP="${POSITIONAL[2]}"
  else
    TARGET_IP="${POSITIONAL[1]}"
    (( ${#POSITIONAL[@]} >= 2 )) && VM_INPUT="${VM_INPUT:-${POSITIONAL[2]}}"
  fi
fi

[[ -n "$TARGET_IP" ]] || die "missing target IP"
[[ "$DELAY_MS" == <-> ]] || die "--delay must be numeric: ${DELAY_MS}"
[[ "$WAIT_SECONDS" == <-> ]] || die "--wait must be numeric: ${WAIT_SECONDS}"

VM_DIR="$(resolve_vm_dir "$VM_INPUT")"
SOCKET_PATH="${VM_DIR}/vphone.sock"

socket_len="$(path_len_with_nul "$SOCKET_PATH")"
if [[ "$socket_len" == <-> ]] && (( socket_len > 103 )); then
  die "vphone.sock path is too long (${socket_len} bytes): ${SOCKET_PATH}; use a shorter instance directory name"
fi

say "VM_DIR=${VM_DIR}"
say "target_ip=${TARGET_IP}"
say "query=https://ipapi.co/${TARGET_IP}/json/"

/usr/bin/python3 - "$SOCKET_PATH" "$TARGET_IP" "$WANT_SCREEN" "$DELAY_MS" "$WAIT_SECONDS" "$ALTITUDE" "$HACC" "$VACC" "$SPEED" "$COURSE" <<'PY'
from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.parse
import urllib.request

socket_path = sys.argv[1]
target_ip = sys.argv[2]
want_screen = sys.argv[3] == "1"
delay_ms = int(sys.argv[4])
wait_seconds = int(sys.argv[5])
altitude = float(sys.argv[6])
hacc = float(sys.argv[7])
vacc = float(sys.argv[8])
speed = float(sys.argv[9])
course = float(sys.argv[10])


def fail(msg: str, code: int = 1) -> None:
    print(f"[-] {msg}", file=sys.stderr)
    raise SystemExit(code)


def query_ipapi(ip: str) -> dict:
    encoded = urllib.parse.quote(ip, safe="")
    url = f"https://ipapi.co/{encoded}/json/"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "vphone-cli-location-script/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = resp.read()
    try:
        payload = json.loads(data.decode("utf-8"))
    except Exception as exc:
        fail(f"invalid ipapi response: {exc}")
    if payload.get("error"):
        fail(f"ipapi error: {payload.get('reason') or payload}")
    return payload


def as_float(payload: dict, key: str) -> float:
    value = payload.get(key)
    try:
        return float(value)
    except Exception:
        fail(f"ipapi response missing numeric {key}: {value!r}")


payload = query_ipapi(target_ip)
lat = as_float(payload, "latitude")
lon = as_float(payload, "longitude")

place = ", ".join(
    str(x)
    for x in [
        payload.get("city"),
        payload.get("region"),
        payload.get("country_name") or payload.get("country_code"),
    ]
    if x
)
timezone = payload.get("timezone") or ""
org = payload.get("org") or ""

print(f"[*] ipapi: {payload.get('ip') or target_ip}")
print(f"[*] place: {place or '-'}")
print(f"[*] timezone: {timezone or '-'}")
print(f"[*] org: {org or '-'}")
print(f"[*] coordinate: {lat}, {lon}")

req = {
    "t": "location",
    "lat": lat,
    "lon": lon,
    "alt": altitude,
    "hacc": hacc,
    "vacc": vacc,
    "speed": speed,
    "course": course,
    "name": f"ipapi:{payload.get('ip') or target_ip}",
    "screen": want_screen,
    "delay": delay_ms,
}

deadline = time.time() + max(wait_seconds, 0)
last_error = None
while True:
    if not os.path.exists(socket_path):
        last_error = f"host-control socket not found: {socket_path}"
    else:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(20)
            s.connect(socket_path)
            s.sendall(json.dumps(req).encode("utf-8") + b"\n")

            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
            s.close()

            if not buf:
                last_error = "no response from vphone host-control socket"
            else:
                line = buf.split(b"\n", 1)[0]
                resp = json.loads(line.decode("utf-8"))
                if resp.get("ok"):
                    print(f"[+] {resp.get('msg') or 'location set'}")
                    break
                last_error = resp.get("error") or str(resp)
        except Exception as exc:
            last_error = str(exc)

    if time.time() >= deadline:
        fail(last_error or "failed to set location")
    time.sleep(1.0)
PY

ok "location applied from ipapi result"
