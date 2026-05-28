#!/bin/bash
# USB-C Host Detector for Pinebook Pro
# Automatically switches USB-C port to host mode when:
#   - No charger is detected on CC lines
#   - A USB device might be connected (CC-less accessory like Jabra headset)
# Automatically disables host mode when charger is plugged in.

set -e

MODULE_PATH="/usr/local/lib/typec-force-host/typec_force_host.ko"
FORCE_HOST="/sys/kernel/typec_force_host/force_host"
TYPEC_PORT="/sys/bus/i2c/devices/4-0022/typec/port0"
TYPEC_MODE="$TYPEC_PORT/power_operation_mode"

POLL_INTERVAL=2
PROBE_DELAY=3
PROBE_HOLD=4
PROBE_RETRY=30

# USB-C DWC3 controller on RK3399
USB_C_CONTROLLER="fe800000.usb"

# Find which bus number corresponds to the USB-C controller
get_usbc_bus_num() {
    for d in /sys/bus/usb/devices/usb[0-9]*; do
        local target
        target=$(readlink -f "$d" 2>/dev/null || echo "")
        case "$target" in
            *"$USB_C_CONTROLLER"*) basename "$d" | sed 's/usb//'; return 0 ;;
        esac
    done
    echo ""
}

USB_C_BUS=$(get_usbc_bus_num)

log() {
    logger -t "typec-host-detector" "$@"
}

module_loaded() {
    [ -f "$FORCE_HOST" ]
}

load_module() {
    if ! module_loaded; then
        if [ -f "$MODULE_PATH" ]; then
            insmod "$MODULE_PATH" 2>/dev/null || true
            sleep 1
        else
            log "Module not found at $MODULE_PATH"
            return 1
        fi
    fi
}

is_charger_connected() {
    local mode
    mode=$(cat "$TYPEC_MODE" 2>/dev/null || echo "default")
    [ "$mode" != "default" ]
}

get_device_set() {
    [ -z "$USB_C_BUS" ] && return
    local bus_pad
    bus_pad=$(printf "%03d" "$USB_C_BUS")
    lsusb 2>/dev/null | grep "^Bus $bus_pad " | grep -v "Linux Foundation\|root hub" | awk '{print $6}' | sort -u || true
}

# Baseline captured at startup — devices present before any host mode probing
BASELINE_DEVICES=$(get_device_set)

has_external_usb_device() {
    local current
    current=$(get_device_set)
    [ -z "$current" ] && return 1
    [ -z "$BASELINE_DEVICES" ] && return 0
    local new_devices
    new_devices=$(comm -13 <(printf "%s\n" "$BASELINE_DEVICES") <(printf "%s\n" "$current"))
    [ -n "$new_devices" ]
}

enable_host() {
    if module_loaded; then
        echo 1 > "$FORCE_HOST" 2>/dev/null
        log "host mode enabled"
    fi
}

disable_host() {
    if module_loaded; then
        echo 0 > "$FORCE_HOST" 2>/dev/null
        log "host mode disabled"
    fi
}

probe_for_devices() {
    # Briefly enable host mode to check if a device is connected
    enable_host
    sleep "$PROBE_HOLD"

    if has_external_usb_device && ! is_charger_connected; then
        log "device detected, keeping host mode"
        return 0
    else
        # If charger connected during probe, disable immediately
        if is_charger_connected; then
            disable_host
            return 1
        fi
        disable_host
        log "no device found, host mode disabled"
        return 1
    fi
}

# Load module at start
load_module || log "module not available, continuing without"

# State tracking
last_charger="unknown"
last_device_check=0
now=0

log "started"

while true; do
    now=$(date +%s)
    charger=$(is_charger_connected && echo "yes" || echo "no")

    if [ "$charger" = "yes" ]; then
        # Charger connected → disable host, let normal CC charging work
        if [ "$last_charger" != "yes" ]; then
            log "charger detected (mode: $(cat $TYPEC_MODE 2>/dev/null))"
        fi
        disable_host
        last_charger="yes"
    else
        # No charger detected on CC
        if [ "$last_charger" = "yes" ]; then
            # Charger was just disconnected → probe after a delay
            log "charger disconnected, probing for devices in ${PROBE_DELAY}s"
            sleep "$PROBE_DELAY"
            # Re-check charger during the delay
            if ! is_charger_connected; then
                probe_for_devices
            fi
        elif [ "$last_charger" = "no" ]; then
            # No charger, check existing state
            if has_external_usb_device && module_loaded; then
                # Device already present → keep host mode
                if [ "$(cat $FORCE_HOST 2>/dev/null)" != "1" ]; then
                    enable_host
                fi
            else
                # No device, check if it's time to retry
                elapsed=$(( now - last_device_check ))
                if [ $elapsed -ge $PROBE_RETRY ]; then
                    probe_for_devices || true
                    last_device_check=$now
                fi
            fi
        else
            # First run: probe after a delay
            sleep "$PROBE_DELAY"
            if ! is_charger_connected; then
                probe_for_devices
            fi
            last_device_check=$now
        fi
        last_charger="no"
    fi

    sleep "$POLL_INTERVAL"
done
