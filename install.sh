#!/bin/bash
# uConsole AIO Panel installer
#
# Always installs the panel and its menu entry. AIS-catcher and Signal K are
# optional and asked one by one. Nothing is enabled at boot: the panel starts
# and stops every service. Run as your normal user, sudo is used only when needed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

# Pinned versions and checksums: nothing unverified gets installed
AIS_VERSION="0.70"
declare -A AIS_SHA256=(
    [trixie_arm64]="bae57565b6597667b2b4864ddc9b623948879b41b00b8c66cee47e4e3ac708cd"
    [bookworm_arm64]="6828911344adb50d7d72c607fe020692efd26867613323fecabd3a2e64838782"
)
NODE_VERSION="22.23.3"
NODE_SHA256="a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f"
SIGNALK_VERSION="2.33.0"
SK_DIR="$HOME/signalk"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

TMP=$(mktemp -d)
chmod 755 "$TMP"   # apt's _apt user must be able to read the local .deb
trap 'rm -rf "$TMP"' EXIT

# Refuses to install a local .deb if apt would remove anything
apt_install_safe() {
    local sim
    sim=$(apt-get -s install "$@" 2>&1) || die "apt cannot install $*: $sim"
    if grep -q '^Remv' <<< "$sim"; then
        die "apt would remove packages to install $*, aborting. Nothing was changed."
    fi
    sudo apt-get install -y --no-install-recommends "$@"
}

# --- Checks -----------------------------------------------------------------

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not as root (sudo is used only where needed)"
command -v pinctrl >/dev/null || die "pinctrl not found: Raspberry Pi OS is required"
. /etc/os-release
CODENAME="${VERSION_CODENAME:-unknown}"
ARCH=$(dpkg --print-architecture)

say "uConsole AIO Panel installer ($CODENAME, $ARCH)"
sudo -v

# --- 1. Panel ---------------------------------------------------------------

say "1/4 Panel"
if ! command -v yad >/dev/null; then
    echo "yad is required for the panel window."
    apt_install_safe yad
fi
sudo install -m 755 uconsole-aio-panel.sh /usr/local/bin/uconsole-aio-panel
# /usr/share/applications: pcmanfm launches desktop shortcuts to it without the "Execute" prompt
sudo install -m 644 files/aio-control.desktop /usr/share/applications/aio-control.desktop
echo "Installed: /usr/local/bin/uconsole-aio-panel and the \"AIO Control\" menu entry."

# --- 2. readsb at boot ------------------------------------------------------

say "2/4 Aircraft (readsb)"
if systemctl is-enabled -q readsb 2>/dev/null; then
    echo "readsb starts at boot and keeps the SDR dongle busy (SDR++ cannot open it)."
    if ask "Let the panel manage readsb and tar1090 instead of starting them at boot?"; then
        sudo systemctl disable readsb tar1090 2>/dev/null || sudo systemctl disable readsb
        echo "Disabled at boot. Undo with: sudo systemctl enable readsb tar1090"
    fi
elif systemctl cat readsb.service >/dev/null 2>&1; then
    echo "readsb is installed and not started at boot: nothing to do."
else
    echo "readsb is not installed: the TAR (Aircraft) mode will show a warning until you install it."
fi

# --- 3. AIS-catcher ---------------------------------------------------------

say "3/4 Ships (AIS-catcher $AIS_VERSION)"
if dpkg -s ais-catcher >/dev/null 2>&1; then
    echo "AIS-catcher is already installed."
    if ! systemctl cat ais-catcher.service >/dev/null 2>&1; then
        sudo install -m 644 files/ais-catcher.service /etc/systemd/system/ais-catcher.service
        sudo systemctl daemon-reload
        echo "Added the ais-catcher service (not started at boot)."
    fi
elif ask "Install AIS-catcher to receive ship positions (needs a 162MHz antenna)?"; then
    KEY="${CODENAME}_${ARCH}"
    SHA="${AIS_SHA256[$KEY]:-}"
    if [ -z "$SHA" ]; then
        warn "No tested AIS-catcher package for $KEY, skipping."
    else
        DEB="$TMP/ais-catcher_${KEY}.deb"
        curl -fL -o "$DEB" \
            "https://github.com/jvde-github/AIS-catcher/releases/download/v${AIS_VERSION}/ais-catcher_debian_${KEY}.deb"
        echo "$SHA  $DEB" | sha256sum -c - || die "AIS-catcher checksum mismatch, aborting."
        apt_install_safe "$DEB"
        sudo install -m 644 files/ais-catcher.service /etc/systemd/system/ais-catcher.service
        sudo systemctl daemon-reload
        echo "Installed. Not started at boot: use AIS (Ships) in the panel."
    fi
fi

# --- 4. Signal K ------------------------------------------------------------

say "4/4 Marine navigation (Signal K $SIGNALK_VERSION)"
if [ -x "$SK_DIR/node_modules/.bin/signalk-server" ]; then
    echo "Signal K is already installed in $SK_DIR."
elif [ -e "$SK_DIR" ]; then
    warn "$SK_DIR already exists and is not a Signal K install made by this script: not touching it."
elif [ "$ARCH" != "arm64" ]; then
    warn "Signal K setup supports arm64 only, skipping."
elif ask "Install Signal K (marine data server for OpenCPN and nautical apps, ~460MB in $SK_DIR)?"; then
    TARBALL="$TMP/node.tar.xz"
    curl -fL -o "$TARBALL" \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz"
    echo "$NODE_SHA256  $TARBALL" | sha256sum -c - || die "Node.js checksum mismatch, aborting."
    # Everything lives in one folder: no system Node.js, no global npm packages
    mkdir -p "$SK_DIR/node" "$SK_DIR/config"
    tar -xJf "$TARBALL" -C "$SK_DIR/node" --strip-components=1
    PATH="$SK_DIR/node/bin:$PATH" npm install --prefix "$SK_DIR" --no-fund --no-audit \
        "signalk-server@${SIGNALK_VERSION}"
    cp files/signalk-settings.json "$SK_DIR/config/settings.json"
    mkdir -p "$HOME/.config/systemd/user"
    install -m 644 files/signalk.service "$HOME/.config/systemd/user/signalk.service"
    systemctl --user daemon-reload
    echo "Installed. Not started at boot: use GPS use → Signal K in the panel."
    warn "The first time you open http://localhost:3000, create the admin user right away:"
    warn "until you do, anyone on your network could create it."
fi

say "Done. Open \"AIO Control\" from the menu (Preferences)."
