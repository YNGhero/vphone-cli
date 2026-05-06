#!/bin/zsh
# set_instance_proxy.sh — configure per-instance iOS SystemConfiguration proxy.
#
# This is a first-stage, guest-level proxy configuration:
#   - HTTP/HTTPS proxies are written to SystemConfiguration Proxies.
#   - SOCKS5 proxies are written to SystemConfiguration SOCKS keys.
#   - Apps that use CFNetwork/system proxy settings should follow it.
#   - This is not a TUN/VPN transparent proxy; apps may bypass it.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
cd "$PROJECT_ROOT"
source "${PROJECT_ROOT}/scripts/vphone_guest_config.sh"

TARGET="${1:-}"
ACTION="${2:-}"
shift $(( $# > 0 ? 1 : 0 ))
shift $(( $# > 0 ? 1 : 0 ))

VM_DIR_INPUT=""
SSH_PORT=""
YES=0
RUN_TEST=0
NO_RESTART=0
REMOTE_PREF="/var/preferences/SystemConfiguration/preferences.plist"
REMOTE_STATE="/var/mobile/Library/Preferences/vphone_instance_proxy.json"
GUEST_REMOTE_PATH='export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/var/jb/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/sbin:/usr/sbin:/iosbinpack64/sbin:/iosbinpack64/usr/sbin:$PATH; '

usage() {
  cat <<USAGE
Usage:
  zsh scripts/set_instance_proxy.sh <vm-dir|ssh-port> <proxy-url|clear|test> [options]

Proxy URL examples:
  http://user:pass@1.2.3.4:8080
  https://1.2.3.4:8443
  socks5://user:pass@1.2.3.4:1080
  socks5h://1.2.3.4:1080

Options:
  --vm-dir <dir>   Explicit VM dir; used to update instance.env
  --test           Also test direct/proxy exit IP with guest curl
  --no-restart     Do not restart configd/cfprefsd/mDNSResponder
  --yes            Non-interactive confirmation for clear

Examples:
  zsh scripts/set_instance_proxy.sh vm.instances/phone-01 socks5://proxy.example:1080 --test
  zsh scripts/set_instance_proxy.sh 2224 http://proxy.example:8080 --vm-dir vm.instances/phone-01
  zsh scripts/set_instance_proxy.sh vm.instances/phone-01 clear --yes
  zsh scripts/set_instance_proxy.sh 2224 test
USAGE
}

say() { print -r -- "[*] $*"; }
ok() { print -r -- "[+] $*"; }
warn() { print -r -- "[!] $*"; }
die() { print -r -- "[-] $*" >&2; exit 1; }

if [[ "$TARGET" == "-h" || "$TARGET" == "--help" ]]; then
  usage
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-dir)
      [[ $# -ge 2 ]] || die "--vm-dir requires a value"
      VM_DIR_INPUT="$2"
      shift 2
      ;;
    --test)
      RUN_TEST=1
      shift
      ;;
    --no-restart)
      NO_RESTART=1
      shift
      ;;
    --yes|-y)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

[[ -n "$TARGET" && -n "$ACTION" ]] || { usage >&2; exit 1; }

shell_quote() {
  /usr/bin/python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

read_env_value() {
  local env_file="$1"
  local key="$2"
  [[ -f "$env_file" ]] || return 0
  awk -F= -v key="$key" '
    $1 == key {
      sub(/^[^=]*=/, "")
      gsub(/^"/, "")
      gsub(/"$/, "")
      print
      exit
    }
  ' "$env_file" 2>/dev/null || true
}

resolve_vm_dir_from_port() {
  local port="$1"
  find "${PROJECT_ROOT}/vm.instances" -maxdepth 2 -name instance.env -print 2>/dev/null \
    | while IFS= read -r env_file; do
        local value
        value="$(read_env_value "$env_file" SSH_LOCAL_PORT)"
        if [[ "$value" == "$port" ]]; then
          dirname "$env_file"
          return 0
        fi
      done \
    | head -1
}

resolve_target() {
  if [[ "$TARGET" == <-> ]]; then
    SSH_PORT="$TARGET"
    if [[ -n "$VM_DIR_INPUT" ]]; then
      VM_DIR_INPUT="${VM_DIR_INPUT:A}"
    else
      VM_DIR_INPUT="$(resolve_vm_dir_from_port "$SSH_PORT")"
    fi
  else
    VM_DIR_INPUT="${TARGET:A}"
    [[ -d "$VM_DIR_INPUT" ]] || die "VM dir not found: ${VM_DIR_INPUT}"
    local env_file="${VM_DIR_INPUT}/instance.env"
    SSH_PORT="$(read_env_value "$env_file" SSH_LOCAL_PORT)"
    [[ -n "$SSH_PORT" ]] || die "SSH_LOCAL_PORT not found in ${env_file}; start the instance first"
  fi

  [[ -n "$SSH_PORT" && "$SSH_PORT" == <-> ]] || die "invalid SSH port: ${SSH_PORT:-<empty>}"
}

guest_ssh() {
  local -a ssh_args
  ssh_args=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o PreferredAuthentications=password
    -o ConnectTimeout=8
    -p "$SSH_PORT"
    root@127.0.0.1
  )
  if (( $# == 0 )); then
    sshpass -p alpine ssh "${ssh_args[@]}"
  else
    sshpass -p alpine ssh "${ssh_args[@]}" "${GUEST_REMOTE_PATH}$1"
  fi
}

guest_upload() {
  local local_path="$1"
  local remote_path="$2"
  cat "$local_path" | guest_ssh "cat > $(shell_quote "$remote_path")"
}

update_instance_env_proxy() {
  local proxy_url="$1"
  local mode="$2"
  local host="$3"
  local port="$4"
  [[ -n "${VM_DIR_INPUT:-}" && -f "${VM_DIR_INPUT}/instance.env" ]] || return 0

  local env_file="${VM_DIR_INPUT}/instance.env"
  local tmp="${env_file}.tmp.$$"
  grep -v '^VPHONE_PROXY_' "$env_file" > "$tmp" || true
  if [[ -n "$proxy_url" ]]; then
    printf 'VPHONE_PROXY_URL=%q\n' "$proxy_url" >> "$tmp"
    printf 'VPHONE_PROXY_MODE=%q\n' "$mode" >> "$tmp"
    printf 'VPHONE_PROXY_HOST=%q\n' "$host" >> "$tmp"
    printf 'VPHONE_PROXY_PORT=%q\n' "$port" >> "$tmp"
  fi
  mv "$tmp" "$env_file"
}

patch_preferences() {
  local mode="$1"
  local proxy_url="$2"
  local original="$3"
  local modified="$4"
  local state="$5"

  /usr/bin/python3 - "$mode" "$proxy_url" "$original" "$modified" "$state" <<'PY'
from __future__ import annotations

import datetime as dt
import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

mode, proxy_url, original, modified, state_path = sys.argv[1:6]


def parse_proxy(url: str) -> dict:
    parsed = urlparse(url)
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https", "socks5", "socks5h", "socks"}:
        raise SystemExit(f"unsupported proxy scheme: {scheme}; expected http/https/socks5")
    if not parsed.hostname:
        raise SystemExit("proxy host is required")
    default_port = 8080 if scheme in {"http", "https"} else 1080
    port = parsed.port or default_port
    if not (1 <= int(port) <= 65535):
        raise SystemExit(f"invalid proxy port: {port}")
    return {
        "url": url,
        "scheme": scheme,
        "host": parsed.hostname,
        "port": int(port),
        "username": unquote(parsed.username or ""),
        "password": unquote(parsed.password or ""),
    }


def set_disabled(proxies: dict) -> None:
    for key in [
        "HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPUser", "HTTPPassword",
        "HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPSUser", "HTTPSPassword",
        "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKSUser", "SOCKSPassword",
        "ProxyAutoConfigEnable", "ProxyAutoConfigURLString",
    ]:
        proxies.pop(key, None)
    proxies["HTTPEnable"] = 0
    proxies["HTTPSEnable"] = 0
    proxies["SOCKSEnable"] = 0
    proxies["ProxyAutoConfigEnable"] = 0


def apply_proxy(proxies: dict, config: dict) -> None:
    set_disabled(proxies)
    scheme = config["scheme"]
    if scheme in {"http", "https"}:
        proxies["HTTPEnable"] = 1
        proxies["HTTPProxy"] = config["host"]
        proxies["HTTPPort"] = config["port"]
        proxies["HTTPSEnable"] = 1
        proxies["HTTPSProxy"] = config["host"]
        proxies["HTTPSPort"] = config["port"]
        if config["username"]:
            proxies["HTTPUser"] = config["username"]
            proxies["HTTPSUser"] = config["username"]
        if config["password"]:
            proxies["HTTPPassword"] = config["password"]
            proxies["HTTPSPassword"] = config["password"]
    else:
        proxies["SOCKSEnable"] = 1
        proxies["SOCKSProxy"] = config["host"]
        proxies["SOCKSPort"] = config["port"]
        if config["username"]:
            proxies["SOCKSUser"] = config["username"]
        if config["password"]:
            proxies["SOCKSPassword"] = config["password"]


with Path(original).open("rb") as f:
    prefs = plistlib.load(f)

if not isinstance(prefs, dict):
    raise SystemExit("SystemConfiguration preferences root is not a dictionary")

config = parse_proxy(proxy_url) if mode == "set" else None
patched = 0

network_services = prefs.get("NetworkServices")
if isinstance(network_services, dict):
    for service in network_services.values():
        if isinstance(service, dict):
            proxies = service.setdefault("Proxies", {})
            if isinstance(proxies, dict):
                apply_proxy(proxies, config) if config else set_disabled(proxies)
                patched += 1

sets = prefs.get("Sets")
if isinstance(sets, dict):
    for set_value in sets.values():
        services = (((set_value or {}).get("Network") or {}).get("Service") or {})
        if isinstance(services, dict):
            for service in services.values():
                if isinstance(service, dict):
                    proxies = service.setdefault("Proxies", {})
                    if isinstance(proxies, dict):
                        apply_proxy(proxies, config) if config else set_disabled(proxies)
                        patched += 1

if patched == 0:
    raise SystemExit("no NetworkServices/Sets proxy dictionaries found in preferences.plist")

with Path(modified).open("wb") as f:
    plistlib.dump(prefs, f, sort_keys=False)

state = {
    "enabled": mode == "set",
    "mode": config["scheme"] if config else "",
    "url": proxy_url if config else "",
    "host": config["host"] if config else "",
    "port": config["port"] if config else 0,
    "services_patched": patched,
    "applied_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "note": "SystemConfiguration proxy; not a TUN/VPN transparent proxy.",
}
Path(state_path).write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(state, ensure_ascii=False))
PY
}

test_exit_ip() {
  local proxy_url="${1:-}"
  local quoted_proxy=""
  [[ -n "$proxy_url" ]] && quoted_proxy="$(shell_quote "$proxy_url")"

  say "testing exit IP from guest via SSH localhost:${SSH_PORT}"
  guest_ssh "PROXY_URL=${quoted_proxy}; \
    CURL=''; \
    for c in /iosbinpack64/usr/bin/curl /var/jb/usr/bin/curl /usr/bin/curl curl; do \
      if command -v \"\$c\" >/dev/null 2>&1 || [ -x \"\$c\" ]; then CURL=\"\$c\"; break; fi; \
    done; \
    if [ -z \"\$CURL\" ]; then echo 'curl not found in guest'; exit 2; fi; \
    echo -n 'DIRECT_IP='; \"\$CURL\" -fsSL --connect-timeout 8 --max-time 20 https://api.ipify.org || true; echo; \
    if [ -n \"\$PROXY_URL\" ]; then \
      echo -n 'PROXY_IP='; \"\$CURL\" -fsSL --proxy \"\$PROXY_URL\" --connect-timeout 10 --max-time 25 https://api.ipify.org || true; echo; \
    fi"
}

resolve_target
command -v sshpass >/dev/null 2>&1 || die "sshpass not found; install with: brew install hudochenkov/sshpass/sshpass"

ACTION_L="${ACTION:l}"
case "$ACTION_L" in
  test|status)
    if [[ -z "${VM_DIR_INPUT:-}" && -n "$SSH_PORT" ]]; then
      VM_DIR_INPUT="$(resolve_vm_dir_from_port "$SSH_PORT")"
    fi
    proxy_url=""
    if [[ -n "${VM_DIR_INPUT:-}" && -f "${VM_DIR_INPUT}/instance.env" ]]; then
      proxy_url="$(read_env_value "${VM_DIR_INPUT}/instance.env" VPHONE_PROXY_URL)"
    fi
    test_exit_ip "$proxy_url"
    exit 0
    ;;
  clear|none|off|disable|disabled)
    MODE="clear"
    PROXY_URL=""
    ;;
  *)
    MODE="set"
    PROXY_URL="$ACTION"
    ;;
esac

if [[ "$MODE" == "clear" && "$YES" -eq 0 && -t 0 && -r /dev/tty ]]; then
  print -r -- "将清除实例代理配置：${VM_DIR_INPUT:-ssh:${SSH_PORT}}" > /dev/tty
  printf "继续？输入 yes: " > /dev/tty
  answer=""
  IFS= read -r answer < /dev/tty || answer=""
  [[ "$answer" == "yes" ]] || die "cancelled"
fi

TMPDIR_PROXY="$(mktemp -d "${TMPDIR:-/tmp}/vphone-proxy.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_PROXY" 2>/dev/null || true; }
trap cleanup EXIT

ORIGINAL="${TMPDIR_PROXY}/preferences.orig.plist"
MODIFIED="${TMPDIR_PROXY}/preferences.new.plist"
STATE="${TMPDIR_PROXY}/vphone_instance_proxy.json"

say "downloading SystemConfiguration preferences from SSH localhost:${SSH_PORT}"
guest_ssh "cat $(shell_quote "$REMOTE_PREF")" > "$ORIGINAL"

say "$([[ "$MODE" == "set" ]] && print -r -- "setting proxy: ${PROXY_URL}" || print -r -- "clearing proxy")"
STATE_JSON="$(patch_preferences "$MODE" "$PROXY_URL" "$ORIGINAL" "$MODIFIED" "$STATE")"
print -r -- "$STATE_JSON"

STAMP="$(date '+%Y%m%d-%H%M%S')"
REMOTE_TMP="/tmp/vphone_proxy_preferences.${STAMP}.plist"
REMOTE_STATE_TMP="/tmp/vphone_instance_proxy.${STAMP}.json"
guest_upload "$MODIFIED" "$REMOTE_TMP"
guest_upload "$STATE" "$REMOTE_STATE_TMP"

say "installing preferences and refreshing config daemons"
guest_ssh "set -e; \
  mkdir -p /var/mobile/Library/Preferences; \
  cp $(shell_quote "$REMOTE_PREF") $(shell_quote "${REMOTE_PREF}.vphone-proxy.bak.${STAMP}") 2>/dev/null || true; \
  cat $(shell_quote "$REMOTE_TMP") > $(shell_quote "$REMOTE_PREF"); \
  chmod 0644 $(shell_quote "$REMOTE_PREF") 2>/dev/null || true; \
  chown root:wheel $(shell_quote "$REMOTE_PREF") 2>/dev/null || true; \
  if [ $(shell_quote "$MODE") = clear ]; then rm -f $(shell_quote "$REMOTE_STATE"); else cat $(shell_quote "$REMOTE_STATE_TMP") > $(shell_quote "$REMOTE_STATE"); chown mobile:mobile $(shell_quote "$REMOTE_STATE") 2>/dev/null || true; fi; \
  rm -f $(shell_quote "$REMOTE_TMP") $(shell_quote "$REMOTE_STATE_TMP"); \
  if [ ${NO_RESTART} -eq 0 ]; then \
    (/iosbinpack64/usr/bin/killall configd || /usr/bin/killall configd || true) >/dev/null 2>&1; \
    (/iosbinpack64/usr/bin/killall cfprefsd || /usr/bin/killall cfprefsd || true) >/dev/null 2>&1; \
    (/iosbinpack64/usr/bin/killall mDNSResponder || /usr/bin/killall mDNSResponder || true) >/dev/null 2>&1; \
  fi"

if [[ "$MODE" == "set" ]]; then
  proxy_mode="$(/usr/bin/python3 - "$STATE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("mode", ""))
PY
)"
  proxy_host="$(/usr/bin/python3 - "$STATE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("host", ""))
PY
)"
  proxy_port="$(/usr/bin/python3 - "$STATE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("port", ""))
PY
)"
  update_instance_env_proxy "$PROXY_URL" "$proxy_mode" "$proxy_host" "$proxy_port"
  ok "proxy configured: ${PROXY_URL}"
else
  update_instance_env_proxy "" "" "" ""
  ok "proxy cleared"
fi

if (( RUN_TEST )); then
  test_exit_ip "$PROXY_URL"
fi
