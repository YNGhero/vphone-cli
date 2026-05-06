#!/bin/zsh
# app_profile_set.sh — create/update per-app device profile JSON used by VPhoneProfileTweak.

set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/app_profile_set.sh [实例名|VM目录|SSH端口] <bundle-id> [options]

Options:
  --from-json <file>       Upload an existing profile JSON
  --device-name <name>     UIDevice.name / MobileGestalt DeviceName
  --idfa <uuid>            ASIdentifierManager advertisingIdentifier
  --idfv <uuid>            UIDevice identifierForVendor
  --udid <uuid-or-string>  MobileGestalt UniqueDeviceID/OpaqueDeviceID
  --serial <value>         MobileGestalt SerialNumber
  --wifi <mac>             MobileGestalt WiFiAddress
  --bluetooth <mac>        MobileGestalt BluetoothAddress
  --product-type <value>   MobileGestalt ProductType, e.g. iPhone17,3
  --spoof-product-type     Spoof hw.machine/uname and MG ProductType (default)
  --no-spoof-product-type  Do not spoof low-level product identifier
  --model <value>          UIDevice model/localizedModel, default iPhone
  --system-version <ver>   UIDevice.systemVersion / MG ProductVersion
  --build-version <ver>    MG BuildVersion
  --locale <id>            NSLocale currentLocale; default random English locale
  --languages <csv>        NSLocale preferredLanguages; default en
  --timezone <name>        NSTimeZone; default timezone matching random English locale
  --audit-reads            Log hooked Objective-C API reads to /tmp/vphone_profile_tweak.log
  --audit-mobilegestalt    Experimental: log MGCopyAnswer keys without spoofing values
  --hook-mobilegestalt     Spoof MGCopyAnswer values; higher compatibility risk
  --disabled               Write enabled=false

Examples:
  zsh scripts/app_profile_set.sh instagram-01 com.burbn.instagram
  zsh scripts/app_profile_set.sh vm.instances/instagram-01 com.burbn.instagram --audit-reads
  zsh scripts/app_profile_set.sh 2224 com.burbn.instagram
  zsh scripts/app_profile_set.sh 2224 com.burbn.instagram --device-name 'iPhone' --locale en_US --languages en --timezone America/Los_Angeles
  zsh scripts/app_profile_set.sh 2224 com.burbn.instagram --audit-reads
USAGE
}

SSH_PORT="${SSH_LOCAL_PORT:-2224}"
BUNDLE_ID=""
FROM_JSON=""
ENABLED=1
HOOK_MOBILEGESTALT=0
SPOOF_PRODUCT_TYPE=1
AUDIT_READS=0
AUDIT_MOBILEGESTALT=0

