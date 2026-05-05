#!/bin/bash
# vphone_jb_setup.sh — First-boot JB finalization script.
#
# Deployed to /cores/ during cfw_install_jb.sh (ramdisk phase).
# Runs automatically via LaunchDaemon on first normal boot.
# Idempotent — safe to re-run on subsequent boots.
#
# Logs to /var/log/vphone_jb_setup.log for host-side monitoring
# via vphoned file browser.

set -uo pipefail

LOG="/var/log/vphone_jb_setup.log"
DONE_MARKER="/var/mobile/.vphone_jb_setup_done"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; exit 1; }

# Redirect all output to log
exec > >(tee -a "$LOG") 2>&1

log "=== vphone_jb_setup.sh starting ==="

# ── Check done marker ────────────────────────────────────────
if [ -f "$DONE_MARKER" ]; then
    log "Already completed (marker exists), exiting."
    exit 0
fi

# ── Environment ──────────────────────────────────────────────
export TERM=xterm-256color
export DEBIAN_FRONTEND=noninteractive

# Discover PATH dynamically
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "PATH=$PATH"

# ── Find boot manifest hash ─────────────────────────────────
BOOT_HASH=""
for d in /private/preboot/*/; do
    b="${d%/}"; b="${b##*/}"
    if [ "${#b}" = 96 ]; then
        BOOT_HASH="$b"
        break
    fi
done
[ -n "$BOOT_HASH" ] || die "Could not find 96-char boot manifest hash"
log "Boot hash: $BOOT_HASH"

JB_TARGET="/private/preboot/$BOOT_HASH/jb-vphone/procursus"
[ -d "$JB_TARGET" ] || die "Procursus not found at $JB_TARGET"
LOCAL_DEB_DIR="/private/preboot/$BOOT_HASH/vphone-local-debs"

install_local_deb() {
    pkg="$1"
    deb="$2"
    label="$3"

    if dpkg -s "$pkg" >/dev/null 2>&1; then
        log "  $label already installed"
        return 0
    fi
    if [ ! -f "$deb" ]; then
        log "  Local $label deb not found: $deb"
        return 1
    fi

    log "  Installing local $label: $deb"
    dpkg -i "$deb" 2>&1
}

# ═══════════ 0/7 REPLACE LAUNCHCTL ═════════════════════════════
# Procursus launchctl crashes (missing _launch_active_user_switch symbol).
# iosbinpack64's launchctl talks to launchd fine and always exits 0,
# which is enough for dpkg postinst/prerm script compatibility.
log "[0/8] Linking iosbinpack64 launchctl into procursus..."
IOSBINPACK_LAUNCHCTL=""
for p in /iosbinpack64/bin/launchctl /iosbinpack64/usr/bin/launchctl; do
    [ -f "$p" ] && IOSBINPACK_LAUNCHCTL="$p" && break
done

if [ -n "$IOSBINPACK_LAUNCHCTL" ]; then
    if [ -f "$JB_TARGET/usr/bin/launchctl" ] && [ ! -L "$JB_TARGET/usr/bin/launchctl" ] && [ ! -f "$JB_TARGET/usr/bin/launchctl.procursus" ]; then
        mv "$JB_TARGET/usr/bin/launchctl" "$JB_TARGET/usr/bin/launchctl.procursus"
        log "  procursus original saved as launchctl.procursus"
    fi
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/usr/bin/launchctl"
    mkdir -p "$JB_TARGET/bin"
    ln -sf "$IOSBINPACK_LAUNCHCTL" "$JB_TARGET/bin/launchctl"
    log "  linked usr/bin/launchctl + bin/launchctl -> $IOSBINPACK_LAUNCHCTL"
else
    log "  WARNING: iosbinpack64 launchctl not found"
fi

# ═══════════ 1/7 SYMLINK /var/jb ═════════════════════════════
log "[1/8] Creating /private/var/jb symlink..."
CURRENT_LINK=$(readlink /private/var/jb 2>/dev/null || true)
if [ "$CURRENT_LINK" = "$JB_TARGET" ]; then
    log "  Symlink already correct"
else
    ln -sf "$JB_TARGET" /private/var/jb
    log "  /var/jb -> $JB_TARGET"
fi

