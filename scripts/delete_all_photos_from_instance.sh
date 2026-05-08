#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export PATH="${PROJECT_ROOT}/.tools/shims:${PROJECT_ROOT}/.tools/bin:${PROJECT_ROOT}/.venv/bin:${HOME}/Library/Python/3.9/bin:${HOME}/Library/Python/3.14/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
source "${PROJECT_ROOT}/scripts/vphone_app_state_common.sh"

usage() {
  cat <<'USAGE'
Usage:
  zsh scripts/delete_all_photos_from_instance.sh [实例名|VM目录|SSH端口] [--yes]

Defaults:
  SSH_PORT: ${SSH_LOCAL_PORT:-2224}

This script avoids the iOS PhotoKit delete confirmation popup. It keeps the
Photos database/schema intact, purges asset rows directly, removes DCIM media
files and thumbnails, then restarts Photos/assetsd.

Examples:
  zsh scripts/delete_all_photos_from_instance.sh instagram-01
  zsh scripts/delete_all_photos_from_instance.sh vm.instances/instagram-01 --yes
  zsh scripts/delete_all_photos_from_instance.sh 2224
  zsh scripts/delete_all_photos_from_instance.sh 2224 --yes
USAGE
}

SSH_PORT="${SSH_LOCAL_PORT:-2224}"
ASSUME_YES=0
TARGET=""

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    -y|--yes)
      ASSUME_YES=1
      ;;
    <->)
      TARGET="$arg"
      SSH_PORT="$arg"
      ;;
    *)
      if [[ -z "$TARGET" ]] && vpa_resolve_vm_dir "$arg" >/dev/null 2>&1; then
        TARGET="$arg"
        SSH_PORT="$(vpa_resolve_ssh_port "$arg")"
      else
        echo "[-] unknown argument: $arg" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ "$SSH_PORT" == <-> ]] || { echo "[-] SSH_PORT must be numeric: $SSH_PORT" >&2; exit 2; }
command -v sshpass >/dev/null 2>&1 || { echo "[-] sshpass not found" >&2; exit 2; }

if [[ "$ASSUME_YES" != "1" ]]; then
  print -r -- "即将清空 guest 照片库里的所有照片/视频资产。" > /dev/tty
  print -r -- "脚本会保留 Photos.sqlite 结构，只清空资产数据和 DCIM 文件，避免相册闪退。" > /dev/tty
  print -n -- "确认删除请输入 DELETE: " > /dev/tty
  read -r reply < /dev/tty
  [[ "$reply" == "DELETE" ]] || { echo "[-] cancelled" >&2; exit 1; }
fi

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PasswordAuthentication=yes
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -o ConnectionAttempts=1
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=1
  -o LogLevel=ERROR
  -p "$SSH_PORT"
  root@127.0.0.1
)

remote_db_exists() {
  sshpass -p "$VPA_SSH_PASSWORD" ssh "${SSH_OPTS[@]}" '[ -f /var/mobile/Media/PhotoData/Photos.sqlite ] && echo yes || echo no' 2>/dev/null | tail -1
}

# If a previous hard-reset removed Photos.sqlite, rebuild a valid empty schema by
# importing a tiny placeholder first; the purge below then removes that asset.
if [[ "$(remote_db_exists)" != "yes" ]]; then
  echo "[*] Photos.sqlite missing; rebuilding schema with a temporary placeholder"
  placeholder_dir="${PROJECT_ROOT}/.build/photo_delete"
  placeholder="${placeholder_dir}/vphone-placeholder.png"
  mkdir -p "$placeholder_dir"
  python3 - "$placeholder" <<'PY'
import base64, sys
png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII='
with open(sys.argv[1], 'wb') as f:
    f.write(base64.b64decode(png))
PY
  VPHONE_PHOTO_ALBUM=VPhoneResetTemp zsh "${PROJECT_ROOT}/scripts/import_photo_to_instance.sh" "$placeholder" "$SSH_PORT" VPhoneResetTemp >/dev/null
fi

echo "[*] purging guest Photos assets on SSH port ${SSH_PORT}"
sshpass -p "$VPA_SSH_PASSWORD" ssh "${SSH_OPTS[@]}" '/var/jb/usr/bin/bash -s' <<'REMOTE'
set -euo pipefail
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/sbin:/var/jb/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/bin:/usr/bin:/bin:/sbin:/usr/sbin:/iosbinpack64/sbin:/iosbinpack64/usr/sbin

MEDIA=/var/mobile/Media
DCIM="$MEDIA/DCIM"
PHOTODATA="$MEDIA/PhotoData"
DB="$PHOTODATA/Photos.sqlite"
IMPORT_TMP=/var/mobile/Documents/vphone-photo-imports