typeset -A OPTS
args=("$@")
if (( ${#args[@]} > 0 )); then
  if [[ "${args[1]}" == <-> ]]; then
    SSH_PORT="${args[1]}"
    args=("${args[@]:1}")
  elif vpa_resolve_vm_dir "${args[1]}" >/dev/null 2>&1; then
    SSH_PORT="$(vpa_resolve_ssh_port "${args[1]}")"
    args=("${args[@]:1}")
  fi
fi

while (( ${#args[@]} > 0 )); do
  case "${args[1]}" in
    -h|--help) usage; exit 0 ;;
    --from-json) (( ${#args[@]} >= 2 )) || vpa_die "--from-json requires a file"; FROM_JSON="${args[2]}"; args=("${args[@]:2}") ;;
    --from-json=*) FROM_JSON="${args[1]#--from-json=}"; args=("${args[@]:1}") ;;
    --disabled) ENABLED=0; args=("${args[@]:1}") ;;
    --hook-mobilegestalt) HOOK_MOBILEGESTALT=1; args=("${args[@]:1}") ;;
    --spoof-product-type) SPOOF_PRODUCT_TYPE=1; args=("${args[@]:1}") ;;
    --no-spoof-product-type) SPOOF_PRODUCT_TYPE=0; args=("${args[@]:1}") ;;
    --audit-reads) AUDIT_READS=1; args=("${args[@]:1}") ;;
    --audit-mobilegestalt) AUDIT_MOBILEGESTALT=1; args=("${args[@]:1}") ;;
    --device-name|--idfa|--idfv|--udid|--serial|--wifi|--bluetooth|--product-type|--model|--system-version|--build-version|--locale|--languages|--timezone)
      (( ${#args[@]} >= 2 )) || vpa_die "${args[1]} requires a value"
      key="${args[1]#--}"
      OPTS[$key]="${args[2]}"
      args=("${args[@]:2}") ;;
    --*) vpa_die "unknown option: ${args[1]}" ;;
    *)
      if [[ -z "$BUNDLE_ID" ]]; then BUNDLE_ID="${args[1]}"; else vpa_die "unexpected argument: ${args[1]}"; fi
      args=("${args[@]:1}") ;;
  esac
done

[[ "$SSH_PORT" == <-> ]] || vpa_die "SSH_PORT must be numeric: $SSH_PORT"
vpa_validate_bundle_id "$BUNDLE_ID"
vpa_require_tools

TMP_JSON="$(mktemp -t vphone-app-profile.XXXXXX).json"
if [[ -n "$FROM_JSON" ]]; then
  FROM_JSON="${FROM_JSON:A}"
  [[ -f "$FROM_JSON" ]] || vpa_die "profile JSON not found: $FROM_JSON"
  cp "$FROM_JSON" "$TMP_JSON"
else
  python3 - "$BUNDLE_ID" "$ENABLED" \
    "${OPTS[device-name]:-}" "${OPTS[idfa]:-}" "${OPTS[idfv]:-}" "${OPTS[udid]:-}" \
    "${OPTS[serial]:-}" "${OPTS[wifi]:-}" "${OPTS[bluetooth]:-}" "${OPTS[product-type]:-}" \
    "${OPTS[model]:-}" "${OPTS[system-version]:-}" "${OPTS[build-version]:-}" \
    "${OPTS[locale]:-}" "${OPTS[languages]:-}" "${OPTS[timezone]:-}" "$HOOK_MOBILEGESTALT" \
    "$SPOOF_PRODUCT_TYPE" "$AUDIT_READS" "$AUDIT_MOBILEGESTALT" > "$TMP_JSON" <<'PY'
import json, random, sys, time, uuid
bundle, enabled = sys.argv[1], bool(int(sys.argv[2]))
(device_name, idfa, idfv, udid, serial, wifi, bt, product_type, model,
 system_version, build_version, locale, languages, timezone, hook_mg,
 spoof_product_type, audit_reads, audit_mg) = sys.argv[3:]

def mac():
    return '02:%02x:%02x:%02x:%02x:%02x' % tuple(random.randrange(256) for _ in range(5))

def uuid_s(v=''):
    if v:
        return str(uuid.UUID(v)).upper()
    return str(uuid.uuid4()).upper()

english_regions = [
    ('en_US', 'America/New_York'),
    ('en_US', 'America/Chicago'),
    ('en_US', 'America/Denver'),
    ('en_US', 'America/Los_Angeles'),
    ('en_US', 'America/Phoenix'),
    ('en_US', 'Pacific/Honolulu'),
    ('en_CA', 'America/Toronto'),
    ('en_CA', 'America/Vancouver'),
    ('en_GB', 'Europe/London'),
    ('en_IE', 'Europe/Dublin'),
    ('en_AU', 'Australia/Sydney'),
    ('en_AU', 'Australia/Melbourne'),
    ('en_NZ', 'Pacific/Auckland'),
]
default_locale, default_timezone = random.choice(english_regions)
langs = [x.strip() for x in languages.split(',') if x.strip()] if languages else ['en']
locale = locale or default_locale
timezone = timezone or default_timezone
udid_value = udid or uuid_s()
profile = {
    'enabled': enabled,
    'bundle_id': bundle,
    'idfa': uuid_s(idfa),
    'idfv': uuid_s(idfv),
    'udid': udid_value,
    'oudid': udid_value,
    'serial': serial or f'VP{int(time.time())}{random.randrange(1000,9999)}',
    'wifiAddress': wifi or mac(),
    'bluetoothAddress': bt or mac(),
    'deviceName': device_name or 'iPhone',
    'model': model or 'iPhone',
    'localizedModel': model or 'iPhone',
    'productType': product_type or 'iPhone17,3',
    'spoofProductType': bool(int(spoof_product_type)),
    'systemName': 'iOS',
    'systemVersion': system_version,
    'buildVersion': build_version,
    'localeIdentifier': locale,
    'preferredLanguages': langs,
    'timeZone': timezone,
    'advertisingTrackingEnabled': True,
    'trackingAuthorized': True,
    'hookMobileGestalt': bool(int(hook_mg)),
    'auditReads': bool(int(audit_reads)),
    'auditMobileGestalt': bool(int(audit_mg)),
    'created_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
}
json.dump(profile, sys.stdout, indent=2, ensure_ascii=False)
print()
PY
fi

REMOTE_DIR="/var/mobile/vphone_app_profiles"
REMOTE_JSON="${REMOTE_DIR}/${BUNDLE_ID}.json"
qdir="$(vpa_quote_args "$REMOTE_DIR")"
qjson="$(vpa_quote_args "$REMOTE_JSON")"
vpa_say "upload profile: ${BUNDLE_ID} -> localhost:${SSH_PORT}"
vpa_ssh "$SSH_PORT" "mkdir -p ${qdir}; cat > ${qjson}; chown mobile:mobile ${qjson} 2>/dev/null || true; chmod 0644 ${qjson}" < "$TMP_JSON"
rm -f "$TMP_JSON"
vpa_ok "profile updated: ${REMOTE_JSON}"
print -r -- "重启/重开目标 App 后生效。"
