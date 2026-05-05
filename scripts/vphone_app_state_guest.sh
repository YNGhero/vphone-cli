#!/usr/bin/env bash
# Guest-side helper for per-app backup/new-device/restore.
# This script is streamed into the iOS VM over SSH by host scripts.

set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/var/jb/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/sbin:/usr/sbin:/iosbinpack64/sbin:/iosbinpack64/usr/sbin:$PATH

ACTION="${1:-}"
BUNDLE_ID="${2:-}"
STAGE="${3:-}"

say() { printf '[*] %s\n' "$*" >&2; }
ok() { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[-] %s\n' "$*" >&2; exit 1; }

[ -n "$ACTION" ] || die "missing action"
[ -n "$BUNDLE_ID" ] || die "missing bundle id"
[ -n "$STAGE" ] || die "missing stage path"
case "$BUNDLE_ID" in
  *[!A-Za-z0-9._-]*|'') die "invalid bundle id: $BUNDLE_ID" ;;
esac
case "$STAGE" in
  /var/mobile/Library/vphone_app_state/staging/*|/tmp/vphone_app_state/*) ;;
  *) die "unsafe stage path: $STAGE" ;;
esac

FM="/usr/bin/find"
[ -x "$FM" ] || FM="find"
MCM_METADATA_NAME=".com.apple.mobile_container_manager.metadata.plist"

xml_unescape_basic() {
  sed \
    -e 's/&lt;/</g' \
    -e 's/&gt;/>/g' \
    -e 's/&quot;/"/g' \
    -e "s/&apos;/'/g" \
    -e 's/&amp;/\&/g'
}

xml_line_string_value() {
  # Extract the first <string>...</string> value from a single XML line.
  printf '%s\n' "$1" | sed -n 's/^.*<string>\(.*\)<\/string>.*$/\1/p' | xml_unescape_basic
}

xml_string_after_key() {
  local key="$1" file="$2" line seen=0
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    if [ "$seen" = 0 ]; then
      case "$line" in
        *"<key>${key}</key>"*)
          seen=1
          case "$line" in
            *"<string>"*"</string>"*) ;;
            *) continue ;;
          esac
          ;;
        *) continue ;;
      esac
    fi
    case "$line" in
      *"<string>"*"</string>"*)
        xml_line_string_value "$line"
        return 0
        ;;
      *"<key>"*"</key>"*)
        # We reached the next key without seeing a string value.
        [ "$seen" = 1 ] && return 1
        ;;
    esac
  done < "$file"
  return 1
}

plist_contains_string() {
  local needle="$1" file="$2"
  [ -f "$file" ] || return 1
  grep -a -F -q "$needle" "$file" 2>/dev/null
}

plist_value() {
  local key="$1" file="$2" out=""
  [ -f "$file" ] || return 1
  if command -v plutil >/dev/null 2>&1; then
    out="$(plutil -extract "$key" raw -o - "$file" 2>/dev/null || true)"
    if [ -n "$out" ] && [ "$out" != "(null)" ]; then printf '%s\n' "$out"; return 0; fi
    out="$(plutil -convert xml1 -o /tmp/vphone-plist.$$.xml "$file" 2>/dev/null && xml_string_after_key "$key" /tmp/vphone-plist.$$.xml || true)"
    rm -f /tmp/vphone-plist.$$.xml 2>/dev/null || true
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  fi
  out="$(xml_string_after_key "$key" "$file" 2>/dev/null || true)"
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  return 1
}

shell_quote() {
  # single-quote for manifest.env
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\''/g"
  printf "'"
}

write_kv() {
  local key="$1" val="$2" file="$3"
  printf '%s=' "$key" >> "$file"
  shell_quote "$val" >> "$file"
  printf '\n' >> "$file"
}

safe_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

container_dir_for_metadata() {
  local p
  p="$(dirname "$1")"
  case "$p" in
    /private/var/*) p="${p#/private}" ;;
  esac
  printf '%s\n' "$p"
}

copy_dir_contents() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xpf -)
}

clean_dir_contents() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || { mkdir -p "$dir"; return 0; }
  # Do not expand globs. Use find to avoid deleting the container itself.
  # Preserve the MobileContainerManager metadata file; deleting it breaks future
  # bundle-id -> container resolution for data and App Group containers.
  find "$dir" -mindepth 1 -maxdepth 1 ! -name "$MCM_METADATA_NAME" -exec rm -rf {} + 2>/dev/null || true
}

restore_dir_contents() {
  local src="$1" dst="$2" saved_meta=""
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  if [ -f "$dst/$MCM_METADATA_NAME" ]; then
    saved_meta="/tmp/vphone-mcm-meta.$$.plist"
    cp -p "$dst/$MCM_METADATA_NAME" "$saved_meta" 2>/dev/null || saved_meta=""
  fi
  clean_dir_contents "$dst"
  (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xpf -)
  # If the current container already had metadata, keep the current metadata
  # instead of overwriting it with metadata from a backup made on another UUID.
  if [ -n "$saved_meta" ] && [ -f "$saved_meta" ]; then
    cp -p "$saved_meta" "$dst/$MCM_METADATA_NAME" 2>/dev/null || true
    rm -f "$saved_meta" 2>/dev/null || true
  fi
}

resolve_app() {
  APP_BUNDLE_PATH=""
  APP_INFO_PLIST=""
  APP_EXECUTABLE=""
  APP_EXECUTABLE_PATH=""
  APP_DISPLAY_NAME=""
  APP_DATA_CONTAINER=""
  APP_PREF_PATH="/var/mobile/Library/Preferences/${BUNDLE_ID}.plist"
  APP_PREF_BYHOST_DIR="/var/mobile/Library/Preferences/ByHost"

  local info id exec name meta base
  while IFS= read -r info; do
    id="$(plist_value CFBundleIdentifier "$info" || true)"
    if [ "$id" = "$BUNDLE_ID" ] || { [ -z "$id" ] && plist_contains_string "$BUNDLE_ID" "$info"; }; then
      APP_INFO_PLIST="$info"
      APP_BUNDLE_PATH="$(dirname "$info")"
      exec="$(plist_value CFBundleExecutable "$info" || true)"
      name="$(plist_value CFBundleDisplayName "$info" || plist_value CFBundleName "$info" || basename "$APP_BUNDLE_PATH" .app || true)"
      if [ -z "$exec" ]; then
        base="$(basename "$APP_BUNDLE_PATH" .app)"
        [ -f "$APP_BUNDLE_PATH/$base" ] && exec="$base"
      fi
      APP_EXECUTABLE="$exec"
      [ -n "$exec" ] && APP_EXECUTABLE_PATH="$APP_BUNDLE_PATH/$exec"
      APP_DISPLAY_NAME="$name"
      break
    fi
  done < <(find /var/containers/Bundle/Application /private/var/containers/Bundle/Application -maxdepth 3 -path '*.app/Info.plist' -type f 2>/dev/null | sort -u)

  [ -n "$APP_BUNDLE_PATH" ] || die "app bundle not found for $BUNDLE_ID"

  while IFS= read -r meta; do
    id="$(plist_value MCMMetadataIdentifier "$meta" || true)"
    if [ "$id" = "$BUNDLE_ID" ] || { [ -z "$id" ] && plist_contains_string "$BUNDLE_ID" "$meta"; }; then
      APP_DATA_CONTAINER="$(container_dir_for_metadata "$meta")"
      break
    fi
  done < <(find /var/mobile/Containers/Data/Application /private/var/mobile/Containers/Data/Application -maxdepth 2 -name .com.apple.mobile_container_manager.metadata.plist -type f 2>/dev/null | sort -u)

  if [ -z "$APP_DATA_CONTAINER" ] && [ "${RESOLVE_APP_WARN_MISSING_DATA:-1}" = "1" ]; then
    warn "data container not found for $BUNDLE_ID; restore/new-device will create no app data container"
  fi
}

entitlements_xml() {
  local exe="$1"
  [ -n "$exe" ] && [ -f "$exe" ] || return 0
  if command -v ldid >/dev/null 2>&1; then
    ldid -e "$exe" 2>/dev/null || true
  elif [ -x /var/jb/usr/bin/ldid ]; then
    /var/jb/usr/bin/ldid -e "$exe" 2>/dev/null || true
  fi
}

extract_array_after_key() {
  local key="$1" file="$2" line inarr=0 val
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    if [ "$inarr" = 0 ]; then
      case "$line" in
        *"<key>${key}</key>"*) inarr=1 ;;
      esac
      continue
    fi
    case "$line" in
      *"</array>"*) break ;;
      *"<string>"*"</string>"*)
        val="$(xml_line_string_value "$line")"
        [ -n "$val" ] && printf '%s\n' "$val"
        ;;
    esac
  done < "$file" | sort -u
}

extract_string_after_key() {
  local key="$1" file="$2"
  xml_string_after_key "$key" "$file" || true
}

resolve_groups_and_keychain() {
  GROUPS_FILE="$STAGE/group_paths.tsv"
  APP_GROUP_IDS_FILE="$STAGE/app_group_ids.txt"
  ACCESS_GROUPS_FILE="$STAGE/keychain_access_groups.txt"
  ENT_FILE="$STAGE/entitlements.plist"
  : > "$GROUPS_FILE"
  : > "$APP_GROUP_IDS_FILE"
  : > "$ACCESS_GROUPS_FILE"
  entitlements_xml "$APP_EXECUTABLE_PATH" > "$ENT_FILE" || true

  if [ -s "$ENT_FILE" ]; then
    extract_array_after_key "com.apple.security.application-groups" "$ENT_FILE" >> "$APP_GROUP_IDS_FILE" || true
    extract_array_after_key "com.apple.security.system-groups" "$ENT_FILE" >> "$APP_GROUP_IDS_FILE" || true
    extract_array_after_key "keychain-access-groups" "$ENT_FILE" >> "$ACCESS_GROUPS_FILE" || true
    extract_string_after_key "application-identifier" "$ENT_FILE" >> "$ACCESS_GROUPS_FILE" || true
  fi
  # Heuristic fallback for TrollStore/rootless apps where groups may not dump cleanly.
  find /var/mobile/Containers/Shared/AppGroup /private/var/mobile/Containers/Shared/AppGroup -maxdepth 2 -name .com.apple.mobile_container_manager.metadata.plist -type f 2>/dev/null | sort -u | while IFS= read -r meta; do
    local gid path matched=0 wanted
    gid="$(plist_value MCMMetadataIdentifier "$meta" || true)"
    path="$(container_dir_for_metadata "$meta")"
    while IFS= read -r wanted; do
      [ -n "$wanted" ] || continue
      if [ "$gid" = "$wanted" ] || { [ -z "$gid" ] && plist_contains_string "$wanted" "$meta"; }; then
        gid="$wanted"
        matched=1
      fi
    done < "$APP_GROUP_IDS_FILE"
    case "$gid" in
      *"$BUNDLE_ID"*) matched=1 ;;
    esac
    if [ "$matched" = 0 ] && plist_contains_string "$BUNDLE_ID" "$meta"; then
      gid="$(grep -a -E -o 'group\.[A-Za-z0-9._-]+' "$meta" 2>/dev/null | head -n 1 || true)"
      [ -n "$gid" ] && matched=1
    fi
    [ -n "$gid" ] || continue
    if [ "$matched" = 1 ]; then
      printf '%s\t%s\t%s\n' "$gid" "$path" "$(safe_component "$gid")" >> "$GROUPS_FILE"
      printf '%s\n' "$gid" >> "$APP_GROUP_IDS_FILE"
    fi
  done
  sort -u "$APP_GROUP_IDS_FILE" -o "$APP_GROUP_IDS_FILE" 2>/dev/null || true
  sort -u "$ACCESS_GROUPS_FILE" -o "$ACCESS_GROUPS_FILE" 2>/dev/null || true
  sort -u "$GROUPS_FILE" -o "$GROUPS_FILE" 2>/dev/null || true
}

sql_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/''/g"
  printf "'"
}

sql_in_clause_from_file() {
  local file="$1" first=1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" = 0 ]; then printf ','; fi
    sql_quote "$line"
    first=0
  done < "$file"
}

backup_keychain() {
  local out="$STAGE/keychain/keychain_app.sqlite"
  local db="/var/Keychains/keychain-2.db"
  mkdir -p "$STAGE/keychain"
  [ -f "$db" ] || { warn "keychain db not found: $db"; return 0; }
  [ -s "$ACCESS_GROUPS_FILE" ] || { warn "no keychain access groups found; keychain backup skipped"; return 0; }
  command -v sqlite3 >/dev/null 2>&1 || { warn "sqlite3 not found; keychain backup skipped"; return 0; }
  local inclause
  inclause="$(sql_in_clause_from_file "$ACCESS_GROUPS_FILE")"
  [ -n "$inclause" ] || return 0
  rm -f "$out"
  sqlite3 "$db" <<SQL || warn "keychain selected backup failed"
ATTACH '$out' AS out;
CREATE TABLE out.genp AS SELECT * FROM main.genp WHERE agrp IN ($inclause);
CREATE TABLE out.cert AS SELECT * FROM main.cert WHERE agrp IN ($inclause);
CREATE TABLE out.keys AS SELECT * FROM main.keys WHERE agrp IN ($inclause);
CREATE TABLE out.inet AS SELECT * FROM main.inet WHERE agrp IN ($inclause);
DETACH out;
SQL
  if [ -f "$out" ]; then
    local size=""
    size="$(du -h "$out" 2>/dev/null | sed 's/[[:space:]].*$//' | head -n 1 || true)"
    if [ -n "$size" ]; then
      ok "keychain backup saved: $size"
    else
      ok "keychain backup saved: $out"
    fi
  fi
}

clean_keychain() {
  local db="/var/Keychains/keychain-2.db"
  [ -f "$db" ] || return 0
  [ -s "$ACCESS_GROUPS_FILE" ] || { warn "no keychain access groups found; keychain clean skipped"; return 0; }
  command -v sqlite3 >/dev/null 2>&1 || { warn "sqlite3 not found; keychain clean skipped"; return 0; }
  local inclause
  inclause="$(sql_in_clause_from_file "$ACCESS_GROUPS_FILE")"
  [ -n "$inclause" ] || return 0
  cp "$db" "/tmp/keychain-2.vphone-appstate.$$.bak" 2>/dev/null || true
  sqlite3 "$db" >/dev/null <<SQL || warn "keychain clean failed"
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;
DELETE FROM genp WHERE agrp IN ($inclause);
DELETE FROM cert WHERE agrp IN ($inclause);
DELETE FROM keys WHERE agrp IN ($inclause);
DELETE FROM inet WHERE agrp IN ($inclause);
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
}

restore_keychain() {
  local bak="$STAGE/keychain/keychain_app.sqlite"
  local db="/var/Keychains/keychain-2.db"
  [ -f "$bak" ] || { warn "backup has no selected keychain sqlite; keychain restore skipped"; return 0; }
  [ -f "$db" ] || { warn "keychain db not found: $db"; return 0; }
  [ -s "$ACCESS_GROUPS_FILE" ] || { warn "no keychain access groups found; keychain restore skipped"; return 0; }
  command -v sqlite3 >/dev/null 2>&1 || { warn "sqlite3 not found; keychain restore skipped"; return 0; }
  local inclause table
  inclause="$(sql_in_clause_from_file "$ACCESS_GROUPS_FILE")"
  [ -n "$inclause" ] || return 0
  cp "$db" "/tmp/keychain-2.vphone-appstate-restore.$$.bak" 2>/dev/null || true
  sqlite3 "$db" "PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE; DELETE FROM genp WHERE agrp IN ($inclause); DELETE FROM cert WHERE agrp IN ($inclause); DELETE FROM keys WHERE agrp IN ($inclause); DELETE FROM inet WHERE agrp IN ($inclause); COMMIT;" || warn "keychain pre-clean failed"
  for table in genp cert keys inet; do
    if sqlite3 "$bak" ".tables" | tr ' ' '\n' | grep -qx "$table"; then
      sqlite3 "$db" "ATTACH '$bak' AS bak; INSERT INTO main.$table SELECT * FROM bak.$table; DETACH bak;" || warn "keychain table restore failed: $table"
    fi
  done
  sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
}

restart_state_services() {
  killall -9 cfprefsd 2>/dev/null || true
  launchctl kickstart -k system/com.apple.securityd 2>/dev/null || killall securityd 2>/dev/null || true
}

clean_pasteboard() {
  killall pasteboardd pasted 2>/dev/null || true
  rm -rf /var/mobile/Library/Caches/com.apple.UIKit.pboard/* /var/mobile/Library/Caches/com.apple.Pasteboard/* 2>/dev/null || true
  launchctl kickstart -k system/com.apple.UIKit.pasteboardd 2>/dev/null || true
  launchctl kickstart -k system/com.apple.pasteboard.pasted 2>/dev/null || true
}

terminate_app() {
  if [ -n "${APP_EXECUTABLE:-}" ]; then
    killall "$APP_EXECUTABLE" 2>/dev/null || true
    killall -9 "$APP_EXECUTABLE" 2>/dev/null || true
  fi
}

relaunch_app() {
  local launched=0
  if command -v open >/dev/null 2>&1; then
    open -b "$BUNDLE_ID" >/dev/null 2>&1 && launched=1 || true
  fi
  if [ "$launched" = 0 ] && command -v uiopen >/dev/null 2>&1; then
    uiopen --bundleid "$BUNDLE_ID" >/dev/null 2>&1 && launched=1 || true
  fi
  if [ "$launched" = 1 ]; then ok "relaunch requested: $BUNDLE_ID"; else warn "relaunch not available; open app from GUI manually"; fi
}

respring_if_needed() {
  local flag="$1"
  if [ "$flag" = "1" ]; then
    warn "Restarting SpringBoard"
    killall SpringBoard 2>/dev/null || true
  fi
}

generate_profile() {
  local dir="/var/mobile/vphone_app_profiles"
  local out="$dir/${BUNDLE_ID}.json"
  mkdir -p "$dir"
  random_uuid() {
    local h
    h="$(hexdump -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null || true)"
    if [ "${#h}" -lt 32 ]; then
      h="$(printf '%08x%08x%08x%08x' "$RANDOM$RANDOM" "$RANDOM$RANDOM" "$RANDOM$RANDOM" "$RANDOM$RANDOM" | tr -cd '0-9a-f' | head -c 32)"
    fi
    h="$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')"
    printf '%s-%s-4%s-8%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  }
  local idfa idfv oudid serial wifi bt name product_type model system_name system_version build_version locale_identifier time_zone
  idfa="$(random_uuid)"
  idfv="$(random_uuid)"
  oudid="$(random_uuid)"
  serial="VP$(date +%s)$(printf '%04d' $((RANDOM % 10000)))"
  wifi="$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
  bt="$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
  name="iPhone"
  product_type="${VPHONE_PROFILE_PRODUCT_TYPE:-iPhone17,3}"
  model="${VPHONE_PROFILE_MODEL:-iPhone}"
  system_name="${VPHONE_PROFILE_SYSTEM_NAME:-iOS}"
  system_version="${VPHONE_PROFILE_SYSTEM_VERSION:-}"
  build_version="${VPHONE_PROFILE_BUILD_VERSION:-}"
  locale_identifier="${VPHONE_PROFILE_LOCALE:-}"
  time_zone="${VPHONE_PROFILE_TIMEZONE:-}"
  cat > "$out" <<JSON
{
  "enabled": true,
  "bundle_id": "$BUNDLE_ID",
  "idfa": "$idfa",
  "idfv": "$idfv",
  "udid": "$oudid",
  "oudid": "$oudid",
  "serial": "$serial",
  "wifiAddress": "$wifi",
  "bluetoothAddress": "$bt",
  "deviceName": "$name",
  "model": "$model",
  "localizedModel": "$model",
  "productType": "$product_type",
  "systemName": "$system_name",
  "systemVersion": "$system_version",
  "buildVersion": "$build_version",
  "localeIdentifier": "$locale_identifier",
  "preferredLanguages": [],
  "timeZone": "$time_zone",
  "advertisingTrackingEnabled": true,
  "trackingAuthorized": true,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  chown mobile:mobile "$out" 2>/dev/null || true
  ok "profile generated: $out"
}

write_manifest() {
  local manifest="$STAGE/manifest.env"
  : > "$manifest"
  write_kv BUNDLE_ID "$BUNDLE_ID" "$manifest"
  write_kv INSTANCE_NAME "${APP_BACKUP_INSTANCE_NAME:-}" "$manifest"
  write_kv DISPLAY_NAME "${APP_DISPLAY_NAME:-}" "$manifest"
  write_kv APP_BUNDLE_PATH "${APP_BUNDLE_PATH:-}" "$manifest"
  write_kv APP_EXECUTABLE "${APP_EXECUTABLE:-}" "$manifest"
  write_kv APP_DATA_CONTAINER "${APP_DATA_CONTAINER:-}" "$manifest"
  write_kv APP_PREF_PATH "${APP_PREF_PATH:-}" "$manifest"
  write_kv CREATED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$manifest"
  {
    echo "Bundle: $BUNDLE_ID"
    echo "Instance: ${APP_BACKUP_INSTANCE_NAME:-}"
    echo "Name: ${APP_DISPLAY_NAME:-}"
    echo "App bundle: ${APP_BUNDLE_PATH:-}"
    echo "Data: ${APP_DATA_CONTAINER:-}"
    echo "Preferences: ${APP_PREF_PATH:-}"
    echo "Groups:"
    cat "$GROUPS_FILE" 2>/dev/null || true
    echo "Keychain access groups:"
    cat "$ACCESS_GROUPS_FILE" 2>/dev/null || true
  } > "$STAGE/summary.txt"
}

backup_action() {
  local backup_name="${4:-}"
  APP_BACKUP_INSTANCE_NAME="${5:-}"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  resolve_app
  resolve_groups_and_keychain
  terminate_app
  sleep 1
  write_manifest

  if [ -d "$APP_DATA_CONTAINER" ]; then
    say "copy app data: $APP_DATA_CONTAINER"
    copy_dir_contents "$APP_DATA_CONTAINER" "$STAGE/app_data"
  fi

  if [ -f "$APP_PREF_PATH" ]; then
    mkdir -p "$STAGE/preferences"
    cp -p "$APP_PREF_PATH" "$STAGE/preferences/${BUNDLE_ID}.plist" 2>/dev/null || cp "$APP_PREF_PATH" "$STAGE/preferences/${BUNDLE_ID}.plist"
  fi
  if [ -d "$APP_PREF_BYHOST_DIR" ]; then
    mkdir -p "$STAGE/preferences/ByHost"
    find "$APP_PREF_BYHOST_DIR" -maxdepth 1 -type f -name "${BUNDLE_ID}.*.plist" -exec cp -p {} "$STAGE/preferences/ByHost/" \; 2>/dev/null || true
  fi

  mkdir -p "$STAGE/group_containers"
  while IFS=$'\t' read -r gid gpath gsafe; do
    [ -n "$gid" ] || continue
    if [ -d "$gpath" ]; then
      say "copy group container: $gid -> $gpath"
      copy_dir_contents "$gpath" "$STAGE/group_containers/$gsafe"
    fi
  done < "$GROUPS_FILE"

  if [ -f "/var/mobile/vphone_app_profiles/${BUNDLE_ID}.json" ]; then
    mkdir -p "$STAGE/profile"
    cp -p "/var/mobile/vphone_app_profiles/${BUNDLE_ID}.json" "$STAGE/profile/profile.json" 2>/dev/null || true
  fi

  backup_keychain
  chown -R mobile:mobile "$STAGE" 2>/dev/null || true
  ok "backup staged: $STAGE"
  printf '%s\n' "$STAGE"
}

prepare_for_new_or_restore() {
  resolve_app
  mkdir -p "$STAGE"
  resolve_groups_and_keychain
  terminate_app
  sleep 1
  if [ -n "$APP_DATA_CONTAINER" ]; then
    say "clean app data: $APP_DATA_CONTAINER"
    clean_dir_contents "$APP_DATA_CONTAINER"
  fi
  while IFS=$'\t' read -r gid gpath gsafe; do
    [ -n "$gid" ] || continue
    if [ -d "$gpath" ]; then
      say "clean group container: $gid -> $gpath"
      clean_dir_contents "$gpath"
    fi
  done < "$GROUPS_FILE"
  rm -f "$APP_PREF_PATH" "$APP_PREF_PATH.lockfile" 2>/dev/null || true
  find "$APP_PREF_BYHOST_DIR" -maxdepth 1 -type f -name "${BUNDLE_ID}.*.plist" -delete 2>/dev/null || true
  clean_keychain
}

new_action() {
  local clean_pb="${4:-1}"
  local relaunch="${5:-1}"
  local respring="${6:-0}"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  prepare_for_new_or_restore
  generate_profile
  [ "$clean_pb" = "1" ] && clean_pasteboard
  restart_state_services
  respring_if_needed "$respring"
  [ "$relaunch" = "1" ] && relaunch_app
  ok "new-device completed for $BUNDLE_ID"
}

find_current_group_path() {
  local gid="$1" meta id
  while IFS= read -r meta; do
    id="$(plist_value MCMMetadataIdentifier "$meta" || true)"
    if [ "$id" = "$gid" ] || { [ -z "$id" ] && plist_contains_string "$gid" "$meta"; }; then container_dir_for_metadata "$meta"; return 0; fi
  done < <(find /var/mobile/Containers/Shared/AppGroup /private/var/mobile/Containers/Shared/AppGroup -maxdepth 2 -name .com.apple.mobile_container_manager.metadata.plist -type f 2>/dev/null | sort -u)
  return 1
}

restore_action() {
  local relaunch="${4:-1}"
  local respring="${5:-0}"
  [ -f "$STAGE/manifest.env" ] || die "backup manifest missing in stage: $STAGE/manifest.env"

  # Preserve backup metadata before prepare_for_new_or_restore regenerates the
  # current-app metadata files under the same stage directory.
  local BACKUP_GROUPS_FILE="$STAGE/backup_group_paths.tsv"
  local BACKUP_ACCESS_GROUPS_FILE="$STAGE/backup_keychain_access_groups.txt"
  [ -f "$STAGE/group_paths.tsv" ] && cp "$STAGE/group_paths.tsv" "$BACKUP_GROUPS_FILE" || : > "$BACKUP_GROUPS_FILE"
  [ -f "$STAGE/keychain_access_groups.txt" ] && cp "$STAGE/keychain_access_groups.txt" "$BACKUP_ACCESS_GROUPS_FILE" || : > "$BACKUP_ACCESS_GROUPS_FILE"

  # shellcheck disable=SC1090
  . "$STAGE/manifest.env"
  local BACKUP_APP_DATA_CONTAINER="${APP_DATA_CONTAINER:-}"
  [ "${BUNDLE_ID:-}" = "$2" ] || die "backup bundle mismatch: archive=${BUNDLE_ID:-?}, requested=$2"
  BUNDLE_ID="$2"
  local old_resolve_warn="${RESOLVE_APP_WARN_MISSING_DATA:-1}"
  RESOLVE_APP_WARN_MISSING_DATA=0
  prepare_for_new_or_restore
  RESOLVE_APP_WARN_MISSING_DATA="$old_resolve_warn"

  if [ -z "$APP_DATA_CONTAINER" ] && [ -n "$BACKUP_APP_DATA_CONTAINER" ] && [ -d "$BACKUP_APP_DATA_CONTAINER" ]; then
    APP_DATA_CONTAINER="$BACKUP_APP_DATA_CONTAINER"
    warn "current data container metadata is missing; using backup manifest path: $APP_DATA_CONTAINER"
  fi

  if [ -n "$APP_DATA_CONTAINER" ] && [ -d "$STAGE/app_data" ]; then
    mkdir -p "$APP_DATA_CONTAINER"
    say "restore app data: $APP_DATA_CONTAINER"
    restore_dir_contents "$STAGE/app_data" "$APP_DATA_CONTAINER"
    chown -R mobile:mobile "$APP_DATA_CONTAINER" 2>/dev/null || true
  fi

  if [ -d "$STAGE/preferences" ]; then
    if [ -f "$STAGE/preferences/${BUNDLE_ID}.plist" ]; then
      mkdir -p "$(dirname "$APP_PREF_PATH")"
      cp -p "$STAGE/preferences/${BUNDLE_ID}.plist" "$APP_PREF_PATH" 2>/dev/null || cp "$STAGE/preferences/${BUNDLE_ID}.plist" "$APP_PREF_PATH"
      chown mobile:mobile "$APP_PREF_PATH" 2>/dev/null || true
    fi
    if [ -d "$STAGE/preferences/ByHost" ]; then
      mkdir -p "$APP_PREF_BYHOST_DIR"
      cp -p "$STAGE/preferences/ByHost"/* "$APP_PREF_BYHOST_DIR"/ 2>/dev/null || true
      chown -R mobile:mobile "$APP_PREF_BYHOST_DIR" 2>/dev/null || true
    fi
  fi

  if [ -f "$BACKUP_GROUPS_FILE" ]; then
    while IFS=$'\t' read -r gid oldpath gsafe; do
      [ -n "$gid" ] || continue
      local target
      target="$(find_current_group_path "$gid" || true)"
      [ -n "$target" ] || target="$oldpath"
      if [ -d "$STAGE/group_containers/$gsafe" ]; then
        mkdir -p "$target"
        say "restore group container: $gid -> $target"
        restore_dir_contents "$STAGE/group_containers/$gsafe" "$target"
        chown -R mobile:mobile "$target" 2>/dev/null || true
      fi
    done < "$BACKUP_GROUPS_FILE"
  fi

  if [ -f "$BACKUP_ACCESS_GROUPS_FILE" ]; then
    cp "$BACKUP_ACCESS_GROUPS_FILE" "$ACCESS_GROUPS_FILE" 2>/dev/null || true
  fi
  restore_keychain

  if [ -f "$STAGE/profile/profile.json" ]; then
    mkdir -p /var/mobile/vphone_app_profiles
    cp -p "$STAGE/profile/profile.json" "/var/mobile/vphone_app_profiles/${BUNDLE_ID}.json" 2>/dev/null || cp "$STAGE/profile/profile.json" "/var/mobile/vphone_app_profiles/${BUNDLE_ID}.json"
    chown mobile:mobile "/var/mobile/vphone_app_profiles/${BUNDLE_ID}.json" 2>/dev/null || true
  fi

  restart_state_services
  respring_if_needed "$respring"
  [ "$relaunch" = "1" ] && relaunch_app
  ok "restore completed for $BUNDLE_ID"
}

case "$ACTION" in
  backup) backup_action "$@" ;;
  new) new_action "$@" ;;
  restore) restore_action "$@" ;;
  *) die "unknown action: $ACTION" ;;
esac
