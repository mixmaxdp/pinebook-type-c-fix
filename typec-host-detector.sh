#!/bin/bash
# USB-C Host Detector for Pinebook Pro
#
# Keeps host mode (VBUS + extcon) active whenever no PD source is detected on
# CC lines. This allows CC-less USB-C accessories (e.g. Jabra EVOLVE 20 headset)
# to receive power and enumerate at their own pace.
#
# When a PD source (charger/dock) appears, disables host mode so the TCPM can
# negotiate power delivery normally.

MODULE_PATH="/usr/local/lib/typec-force-host/typec_force_host.ko"
FORCE_HOST="/sys/kernel/typec_force_host/force_host"
FORCE_DATA_HOST="/sys/kernel/typec_force_host/force_data_host"
TYPEC_PORT="/sys/bus/i2c/devices/4-0022/typec/port0"
TYPEC_MODE="$TYPEC_PORT/power_operation_mode"

POLL_INTERVAL=2

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

enable_host() {
    if module_loaded && [ "$(cat $FORCE_HOST 2>/dev/null)" != "1" ]; then
        echo 1 > "$FORCE_HOST" 2>/dev/null
        log "host mode enabled"
    fi
}

disable_host() {
    if module_loaded; then
        local cur
        cur=$(cat "$FORCE_HOST" 2>/dev/null || echo "0")
        if [ "$cur" = "0" ]; then
            return
        fi
        echo 0 > "$FORCE_HOST" 2>/dev/null
        echo 0 > "$FORCE_DATA_HOST" 2>/dev/null
        log "host mode disabled"
    fi
}

load_module || log "module not available, continuing without"

last_charger="unknown"

log "started"

while true; do
    charger=$(is_charger_connected && echo "yes" || echo "no")

    if [ "$charger" = "yes" ]; then
        [ "$last_charger" != "yes" ] && log "PD source detected (mode: $(cat $TYPEC_MODE 2>/dev/null))"
        disable_host
    else
        [ "$last_charger" != "no" ] && log "no PD source, enabling host mode"
        enable_host
    fi

    last_charger="$charger"
    sleep "$POLL_INTERVAL"
done
