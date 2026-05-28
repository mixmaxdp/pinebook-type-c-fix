# USB-C Accessory Detection on Pinebook Pro

This project fixes USB-C accessory detection on the Pinebook Pro for devices that don't implement USB-C CC pull-down resistors (e.g., Jabra EVOLVE 20 headset).

## How It Works

The Pinebook Pro's USB-C port uses a FUSB302 controller for Type-C connection detection via CC (Configuration Channel) pins. Devices that don't pull CC lines down are invisible to this controller — they receive no VBUS and are never enumerated.

This project provides:
1. A **kernel module** (`typec_force_host`) that bypasses CC detection and directly enables VBUS + host mode
2. A **systemd service** that automatically switches between charger and device modes

## Architecture

```
USB-C Connector
    │
    ├── CC lines ──→ FUSB302 (I2C)
    │                    │
    │                    ├── TCPM (Type-C Port Manager)
    │                    │     └── /sys/class/typec/port0/
    │                    │
    │                    ├── Type-C class → typec-extcon bridge
    │                    │     ├── extcon1         ← USB-HOST cable
    │                    │     ├── usb_role switch
    │                    │     └── typec_mux
    │                    │
    │                    └── vbus_5vout regulator (GPIO)
    │
    ├── D+/D- ──→ USB 2.0 PHY
    └── SS ──→ USB 3.0 PHY / DP alt mode

DWC3 USB Controller
    ├── dr_mode = "otg"
    ├── extcon = <&typec_extcon>
    └── phys = <&u2phy1_otg &tcphy0_usb3>
```

## Files

| File | Purpose |
|---|---|
| `typec_force_host.c` | Kernel module source |
| `Makefile` | Module build file |
| `typec-host-detector.sh` | Background auto-detection script |
| `typec-host-detector.service` | Systemd unit |
| `install.sh` | Build & install script |

## Manual Usage

```bash
# Load module
sudo insmod /usr/local/lib/typec-force-host/typec_force_host.ko

# Force host mode
echo 1 | sudo tee /sys/kernel/typec_force_host/force_host

# Restore normal mode (e.g., before plugging a charger)
echo 0 | sudo tee /sys/kernel/typec_force_host/force_host

# Check service status
systemctl status typec-host-detector

# Follow logs
journalctl -u typec-host-detector -f
```

## Automatic Detection

Install with `sudo bash install.sh`. The service:

- Monitors `power_operation_mode` on the Type-C port
- Scopes USB device detection to the `fe800000.usb` bus (USB-C only, ignores USB-A devices)
- Computes bus number dynamically each check (handles HCD registration after role switches)
- Tracks baseline devices at startup; only newly appeared devices on the USB-C bus are considered "external"
- When a charger is detected (CC negotiation) → disables host mode
- When charger is removed → waits 3s, probes host mode for 4s
- If a USB device appears → keeps host mode on
- If no device found → disables host immediately, retries every 10s
- If charger reconnected at any point → immediately disables host

## Rebuilding After Kernel Update

```bash
cd typec-force-host
make
sudo cp typec_force_host.ko /usr/local/lib/typec-force-host/
sudo systemctl restart typec-host-detector
```
