#!/bin/bash
# uConsole AIO Panel - power and mode control for the ClockworkPi uConsole AIO board
# https://github.com/francescom/uconsole-aio-panel - MIT License

# --- Configuration ----------------------------------------------------------

# AIO v2 board GPIO pins (tested on CM5), same mapping as hackergadgets/aiov2_ctl
PIN_USB=23     # AIO USB ports (e.g. a WiFi 1200 dongle)
PIN_GPS=27
PIN_LORA=16
PIN_SDR=7

# Optional services: started only if installed, a warning is shown otherwise
AIS_SVC="ais-catcher"   # system service, ship map on http://localhost:8100
NAUTICA_SVC="signalk"   # user service in ~/signalk, web UI on http://localhost:3000

# Last selected modes are remembered here
CONF="$HOME/.config/uconsole-aio-panel.conf"

# Drop-down entries
SDR_ADSB="TAR (Aircraft, 1090MHz, ¼λ 6.9cm)"
SDR_AIS="AIS (Ships, 162MHz, ¼λ 46cm)"
SDR_LIBERO="SDR++ (Free listening)"
GPS_SOLO="NMEA (Raw serial data)"
GPS_GPSD="GPSD (Position for maps and apps)"
GPS_MARE="Signal K (Marine navigation)"

# --- Functions --------------------------------------------------------------

# Asks for the password with YAD only when the sudo cache has expired.
# Runs in the main shell, so "Cancel" really exits the script.
auth() {
    sudo -n true 2>/dev/null && return 0
    local msg="Enter your password to manage the AIO hardware:"
    local pass
    while true; do
        pass=$(yad --entry --hide-text --title="uConsole authentication" \
            --text="$msg" --image="dialog-password" --width=300 \
            --button="OK:0" --button="Cancel:1") || exit 1
        sudo -S -v -p '' <<< "$pass" 2>/dev/null && break
        msg="<b>Wrong password</b>, try again:"
    done
}

# Rail state from the pin level ("hi"/"lo"). After boot the pins are not driven
# yet (level "--"): then the AIO v2 default applies, SDR on, everything else off.
# Same logic as hackergadgets/aiov2_ctl.
pin_on() {
    local out
    out=$(pinctrl get "$1")
    if [[ "$out" =~ \|\ hi ]]; then
        echo "TRUE"
    elif [[ "$out" =~ \|\ lo ]]; then
        echo "FALSE"
    elif [ "$1" = "$PIN_SDR" ]; then
        echo "TRUE"
    else
        echo "FALSE"
    fi
}

pin_set() {
    sudo pinctrl set "$1" op "$([ "$2" = "TRUE" ] && echo dh || echo dl)"
}

# Builds the list for a :CB field, marking the default entry with ^
combo() {
    local def="$1" out="" item
    shift
    for item in "$@"; do
        [ "$item" = "$def" ] && item="^$item"
        out="${out:+$out!}$item"
    done
    echo "$out"
}

# Accepts "name" (a .service) or a full unit name such as "gpsd.socket"
svc_exists() {
    local unit="$1"
    [[ "$unit" == *.* ]] || unit="$unit.service"
    systemctl cat "$unit" >/dev/null 2>&1
}

# Stops the given services, skipping those that are not installed
svc_stop() {
    local s
    for s in "$@"; do
        svc_exists "$s" && sudo systemctl stop "$s"
    done
}

# Starts the given services, collecting the missing ones for a warning
svc_start() {
    local s
    for s in "$@"; do
        if svc_exists "$s"; then
            sudo systemctl start "$s"
        else
            MISSING="${MISSING}\n• $s"
        fi
    done
}

# --- 1. Authentication and current state -------------------------------------

auth

USB_ST=$(pin_on $PIN_USB)
GPS_ST=$(pin_on $PIN_GPS)
LORA_ST=$(pin_on $PIN_LORA)
SDR_ST=$(pin_on $PIN_SDR)

SDR_MODE="$SDR_ADSB"
GPS_MODE="$GPS_GPSD"
[ -f "$CONF" ] && . "$CONF"

