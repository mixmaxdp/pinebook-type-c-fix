#!/bin/bash
# USB-C Host Detector for Pinebook Pro
# Automatically switches USB-C port to host mode when:
#   - No PD activity on CC lines (CC-less accessory like Jabra headset)
#   - A USB device is detected on the USB-C bus
# Automatically disables host mode when PD activity resumes (charger or dock).

MODULE_PATH="/usr/local/lib/typec-force-host/typec_force_host.ko"
FORCE_HOST="/sys/kernel/typec_force_host/force_host"
FORCE_DATA_HOST="/sys/kernel/typec_force_host/force_data_host"
TYPEC_PORT="/sys/bus/i2c/devices/4-0022/typec/port0"
TYPEC_MODE="$TYPEC_PORT/power_operation_mode"

POLL_INTERVAL=2
PROBE_DELAY=3
PROBE_HOLD=2
PROBE_RETRY=10

USB_C_CONTROLLER="fe800000.usb"

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
    local bus bus_pad
    bus=$(get_usbc_bus_num)
    [ -z "$bus" ] && return
    bus_pad=$(printf "%03d" "$bus")
    lsusb 2>/dev/null | grep "^Bus $bus_pad " | grep -v "Linux Foundation\|root hub" | awk '{print $6}' | sort -u || true
}

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
    if module_loaded && [ "$(cat $FORCE_HOST 2>/dev/null)" != "1" ]; then
        echo 1 > "$FORCE_HOST" 2>/dev/null
        log "host mode enabled (VBUS + extcon)"
    fi
}

disable_host() {
    if module_loaded; then
        local cur_h cur_dh
        cur_h=$(cat "$FORCE_HOST" 2>/dev/null || echo "0")
        cur_dh=$(cat "$FORCE_DATA_HOST" 2>/dev/null || echo "0")
        if [ "$cur_h" = "0" ] && [ "$cur_dh" = "0" ]; then
            return
        fi
        echo 0 > "$FORCE_HOST" 2>/dev/null
        echo 0 > "$FORCE_DATA_HOST" 2>/dev/null
        log "host mode disabled (extcon + VBUS)"
    fi
}

probe_for_devices() {
    is_charger_connected && return 1
    enable_host
    sleep "$PROBE_HOLD"

    if has_external_usb_device && ! is_charger_connected; then
        log "device detected, keeping host mode"
        return 0
    else
        if is_charger_connected; then
            disable_host
            return 1
        fi
        disable_host
        log "no device found, host mode disabled"
        return 1
    fi
}

load_module || log "module not available, continuing without"

last_charger="unknown"
last_device_check=0
now=0

log "started"

while true; do
    now=$(date +%s)
    charger=$(is_charger_connected && echo "yes" || echo "no")

    if [ "$charger" = "yes" ]; then
        [ "$last_charger" != "yes" ] && log "PD source detected (mode: $(cat $TYPEC_MODE 2>/dev/null))"
        disable_host
        last_charger="yes"
    else
        if [ "$last_charger" = "yes" ]; then
            log "charger disconnected, probing for devices in ${PROBE_DELAY}s"
            sleep "$PROBE_DELAY"
            if ! is_charger_connected; then
                probe_for_devices || true
            fi
        elif [ "$last_charger" = "no" ]; then
            if has_external_usb_device && module_loaded; then
                if [ "$(cat $FORCE_HOST 2>/dev/null)" != "1" ]; then
                    enable_host
                fi
            else
                disable_host
                elapsed=$(( now - last_device_check ))
                if [ $elapsed -ge $PROBE_RETRY ]; then
                    probe_for_devices || true
                    last_device_check=$now
                fi
            fi
        else
            sleep "$PROBE_DELAY"
            if ! is_charger_connected; then
                probe_for_devices || true
            fi
            last_device_check=$now
        fi
        last_charger="no"
    fi

    sleep "$POLL_INTERVAL"
done
