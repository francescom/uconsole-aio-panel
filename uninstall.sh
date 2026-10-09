#!/bin/bash
# uConsole AIO Panel uninstaller: removes what install.sh added, asking for each part
set -euo pipefail

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ask()  { local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not as root." >&2; exit 1; }
sudo -v

say "Panel"
sudo rm -f /usr/local/bin/uconsole-aio-panel /usr/share/applications/aio-control.desktop
rm -f "$HOME/.config/uconsole-aio-panel.conf"
echo "Removed."

if dpkg -s ais-catcher >/dev/null 2>&1 && ask "Remove AIS-catcher?"; then
    sudo systemctl stop ais-catcher 2>/dev/null || true
    sudo rm -f /etc/systemd/system/ais-catcher.service
    sudo systemctl daemon-reload
    # remove, NOT purge: purge deletes /etc/udev/rules.d/rtl-sdr.rules,
    # which may belong to other SDR software (e.g. SDR++)
    sudo apt-get remove -y ais-catcher
fi

if [ -d "$HOME/signalk" ] && ask "Remove Signal K and its settings in ~/signalk?"; then
    systemctl --user stop signalk 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/signalk.service"
    systemctl --user daemon-reload
    rm -rf "$HOME/signalk"
fi

if systemctl cat readsb.service >/dev/null 2>&1 && ! systemctl is-enabled -q readsb 2>/dev/null \
    && ask "Start readsb and tar1090 at boot again?"; then
    sudo systemctl enable readsb tar1090 2>/dev/null || sudo systemctl enable readsb
fi

say "Done."
