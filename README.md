# wifiman

A lightweight GTK4 Wi-Fi manager for Linux. Uses GTK4 and libnm — no
libadwaita. Works as a Waybar popup or standalone window.

It shows only networks detected by active scans. Saved profiles remain
in NetworkManager for auto-connect but are not listed unless the SSID
is visible in scan results.

## Features

- Scan for nearby Wi-Fi networks in real time
- Connect to open, WPA/WPA2/WPA3, and Enterprise (PEAP/MSCHAPv2) networks
- Search networks by SSID with live filtering
- Auto-connect to known networks when detected (never disconnects the
  active connection automatically)
- Captive portal detection with banner
- Network details: security, band, signal dBm, bitrate, IP, gateway, DNS
- Connect / Reconnect / Disconnect / Forget actions
- Wi-Fi toggle (turning Wi-Fi OFF closes the app)
- Three color schemes: System, Light, Dark (persists across sessions)
- Background scanning every 45 seconds
- Custom Cairo-drawn signal icon (works with any icon theme)
- Multi‑file logging with automatic rotation and crash diagnostics

## Build

```bash
meson setup build
meson compile -C build
```

Requires: `meson`, `valac`, `gtk4` (build), `libnm` (runtime).

## Usage

Single-instance application — all invocations route to the same process.

| Command | Behavior |
|---|---|
| `./build/wifiman` | Open window, or bring to focus if already running |
| `./build/wifiman --toggle` | Open window, or hide/show existing instance |
| `./build/wifiman --version` | Print version and exit |
| `./build/wifiman --debug` | Open with verbose (DEBUG) logging |

Closing the window hides it instead of quitting. Scanning and auto-connect
continue in the background. Use `--toggle` or re-launch to bring it back.

## Color scheme

Three modes via the gear menu: **System** (follows GNOME preference),
**Light**, **Dark**. The choice persists in `~/.config/wifiman/settings.ini`.

## Waybar integration

Add to `~/.config/waybar/config.jsonc`:

```jsonc
{
    "on-click": "~/.config/waybar/scripts/wifiman/build/wifiman --toggle"
}
```

After rebuilding, kill the old process first: `pkill wifiman`

## Logging

Logs are always written to `~/.local/state/wifiman/logs/`, split by
category:

| File | Contents |
|---|---|
| `app.log` | General application events |
| `wifi.log` | Wi‑Fi scan, connect, disconnect events |
| `security.log` | Authentication events |
| `crash.log` | Fatal errors, GLib ERROR/CRITICAL, POSIX signals (SIGSEGV, SIGABRT) |

Each file rotates automatically at 2 MiB, keeping up to 10 backups
(~88 MiB max total).  With `--debug`, the minimum log level is lowered
to DEBUG so verbose output appears in the category files.  Without it,
only INFO and above are written.
