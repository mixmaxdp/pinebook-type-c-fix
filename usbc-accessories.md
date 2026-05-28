# USB-C Accessory Detection on Pinebook Pro

## System
- **Device**: Pinebook Pro (RK3399)
- **OS**: Armbian 26.2.1, Kernel 6.19.0-edge-rockchip64
- **Port**: Left side USB-C (farthest from screen, USB 3.0 + DP alt mode)
- **Headset**: Jabra EVOLVE 20 (USB-C)

## Architecture

```
USB-C Connector
    │
    ├── CC lines ──→ FUSB302 (I2C at 0x22)
    │                    │
    │                    ├── TCPM (Type-C Port Manager State Machine)
    │                    │     └── /sys/class/typec/port0/
    │                    │
    │                    ├── Type-C class notifies → typec-extcon bridge
    │                    │     ├── extcon1 (/sys/class/extcon/extcon1/)
    │                    │     │    └── USB-HOST cable controls DWC3 role
    │                    │     ├── USB role switch (typec-extcon-role-switch)
    │                    │     └── typec_mux (orientation + mode switch)
    │                    │
    │                    └── vbus_5vout regulator (GPIO0_A3)
    │                         └── Provides 5V to VBUS pin on Type-C
    │
    ├── D+/D- lines ──→ USB 2.0 PHY (u2phy1 @e460)
    │                         └── extcon0 (USB charger detection)
    │
    └── SS TX/RX ──→ USB 3.0 PHY (tcphy0 @ff7c0000)
                     └── DP alt mode mux via typec-extcon

DWC3 USB Controller (usb@fe800000)
    ├── dr_mode = "otg"
    ├── extcon = <&typec_extcon>  ← role switching via extcon1
    └── phys = <&u2phy1_otg &tcphy0_usb3>
```

## The Problem

The Jabra EVOLVE 20 headset (like many USB-C audio accessories) does **not** implement USB-C CC pull-down resistors (Rd). The USB-C specification requires:

- A **sink** device to have 5.1kΩ pull-down resistors on CC1 and CC2
- The **source** (Pinebook Pro) detects these to know a device is connected

Without CC pull-downs, the FUSB302 TCPM state machine never transitions from `SRC_UNATTACHED`. It never:
1. Enables the `vbus_5vout` regulator (VBUS stays 0V)
2. Notifies the typec-extcon bridge to fire `USB-HOST=1`
3. The DWC3 stays in peripheral/device mode ("not attached")

Result: **No power, no enumeration.**

## The Fix

Two components work together:

### 1. Kernel Module (`typec_force_host`)

```
echo 1 > /sys/kernel/typec_force_host/force_host
    ↓
regulator_enable("vbus_5vout")    → GPIO0_A3 high → 5V on VBUS
    ↓  (100ms delay)
extcon_set_state_sync(USB_HOST=1) → DWC3 switches to host mode
    ↓
DWC3 enumerates device on D+/D-   → headset appears in lsusb
```

### 2. Background Detector Service (`typec-host-detector`)

A systemd service that automates the switching:

```
Charger plugged in (CC detected)  → disable host → normal PD charging
Charger removed                    → wait 3s → probe host mode for 4s
    ├─ USB device found            → keep host mode ON (headset works)
    └─ No device found             → disable host, retry after 30s
Any charger reconnected            → immediately disable host
```

## Installed Files

| File | Purpose |
|---|---|
| `/home/max/typec-force-host/typec_force_host.c` | Kernel module source |
| `/home/max/typec-force-host/Makefile` | Module build file |
| `/usr/local/lib/typec-force-host/typec_force_host.ko` | Installed kernel module |
| `/usr/local/lib/typec-host-detector.sh` | Background detector script |
| `/etc/systemd/system/typec-host-detector.service` | Systemd service |
| `/sys/kernel/typec_force_host/force_host` | Write `1` to enable host, `0` to disable |

## Manual Commands

```bash
# Load module
sudo insmod /usr/local/lib/typec-force-host/typec_force_host.ko

# Force host mode (headset plugged in)
echo 1 | sudo tee /sys/kernel/typec_force_host/force_host

# Restore normal mode (before plugging charger)
echo 0 | sudo tee /sys/kernel/typec_force_host/force_host

# Check service status
systemctl status typec-host-detector

# Follow logs
journalctl -u typec-host-detector -f

# Rebuild module after kernel update
cd /home/max/typec-force-host && make
sudo cp typec_force_host.ko /usr/local/lib/typec-force-host/
```

## How It Works

### Normal flow (charger or CC-compliant device)
```
FUSB302 detects Rd on CC → TCPM enables VBUS → typec-extcon fires USB_HOST=1 → DWC3 switches to host
```

### Forced flow (headset without CC pull-downs)
```
echo 1 > force_host → module enables regulator + fires USB_HOST=1 → DWC3 switches to host
```

### Charger detection
When a USB-C charger is plugged in, the FUSB302 detects Rp (pull-up) on CC from the charger, and the TCPM switches to sink mode. The `power_operation_mode` changes from `default` to a charging mode. The detector service monitors this and disables forced host mode.

## Detection Service Logic

```
┌─────────────────────────────────────────────────────────────┐
│ Poll every 2s:                                             │
│                                                             │
│  ┌─ power_operation_mode != "default"?                      │
│  │   YES → charger detected → disable host                  │
│  │   NO  → is a USB device already present?                 │
│  │       YES → keep host enabled                            │
│  │       NO  → is it time to retry? (every 30s)             │
│  │           YES → enable host for 4s, check for devices    │
│  │           NO  → sleep                                    │
│                                                             │
│  On charger disconnect: wait 3s, then probe immediately     │
└─────────────────────────────────────────────────────────────┘
```

## Test Results

| Test | Result |
|---|---|
| Headset via USB-A adapter on USB-A port | ✅ Works |
| Headset on USB-C port (no module) | ❌ Not detected |
| `echo source > port_type` + `lsusb` | ❌ Not detected |
| `typec_force_host` module + `echo 1 > force_host` | ✅ Works! `0b0e:0301 GN Netcom Jabra EVOLVE 20` detected on Bus 007 |
| Auto-detection service | ⏳ Pending test |
