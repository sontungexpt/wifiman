# wifiman

GTK4 Wi-Fi scanner written in Vala. Dependency-light: uses GTK4 and libnm,
no libadwaita.

The UI shows only networks currently detected by active scans. Saved profiles
remain in the NetworkManager backend for auto-connect and authentication reuse,
but are not listed unless the SSID is visible in scan results.

## Build

```bash
meson setup build
meson compile -C build
```

Run with:

```bash
./build/wifiman
```

## CLI

Single Gtk.Application instance. All invocations route to the same process.

| Command | Behavior |
|---|---|
| `./build/wifiman` | Launches the window, or brings it to focus if already running |
| `./build/wifiman --toggle` | Launches the window, or hides/shows the existing instance |
| `./build/wifiman --version` | Prints version and exits |
| `./build/wifiman --debug`  | Launches with file logging enabled |

Closing the window hides it instead of quitting. Scanning and auto-connect
continue in the background. Use `--toggle` or re-launch to bring it back.

## Notes

- GTK4 only, no libadwaita
- libnm is required at runtime
- This is a live Wi-Fi scanner, not a profile manager UI
- Auto-connect runs only when no active connection exists — the active
  connection is never disrupted automatically
- See `docs/architecture.md` for module responsibilities, features, and roadmap
- See `docs/changelog/` for dated records of session changes

## Logging

With `--debug`, logs are written to `~/.local/state/wifiman/wifiman.log`.
Without the flag, only GLib journald/messages are active (visible via
`journalctl`). Logs rotate automatically at 1 MiB (configurable).
