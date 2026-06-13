# wifiman

GTK4 Wi-Fi scanner written in Vala. Dependency-light: uses GTK4 and libnm,
no libadwaita. Designed as a Waybar popup but also runs standalone.

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

## Color scheme

Three modes via the gear menu: **System**, **Light**, **Dark**.

- **System** reads `org.gnome.desktop.interface` GSettings (`color-scheme`
  key) — respects the GNOME/desktop preference.
- **Light** / **Dark** override explicitly.
- The choice persists in `~/.config/wifiman/settings.ini`.

The `.dark-mode` CSS class is applied to all windows and the popover menu
when dark mode is active. All styling hangs off this class — there is no
separate theme file.

### Mismatched-theme support

The app defines its own colour tokens rather than relying on the active
GTK theme variables. This makes it compatible with any dark theme while
still providing correct colours in light mode:

| Token | Light value | Dark value |
|---|---|---|
| `text-primary` | `#111827` | `#f1f5f9` |
| `text-secondary` | `#6b7280` | `#94a3b8` |
| `text-tertiary` | `#4b5563` | `#d1d5db` |
| `bg` / `surface` | `#f4f5f6` / `#ffffff` | `#090d16` / `#111827` |
| `accent` | `#3584e4` | `#38bdf8` |
| `warning` | `#d97706` | (from theme) |
| `success` | `#059669` | (from theme) |
| `error` | `#dc2626` | `#dc2626` |

Badge variant colours (`.connected`, `.warning`, `.connecting`, `.failed`)
use hardcoded hex values instead of `@accent_bg_color` / `@warning_color`
etc., because those variables resolve to the dark theme's colours even
when `.dark-mode` is absent.

## CSS structure

`style.css` is compiled into the binary via GResource and loaded at
`STYLE_PROVIDER_PRIORITY_APPLICATION`. Key sections:

1. **Colour tokens** — `@define-color` blocks for dark and light modes.
2. **Base layout** — window, headerbar, scroll containers, panels.
3. **Network list** — rows, separators, badges, metrics, hero card.
4. **Dialogs** — network actions, password entry, detail grid.
5. **Popover** — settings menu with explicit sub-node targeting
   (`popover.background > contents`, `popover.background > arrow`, etc.).
6. **Dark mode** — every visual rule is repeated under `.dark-mode` with
   the dark colour tokens.

### Light mode pattern

The light mode rules sit before the `DARK MODE` section and use plain
selectors (no `.dark-mode` prefix). The dark mode section duplicates each
rule with `.dark-mode` — same specificity, so the later definition wins
when the class is present.

Popover backgrounds are set via inline CSS at `APPLICATION + 1` priority
to override the GTK theme's `@popover_bg_color` internal variable:

```vala
css.load_from_string (
    ".dark-mode { background: #111827; ... } " +
    "popover:not(.dark-mode) { background: #ffffff; ... }"
);
```

## Waybar integration

Typical `~/.config/waybar/config.jsonc` entry:

```jsonc
{
    "on-click": "~/.config/waybar/scripts/wifiman/build/wifiman --toggle"
}
```

The Gtk.Application singleton means clicking re-activates the existing
process — the binary is only loaded once. After rebuilding, kill the old
process first:

```bash
pkill wifiman
```

Then click the Waybar icon to start the fresh binary.

## Notes

- GTK4 only, no libadwaita
- libnm is required at runtime
- This is a live Wi-Fi scanner, not a profile manager UI
- Auto-connect runs only when no active connection exists — the active
  connection is never disrupted automatically
- See `docs/architecture.md` for module responsibilities, features, and roadmap
- See `docs/changelog/` for dated records of session changes

## Recent fixes (2026-06-13)

- **Crash fix (Vala ABI bug):** `gtk_widget_set_sensitive` crash in connect
  dialog caused by Vala generating broken 1-parameter signal wrappers for local
  functions. Replaced with inline lambdas.
- **Dialog window leak:** Both connect and detail dialogs are now **destroyed**
  (not hidden) on close, preventing accumulation of hidden GtkWindow objects.
- **Manual connect guard:** Prevents auto-connect from racing against
  user-initiated password connections. Includes 120s safety timeout and
  `cancel_manual_connect()` on dialog close.
- **SSID corruption:** Non-UTF-8 SSIDs now show escaped-hex (`\xNN`) instead
  of `U+FFFD` replacement characters.
- **Password persistence:** Saved connection passwords are committed to
  NetworkManager via `commit_changes_async` immediately after `apply_secrets`.
- **Light mode color polish:** Refined surface hierarchy — window bg, headerbar,
  dialog body, and dialog headerbar now have distinct tones instead of nearly
  identical grays. Warmer overall palette, softer card shadows, lighter borders.

## Logging

With `--debug`, logs are written to `~/.local/state/wifiman/wifiman.log`.
Without the flag, only GLib journald/messages are active (visible via
`journalctl`). Logs rotate automatically at 1 MiB (configurable).

File writes are asynchronous — a dedicated writer thread consumes entries
from a lock-free queue. Logging calls never block on disk I/O. The writer
thread drains batches at 100ms intervals and performs rotation internally.

## Signal icon

The Wi-Fi signal indicator uses a custom `Gtk.DrawingArea` (`SignalIcon`)
that draws 4 concentric Cairo arcs — no dependency on icon theme icons.
Works with any theme (including Papirus-Dark where `network-wireless-signal-*-symbolic`
icons all resolve to the same fallback).

`network.strength` is bound to `signal_icon.strength` via `GLib.Binding`
with `SYNC_CREATE` — no manual signal handler needed.