# If the running services disagree with the saved file, the real state wins
if [ "$SDR_ST" = "TRUE" ]; then
    if systemctl is-active -q readsb; then
        SDR_MODE="$SDR_ADSB"
    elif systemctl is-active -q "$AIS_SVC"; then
        SDR_MODE="$SDR_AIS"
    else
        SDR_MODE="$SDR_LIBERO"
    fi
fi

# --- 2. User interface ------------------------------------------------------

OUTPUT=$(yad --title="uConsole AIO Control" \
    --window-icon="network-wireless" \
    --text="<b>AIO Board Hardware Control</b>\nChoose what to power on and how to use it:" \
    --form --width=340 --button="Apply:0" --button="Close:1" \
    --field="USB/WiFi 1200 (AIO USB ports):CHK" "$USB_ST" \
    --field="GPS (Position, 1575MHz):CHK" "$GPS_ST" \
    --field="LoRa (Meshtastic, 868MHz):CHK" "$LORA_ST" \
    --field="SDR (Radio receiver):CHK" "$SDR_ST" \
    --field="SDR use:CB" "$(combo "$SDR_MODE" "$SDR_ADSB" "$SDR_AIS" "$SDR_LIBERO")" \
    --field="GPS use:CB" "$(combo "$GPS_MODE" "$GPS_SOLO" "$GPS_GPSD" "$GPS_MARE")") || exit 0

# --- 3. Apply ---------------------------------------------------------------

IFS='|' read -r USB_NEW GPS_NEW LORA_NEW SDR_NEW SDR_MODE GPS_MODE _ <<< "$OUTPUT"

mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
SDR_MODE="$SDR_MODE"
GPS_MODE="$GPS_MODE"
EOF

# The sudo cache may have expired if the panel stayed open for a long time
auth

MISSING=""

# Stop the services using a module before cutting its power
if [ "$LORA_NEW" = "FALSE" ]; then
    svc_stop meshtasticd
fi
# The RTL-SDR dongle can be used by one program at a time:
# stop everything the selected mode does not need
if [ "$SDR_NEW" = "FALSE" ] || [ "$SDR_MODE" != "$SDR_ADSB" ]; then
    svc_stop tar1090 readsb
fi
if [ "$SDR_NEW" = "FALSE" ] || [ "$SDR_MODE" != "$SDR_AIS" ]; then
    svc_stop "$AIS_SVC"
fi
# Signal K is a user service (~/signalk), no sudo needed
if [ "$GPS_NEW" = "FALSE" ] || [ "$GPS_MODE" != "$GPS_MARE" ]; then
    systemctl --user stop "$NAUTICA_SVC" 2>/dev/null
fi
# Stop the socket too, otherwise gpsd restarts on the first request
if [ "$GPS_NEW" = "FALSE" ] || [ "$GPS_MODE" = "$GPS_SOLO" ]; then
    svc_stop gpsd.socket gpsd
fi

pin_set $PIN_USB "$USB_NEW"
pin_set $PIN_GPS "$GPS_NEW"
pin_set $PIN_LORA "$LORA_NEW"
pin_set $PIN_SDR "$SDR_NEW"

# Short pause so the modules power up cleanly before their daemons start
if [ "$LORA_NEW" = "TRUE" ] || [ "$SDR_NEW" = "TRUE" ] || [ "$GPS_NEW" = "TRUE" ]; then
    sleep 2
fi

if [ "$LORA_NEW" = "TRUE" ]; then
    svc_start meshtasticd
fi

if [ "$SDR_NEW" = "TRUE" ]; then
    case "$SDR_MODE" in
        "$SDR_ADSB") svc_start readsb tar1090 ;;
        "$SDR_AIS")  svc_start "$AIS_SVC" ;;
    esac
fi

if [ "$GPS_NEW" = "TRUE" ] && [ "$GPS_MODE" != "$GPS_SOLO" ]; then
    svc_start gpsd.socket gpsd
    if [ "$GPS_MODE" = "$GPS_MARE" ]; then
        if systemctl --user cat "$NAUTICA_SVC.service" >/dev/null 2>&1; then
            systemctl --user start "$NAUTICA_SVC"
        else
            MISSING="${MISSING}\n• $NAUTICA_SVC"
        fi
    fi
fi

if [ -n "$MISSING" ]; then
    yad --title="uConsole AIO Control" --image="dialog-warning" \
        --text="Not installed, not started:$MISSING" --button="OK:0"
fi