count_db_assets() {
  if [ -f "$DB" ]; then
    sqlite3 "$DB" 'select count(*) from ZASSET;' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

count_files() {
  if [ -d "$DCIM" ]; then
    find "$DCIM" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

stop_photos_stack() {
  for proc in Photos assetsd photolibraryd photoanalysisd mediaanalysisd cloudphotod ptpcamerad mscamerad-xpc; do
    killall "$proc" 2>/dev/null || true
  done
}

before_assets="$(count_db_assets)"
before_files="$(count_files)"
echo "[*] before: Photos.sqlite assets=${before_assets}, DCIM files=${before_files}"

stop_photos_stack
sleep 1

if [ -f "$DB" ]; then
  trigger_sql=/tmp/vphone_photos_restore_triggers.sql
  drop_trigger_sql=/tmp/vphone_photos_drop_triggers.sql
  sqlite3 "$DB" "select sql || ';' from sqlite_master where type='trigger' and sql is not null;" > "$trigger_sql"
  sqlite3 "$DB" "select 'DROP TRIGGER IF EXISTS ' || quote(name) || ';' from sqlite_master where type='trigger';" > "$drop_trigger_sql"
  sqlite3 "$DB" < "$drop_trigger_sql" 2>/dev/null || true

  # Direct sqlite3 deletes cannot execute Apple's CoreData trigger helper
  # functions. Temporarily dropping and restoring triggers avoids that while
  # preserving the database schema, unlike deleting Photos.sqlite entirely.
  sqlite3 "$DB" <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;
DELETE FROM Z_32KEYASSETS;
DELETE FROM Z_33ASSETS;
DELETE FROM Z_3MEMORIESBEINGCURATEDASSETS;
DELETE FROM Z_3MEMORIESBEINGCUSTOMUSERASSETS;
DELETE FROM Z_3MEMORIESBEINGEXTENDEDCURATEDASSETS;
DELETE FROM Z_3MEMORIESBEINGMOVIECURATEDASSETS;
DELETE FROM Z_3MEMORIESBEINGREPRESENTATIVEASSETS;
DELETE FROM Z_3MEMORIESBEINGUSERCURATEDASSETS;
DELETE FROM Z_3MEMORIESBEINGUSERREMOVEDASSETS;
DELETE FROM Z_3SUGGESTIONSBEINGKEYASSETS;
DELETE FROM Z_3SUGGESTIONSBEINGREPRESENTATIVEASSETS;
DELETE FROM ZADDITIONALASSETATTRIBUTES;
DELETE FROM ZASSET;
DELETE FROM ZASSETANALYSISSTATE;
DELETE FROM ZASSETCONTRIBUTOR;
DELETE FROM ZASSETDESCRIPTION;
DELETE FROM ZASSETRESOURCEUPLOADJOB;
DELETE FROM ZASSETRESOURCEUPLOADJOBCONFIGURATION;
DELETE FROM ZASSETRESOURCEUPLOADJOBREQUEST;
DELETE FROM ZCLOUDRESOURCE;
DELETE FROM ZCOMPUTEDASSETATTRIBUTES;
DELETE FROM ZEXTENDEDATTRIBUTES;
DELETE FROM ZINTERNALRESOURCE;
DELETE FROM ZMEDIAANALYSISASSETATTRIBUTES;
DELETE FROM ZPHOTOANALYSISASSETATTRIBUTES;
DELETE FROM ZTRANSIENTINTERNALRESOURCE;
DELETE FROM ZMOMENT;
DELETE FROM ZPHOTOSHIGHLIGHT;
DELETE FROM Z_RT_Asset_boundedByRect_node;
DELETE FROM Z_RT_Asset_boundedByRect_parent;
DELETE FROM Z_RT_Asset_boundedByRect_rowid;
COMMIT;
SQL

  sqlite3 "$DB" 'PRAGMA wal_checkpoint(TRUNCATE); VACUUM;' >/dev/null 2>/dev/null || true
  sqlite3 "$DB" < "$trigger_sql" 2>/dev/null || true
fi

rm -rf "$DCIM"/* "$IMPORT_TMP"/* 2>/dev/null || true
rm -rf "$PHOTODATA"/Thumbnails/* \
       "$PHOTODATA"/AlbumsMetadata/* \
       "$PHOTODATA"/Caches/* 2>/dev/null || true
mkdir -p "$DCIM/100APPLE" "$PHOTODATA/Thumbnails" "$PHOTODATA/AlbumsMetadata" "$PHOTODATA/Caches" "$IMPORT_TMP"
chown -R mobile:mobile "$DCIM" "$PHOTODATA" "$IMPORT_TMP" 2>/dev/null || true
chmod 0755 "$DCIM" "$DCIM/100APPLE" "$PHOTODATA" "$IMPORT_TMP" 2>/dev/null || true

stop_photos_stack
remaining_assets="$(count_db_assets)"
remaining_files="$(count_files)"
triggers="$(sqlite3 "$DB" "select count(*) from sqlite_master where type='trigger';" 2>/dev/null || echo unknown)"
echo "OK purged Photos assets; before_assets=${before_assets}, before_files=${before_files}, remaining_assets=${remaining_assets}, remaining_dcim_files=${remaining_files}, triggers=${triggers}"
echo "[*] Reopen Photos. If it still shows stale thumbnails, reboot this VM once."
REMOTE
