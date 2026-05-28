# USB-C Accessory Detection on Pinebook Pro

Fixes USB-C accessory detection on the Pinebook Pro for devices that lack CC
pull-down resistors (e.g., Jabra EVOLVE 20 headset).

## Problem

The Pinebook Pro's FUSB302 TCPM detects connection via CC voltage. Devices
without Rd pull-downs (or Rp pull-ups) are invisible — they receive no VBUS and
are never enumerated. This affects headsets, simple adapters, and some USB-C
flash drives that don't implement the full Type-C spec.

Additionally, the PBP uses `dr_mode = "otg"` on the DWC3 controller with
`extcon = <&typec_extcon>`, so the DWC3 role follows the extcon state set by the
FUSB302 driver. When the TCPM sees no CC termination, it never sets
EXTCON_USB_HOST, and DWC3 stays in peripheral mode — no VBUS, no enumeration.

## Architecture

```
USB-C Connector
    │
    ├── CC lines ──→ FUSB302 (I2C)
    │                    │
    │                    └── TCPM: sets EXTCON_USB_HOST, controls vbus_5vout
    │
    ├── D+/D- ──→ USB 2.0 PHY
    └── SS ──→ USB 3.0 PHY / DP alt mode (CDN-DP)

DWC3 USB Controller
    ├── dr_mode = "otg"
    ├── extcon = <&typec_extcon>
    └── phys = <&u2phy1_otg &tcphy0_usb3>
```

## Solution

A kernel module + userspace daemon that bypasses CC detection:

1. **Kernel module** (`typec_force_host.ko`): writes to the typec-extcon and
   drives VBUS via direct GPIO control (GPIO1_A3 = GPIO 35), decoupled from
   the TCPM. The GPIO is set using `gpio_set_value()` which bypasses the
   `regulator-fixed` driver — the regulator framework's `regulator_enable()`
   was found to return success but not actually drive the GPIO pin.
2. **Systemd service** (`typec-host-detector.sh`): polls the port state and
   automatically enables/disables host mode based on PD activity.

### Kernel Module: Sysfs Interface

All controls under `/sys/kernel/typec_force_host/`:

| File | Purpose | Readback |
|------|---------|----------|
| `force_host` | Drive VBUS GPIO high + set EXTCON_USB_HOST | `1` or `0` |
| `force_data_host` | Set EXTCON_USB_HOST only (no VBUS) | `1` or `0` |

### Detection Script: State Machine

```
                    ┌──────────┐
     PD on CC ──────→│  CHARGER │←────── PD off
                    │  (sink)  │
                    └────┬─────┘
                         │ PD off
                         v
                    ┌──────────┐
                    │  PROBE   │── wait 3s after PD off ──→ enable VBUS + extcon for 2s
                    └────┬─────┘
                         │
                    ┌────┴─────┐
                    v          v
               ┌────────┐  ┌────────┐
               │ DEVICE │  │  IDLE  │
               │ found  │  │ no dev │
               └────────┘  └────┬───┘
                                │ retry after 10s
                                v
                           ┌────────┐
                           │ PROBE  │
                           └────────┘
```

Any PD activity returns to CHARGER state immediately.

## Dock Analysis

A USB-C dock that provides PD power cannot be used with the PBP as USB host for
port expansion, due to a fundamental VBUS conflict:

- The dock is the PD **Source**: it provides 5V+ on VBUS
- To make the PBP a USB **host**, DWC3 must be in host mode (EXTCON_USB_HOST)
  and must control VBUS to power downstream devices
- If VBUS regulator is OFF → DWC3 can't power the bus → `Cannot enable` errors
- If VBUS regulator is ON → PBP sources its own 5V on VBUS, colliding with the
  dock's 5V → potential short / undefined behavior

There is no safe way for the PBP to simultaneously sink power from a PD source
and source its own VBUS on the same port.

However, the PBP works normally as a USB **device** with PD sources:
- Charging works (sink power)
- DP alt mode works (external monitor via dock's HDMI/DP)
- The dock provides USB data (Ethernet, audio, storage) to the PBP as a USB
  compound device
- Devices plugged into the dock's downstream ports are managed by the dock's own
  USB host controller, not the PBP's DWC3

## Manual Usage

```bash
# Load module
sudo insmod /usr/local/lib/typec-force-host/typec_force_host.ko

# Force full host mode (VBUS + extcon) — use for CC-less devices
echo 1 | sudo tee /sys/kernel/typec_force_host/force_host

# Data-only host mode (extcon, no VBUS) — not generally useful alone
echo 1 | sudo tee /sys/kernel/typec_force_host/force_data_host

# Restore normal mode
echo 0 | sudo tee /sys/kernel/typec_force_host/force_host

# Check service status
systemctl status typec-host-detector

# Follow logs
journalctl -u typec-host-detector -f
```

## Service Behavior

- Monitors `power_operation_mode` on the Type-C port
- Scopes USB device detection to the USB-C DWC3 bus (ignores USB-A ports)
- Computes bus number dynamically (handles HCD registration timing)
- Tracks baseline devices at startup; only *new* devices on the USB-C bus are
  considered external
- PD active → disables host mode (clears extcon + GPIO)
- PD removed → waits 3s, probes host mode for 2s
- Device appears → keeps host mode
- No device → disables host, retries every 10s
- PD reconnected at any point → immediately disables host

## Rebuilding After Kernel Update

```bash
cd ~/typec-force-host
make
sudo cp typec_force_host.ko /usr/local/lib/typec-force-host/
sudo rmmod typec_force_host 2>/dev/null
sudo insmod /usr/local/lib/typec-force-host/typec_force_host.ko
sudo systemctl restart typec-host-detector
```

Or use the install script:

```bash
sudo ~/typec-force-host/install.sh
```

## Hardware Notes

- **FUSB302** at I2C address 0x22 on the RK3399's I2C4 bus, driven by `typec_fusb302`
- **DWC3** at address fe800000 on RK3399, `dr_mode = "otg"`, extcon = typec-extcon
- **VBUS regulator** `vbus_5vout` is a GPIO-controlled regulator (GPIO1_A3 = GPIO 35, active high)
- **GPIO issue**: `regulator_enable("vbus_5vout")` returns success but does **not** actually
  drive GPIO1_A3 high on this kernel. The module works around this by calling
  `gpio_set_value(35, 1)` directly, which does drive the pin.
- **CDN-DP** handles DP alt mode routing; unaffected by the module
- **Charging limitation**: PBP uses a linear charger (RK808 PMIC) with a single
  5V/2.5A sink PDO — hardware-limited to 5V input regardless of PD negotiation

## Files

| File | Purpose |
|------|---------|
| `typec_force_host.c` | Kernel module source |
| `Makefile` | Module build file |
| `typec-host-detector.sh` | Background auto-detection script |
| `typec-host-detector.service` | Systemd unit |
| `install.sh` | Build & install script |
| `.gitignore` | Ignore build artifacts |