# ═══════════ 2/7 FIX OWNERSHIP / PERMISSIONS ═════════════════
log "[2/8] Fixing mobile Library ownership..."
mkdir -p /var/jb/var/mobile/Library/Preferences
chown -R 501:501 /var/jb/var/mobile/Library
chmod 0755 /var/jb/var/mobile/Library
chown -R 501:501 /var/jb/var/mobile/Library/Preferences
chmod 0755 /var/jb/var/mobile/Library/Preferences
log "  Ownership set"

# ═══════════ 3/7 RUN prep_bootstrap.sh ═══════════════════════
log "[3/8] Running prep_bootstrap.sh..."
if [ -f /var/jb/prep_bootstrap.sh ]; then
    NO_PASSWORD_PROMPT=1 /var/jb/prep_bootstrap.sh || log "  prep_bootstrap.sh exited with $?"
    log "  prep_bootstrap.sh completed"
else
    log "  prep_bootstrap.sh already ran (deleted itself), skipping"
fi

# Re-discover PATH after prep_bootstrap
P=""
for d in \
    /var/jb/usr/bin /var/jb/bin /var/jb/sbin /var/jb/usr/sbin \
    /iosbinpack64/bin /iosbinpack64/usr/bin /iosbinpack64/sbin /iosbinpack64/usr/sbin \
    /usr/bin /usr/sbin /bin /sbin; do
    [ -d "$d" ] && P="$P:$d"
done
export PATH="${P#:}"
log "  PATH=$PATH"

# ═══════════ 4/7 CREATE MARKER FILES ═════════════════════════
log "[4/8] Creating marker files..."
for marker in .procursus_strapped .installed_dopamine; do
    if [ -f "/var/jb/$marker" ]; then
        log "  $marker already exists"
    else
        : > "/var/jb/$marker"
        chown 0:0 "/var/jb/$marker"
        chmod 0644 "/var/jb/$marker"
        log "  $marker created"
    fi
done

# ═══════════ 5/7 INSTALL SILEO ═══════════════════════════════
log "[5/8] Installing Sileo..."
SILEO_DEB_PATH="/private/preboot/$BOOT_HASH/org.coolstar.sileo_2.5.1_iphoneos-arm64.deb"

if dpkg -s org.coolstar.sileo >/dev/null 2>&1; then
    log "  Sileo already installed"
else
    if [ -f "$SILEO_DEB_PATH" ]; then
        dpkg -i "$SILEO_DEB_PATH" || log "  dpkg -i sileo exited with $?"
        log "  Sileo installed"
    else
        log "  WARNING: Sileo deb not found at $SILEO_DEB_PATH"
    fi
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# ═══════════ 6/7 APT SETUP ══════════════════════════════════
log "[6/8] Running apt setup..."

# Determine apt sources directory
APT_SOURCES_DIR="/var/jb/etc/apt/sources.list.d"
if [ -d /etc/apt/sources.list.d ] && [ ! -d "$APT_SOURCES_DIR" ]; then
    APT_SOURCES_DIR="/etc/apt/sources.list.d"
fi
HAVOC_LIST="$APT_SOURCES_DIR/havoc.list"
BIGBOSS_LIST="$APT_SOURCES_DIR/bigboss.list"
BIGBOSS_REPO_URL="http://apt.thebigboss.org/repofiles/cydia/"
CUSTOM_SOURCES_SRC="/private/preboot/$BOOT_HASH/vphone-extra-sources.list"
CUSTOM_SOURCES_DST="$APT_SOURCES_DIR/vphone-user.list"

if ! grep -rIl 'havoc.app' /etc/apt /var/jb/etc/apt 2>/dev/null | grep -q .; then
    mkdir -p "$APT_SOURCES_DIR"
    printf '%s\n' 'deb https://havoc.app/ ./' > "$HAVOC_LIST"
    log "  Havoc source added: $HAVOC_LIST"
else
    log "  Havoc source already present"
fi

if ! grep -rIl 'apt.thebigboss.org/repofiles/cydia' /etc/apt /var/jb/etc/apt 2>/dev/null | grep -q .; then
    mkdir -p "$APT_SOURCES_DIR"
    printf '%s\n' "deb $BIGBOSS_REPO_URL stable main" > "$BIGBOSS_LIST"
    log "  BigBoss source added: $BIGBOSS_LIST"
else
    log "  BigBoss source already present"
fi

if [ -s "$CUSTOM_SOURCES_SRC" ]; then
    mkdir -p "$APT_SOURCES_DIR"
    cp "$CUSTOM_SOURCES_SRC" "$CUSTOM_SOURCES_DST"
    chmod 0644 "$CUSTOM_SOURCES_DST"
    log "  Custom Cydia/Sileo sources installed: $CUSTOM_SOURCES_DST"
    sed 's/^/    /' "$CUSTOM_SOURCES_DST"
else
    log "  No custom Cydia/Sileo sources staged"
fi

apt-get -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    update -qq 2>&1 || log "  apt update exited with $?"
log "  apt update done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    install -y -qq libkrw0-tfp0 2>/dev/null || true
log "  libkrw0-tfp0 done"

apt-get -o APT::Get::AllowUnauthenticated=true \
    upgrade -y -qq 2>/dev/null || true
log "  apt upgrade done"

# ═══════════ 7/7 INSTALL TROLLSTORE LITE ═════════════════════
log "[7/8] Installing TrollStore Lite..."

log "  Ensuring ldid dependency..."
if ! dpkg -s ldid >/dev/null 2>&1; then
    install_local_deb libplist3 "$LOCAL_DEB_DIR/libplist3_2.2.0+git20230130.4b50a5a_iphoneos-arm64.deb" "libplist3" || true
    install_local_deb ldid "$LOCAL_DEB_DIR/ldid_2.1.5-procursus7_iphoneos-arm64.deb" "ldid" || true
fi
if ! dpkg -s ldid >/dev/null 2>&1; then
    log "  Local ldid install unavailable/incomplete; falling back to apt"
    apt-get -o APT::Get::AllowUnauthenticated=true \
        install -y -qq ldid 2>&1 || true
fi
if ! dpkg -s ldid >/dev/null 2>&1; then
    die "ldid dependency is still missing; cannot install TrollStore Lite"
fi

if dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
    log "  TrollStore Lite already installed"
else
    LOCAL_TROLLSTORE_DEB="$LOCAL_DEB_DIR/com.opa334.trollstorelite_2.1_iphoneos-arm64.deb"
    if [ -f "$LOCAL_TROLLSTORE_DEB" ]; then
        install_local_deb com.opa334.trollstorelite "$LOCAL_TROLLSTORE_DEB" "TrollStore Lite" || true
    fi

    if ! dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
        log "  Local TrollStore Lite install unavailable/incomplete; falling back to apt"
        apt-get -o APT::Get::AllowUnauthenticated=true \
            install -y -qq com.opa334.trollstorelite 2>&1
        trollstore_rc=$?
        if [ "$trollstore_rc" -ne 0 ]; then
            die "TrollStore Lite apt install failed with exit code $trollstore_rc"
        fi
    fi

    if ! dpkg -s com.opa334.trollstorelite >/dev/null 2>&1; then
        die "TrollStore Lite install completed without registering package"
    fi
    log "  TrollStore Lite installed"
fi

uicache -a 2>/dev/null || true
log "  uicache refreshed"

# ═══════════ 8/8 SHELL PROFILES FOR SSH ═══════════════════════
log "[8/8] Setting up shell profiles for SSH..."

# The injected dropbear daemon is started with:
#   --shell /iosbinpack64/bin/bash
# so SSH does not depend on /etc/passwd's shell field. Do not rewrite
# /etc/passwd or /bin/sh here: on current iOS images the root filesystem is
# normally read-only after first boot. Instead, make the writable root home
# profiles robust so forced-PTY sshpass sessions get a prompt and complete PATH.

cat > /var/root/.bashrc <<'EOF'
# vphone SSH environment
[ -r /var/jb/etc/profile ] && . /var/jb/etc/profile
export PATH="/var/jb/usr/local/sbin:/var/jb/usr/local/bin:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PS1='vphone:\w \u\$ '
EOF
chmod 0644 /var/root/.bashrc
log "  /var/root/.bashrc updated"

cat > /var/root/.bash_profile <<'EOF'
# vphone SSH login shell environment
[ -r /var/root/.bashrc ] && . /var/root/.bashrc
EOF
chmod 0644 /var/root/.bash_profile
log "  /var/root/.bash_profile updated"

# ═══════════ DONE ════════════════════════════════════════════
: > "$DONE_MARKER"
log "=== vphone_jb_setup.sh complete ==="
