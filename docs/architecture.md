# Architecture

The code is organized as a small GTK app with a clear split between window
logic, viewmodel state, NetworkManager access, data models, and reusable row
widgets.

## Runtime flow

1. `main.vala` creates `Application`.
2. `Application` creates/presents `MainWindow`.
3. `MainWindow` instantiates `NetworkManagerService`.
4. `WifiViewModel` consumes the service and exposes GTK-friendly state.
5. `MainWindow` renders the UI and reacts to viewmodel notifications.
6. Search filters only the current scan results and keeps the results page
   visible even when there are no matches.
7. Background scan scheduling keeps cached scan data fresh while the app is
   open.
8. Saved connections are applied internally to scan-result rows for connect,
   reconnect, and forget actions, but never populate the list on their own.
9. Auto-connect triggers on scan rebuilds only when:
   - the app has finished initializing (`_started` flag)
   - auto-reconnect is enabled (`auto_reconnect_enabled`)
   - **no wifi connection is currently active** (`has_active_wifi_connection()`)
   - per-SSID cooldowns allow it
   This guarantees the active connection is never disrupted automatically.

## Module layout

```text
src/
  Application.vala            GTK application entry point
  MainWindow.vala             Top-level window and UI orchestration
  main.vala                   Program entry point
  models/WifiNetwork.vala     Wi-Fi network data model
  services/NetworkManagerService.vala
                              NetworkManager integration and actions
  viewmodels/WifiViewModel.vala
                              UI-facing network state, sorting, filtering,
                              grouping, and action forwarding
  widgets/SignalIcon.vala     Cairo-drawn Wi-Fi signal arcs (icon-theme independent)
  widgets/WifiNetworkRow.vala
                              Reusable GTK row used for network rendering
  utils/WifiUtils.vala        SSID, security, and channel helper functions
  utils/Logger.vala           Async file logging with GLib integration
                                and log rotation
data/
  resources.gresource.xml     Resource manifest for CSS and UI assets
style.css                    Theme-aware GTK CSS with @define-color variables
docs/
  architecture.md            This file
  changelog/
      2026-06-11.md            Session changes
      2026-06-12.md            Async logger, Cairo SignalIcon, bitrate fix, binding
```

## Responsibilities

### `Application`

- Owns the `Gtk.Application`
- Handles activation and command-line `--version`, `--toggle`, and `--debug`
- Initializes `Logger` with `--debug` flag for file logging
- Registers a `"toggle"` GAction for show/hide via CLI
- Keeps startup minimal

### `MainWindow`

- Owns the visible UI
- Sets up the native `GtkHeaderBar`
- Hosts the loading, empty, error, and results pages
- Keeps the search entry inside the results page so search stays visible when
  filtering down to zero matches
- Manages a separate connected-network hero container, search-empty state, and
  the listbox for available scan-result rows
- Builds connect/action dialogs with a flattened, card-free layout:
  - Titlebar: `Gtk.HeaderBar` with `show_title_buttons = false`, centered title
    via `title_widget`, close via `pack_end()` with a `Gtk.Image` +
    `Gtk.GestureClick` (no `Gtk.Button`)
  - Close button styled via `.dialog-close`: 46×46px hit-box,
    `border-radius: 0 12px 0 0`, zero padding/margin/border, hover background
  - HeaderBar's `.end` box padded to zero via
    `headerbar.dialog-headerbar .end { padding:0; margin:0; min-width:0 }`
- Search uses `Gtk.Editable.changed` signal (not `search_changed`) to fire on
  every keystroke, then debounced at 120ms via `queue_search_update()`
- Renders network rows from the viewmodel

### `WifiViewModel`

- Maintains `GLib.ListStore items`
- Tracks `scanning`, `has_networks`, `search_active`, `has_visible_networks`,
  `captive_portal`, `connectivity_text`, `scan_freshness`, and
  `last_successful_network`
- Rebuilds the list from current scan results only (`access_point != null`)
- Annotates scan-result rows with saved-connection metadata when a matching
  profile exists in NetworkManager
- Filters by search text against scan results only
- Groups visible networks into:
  - Connected (always shown as hero row when an active connection exists)
  - Available (all other detected SSIDs from scan results)
- Keeps the filtered-state distinction between:
  - "no networks found" = no scan results at all
  - "no search matches" = scan results exist but are filtered out
- Ensures saved-only profiles never affect `has_networks` or
  `has_visible_networks`
- Schedules background scans with throttling
- Refreshes derived runtime details for signal, speed, portal, IP, gateway, and
  DNS state
- Forwards connect, reconnect, disconnect, forget, and scan actions
- Auto-connects to saved networks detected in scan results with per-SSID cooldown
  (20s) and post-disconnect cooldown (30s) via Timeout-based tracking
- Hard safety guarantee: auto-connect is blocked by three guards:
  - `_started` — never runs on initial startup rebuild
  - `auto_reconnect_enabled` — user-facing toggle to disable auto-connect
  - `has_active_wifi_connection()` — refuses auto-connect when any wifi
    connection is already active/activating
- Live scan freshness label via 5-second periodic timer

### `NetworkManagerService`

- Talks to libnm directly
- Watches device, connection, and active-connection changes
- Requests scans
- Creates and activates connections
- Keeps saved connections internally for auto-connect and auth reuse
- Disconnects and forgets saved networks on request
- Does not expose a saved-network list to the UI layer
- Exposes the current connectivity state for portal / limited / full access
- Tracks all signal handler IDs for cleanup in `disconnect_signals()`,
  including `client.notify["connectivity"]` (`connectivity_notify_id`)

### `WifiNetwork`

- Holds SSID, BSSID, signal strength, security, band, and state
- Pre-computes `lower_ssid` on SSID set for O(1) case-insensitive search matching
- Exposes computed properties for:
  - `subtitle`
  - `primary_status` (including a "Previously saved" badge for known profiles)
  - `primary_status_style`
- Tracks transient `auto_connecting` state with `connecting_status_text`
  for live "Auto-connecting..." badge feedback
- Holds runtime metrics for:
  - signal dBm estimate
  - bitrate
  - scan freshness
  - IP / gateway / DNS
  - warning and health text

### `SignalIcon`

- Custom `Gtk.DrawingArea` that draws Wi-Fi signal arcs with Cairo, bypassing
  the icon theme entirely (fixes themes like Papirus-Dark where all
  `network-wireless-signal-*-symbolic` names resolve to the same fallback icon)
- Exposes an `int strength` property (0–100) that triggers `queue_draw()`
  on change via `notify["strength"]` binding
- Draws 4 concentric arcs (radii 4, 8, 12, 16) sweeping 225°→315° — the
  classic Wi-Fi fan shape, respecting CSS color and opacity via
  `Gtk.StyleContext.get_color()`
- Arc center (`cy = height - 3`) is shifted up 3px from the widget bottom
  so the visual center of the arcs aligns with the widget center, matching
  the badge text baseline
- Supports `.signal-icon` CSS class for theme integration and hero-network
  color overrides

### `WifiNetworkRow`

- Renders one network row with a `SignalIcon` widget for the signal indicator
- Only handles network items (the HEADER branch was removed — unreachable)
- Updates live when network properties change, including auto-connect status
- Adds the hero styling for the connected network
- Exposes a right-click action path for row menus and details
- Renders compact metric pills for signal and speed
- `network.strength` is bound to `signal_icon.strength` via `GLib.Binding`
  with `SYNC_CREATE` (no transform needed) — handles initial sync and
  subsequent property changes automatically. The old `update_signal()` method
  that manually set the strength before binding creation was removed as
  redundant — `SYNC_CREATE` already copies the initial value.
- Signal handlers for `security`, `frequency`, and `access-point-count`
  are not connected — these properties are set once during AP discovery
  and never change, making their handlers dead code.
- Stores `network` as `unowned` to break the reference cycle: signal closures
  on the WifiNetwork keep the row alive, but the row no longer keeps the
  network alive. When `rebuild()` removes a network from `networks_by_ssid`,
  the network is finalized, signal handlers are disconnected, and the row
  is finalized — no orphaned objects leak across scan cycles.
- All signal handler IDs are properly stored and disconnected in
  `disconnect_network()` — no handler leaks across `set_item()` calls.

### `Logger`

- Logs to `~/.local/state/wifiman/wifiman.log` when file logging is enabled
- Integrates with GLib logging APIs (`GLib.debug`, `GLib.message`, etc.) for
  journald/stderr output
- Structured format: `[timestamp] [LEVEL] [Module] message`
- Configurable max file size with automatic rotation (renames to `.old`)
- Guarded by `--debug` CLI flag — no file I/O when disabled

**Asynchronous design:**
- All public API methods (`debug`, `info`, `warn`, `error`) only enqueue a
  `LogEntry` onto a lock-free `AsyncQueue` — they never perform file I/O
- A dedicated writer thread (`"wifiman-log"`) consumes the queue:
  - `timeout_pop(100ms)` provides batching — bursts are collected without
    per-message wakeup
  - After each batch, file size is checked and rotation is performed
    atomically inside the writer thread
  - The file handle is flushed after each batch
- `debug()` and `info()` gate on `debug_on` (mirrors `--debug`) before any
  formatting or GLib calls — true no-ops when `--debug` is not passed
- `warn()` and `error()` always format and always go to journald regardless
- `shutdown()` sets an atomic stop flag, pushes a sentinel entry to wake the
  writer, then calls `join()` — guarantees all queued entries are flushed
- The writer thread only exits after draining the queue and closing the file
- Queue uses a full destroy function (`g_async_queue_new_full`) as a safety
  net — any entries remaining on destruction are freed automatically

### `WifiUtils`

- Converts SSID bytes to safe display strings
- Maps NM security flags to app-level security values
- Formats bitrate, signal dBm, scan age, and connection health labels
- Dead functions removed: `signal_quality_label`, `join_nonempty`,
  `connectivity_to_style`, `active_connection_reason_to_label`,
  `device_state_reason_to_label`, `ssid_equal` (none called anywhere)

## Features

- Scan for nearby Wi-Fi networks in real time
- Show only SSIDs currently detected in scan results
- Toggle wireless on or off from the menu (turning Wi-Fi OFF closes the app)
- Search available networks by SSID (scan results only)
- Keep the search field visible even when no results match
- Always show the connected network as a hero row, even when it is not in the
  current scan list or does not match the active search filter
- Show all other detected networks in a single available list
- Show a subtle "Previously saved" badge when a detected SSID matches a saved
  profile
- Show signal strength as a dBm-style label alongside bars
- Show bitrate, band, scan freshness, and connection health where available
- Detect and surface captive portal state in the results view
- Connect to open networks directly
- Auto-connect to known (saved) networks when detected in scan results, without password prompts
- 20-second cooldown per SSID to prevent reconnect loops
- 30-second cooldown after manual disconnect before auto-reconnect
- Hard safety guarantee: never disconnects the active connection automatically
  (guarded by startup flag, auto-reconnect toggle, and active-connection detection)
- Show "Auto-connecting..." status badge during automatic connection attempts
- Prompt for password or username/password only when no saved profile exists or
  authentication fails
- Show actions for connected or previously saved networks detected in scan:
  - Connect
  - Reconnect
  - Disconnect
  - Forget
- Open a network details dialog with IP, gateway, DNS, and health data
- Support background scans with throttling
- Debounce search input to keep the list responsive
- Support row context menus via right click
- Refresh network state from NetworkManager
- Live scan freshness label that ticks every 5 seconds
- Show loading, empty, error, and search-empty states:
  - empty = no scan results
  - search-empty = scan results exist but none match the filter
- Use GTK theme colors and native GTK4 widgets only

## Enhanced Feature Spec

Some items below are already implemented in the current codebase; the rest are
still a roadmap for the next pass.

The current app is already functional as a live environment scanner. The
following is the target production spec for the next architecture pass. These
items extend the current behavior without changing the scan-results-only UI
model.

### Network intelligence

- Signal dBm estimate is now shown alongside bars
- Band detection is shown for 2.4 GHz / 5 GHz / 6 GHz when available
- Link speed and bitrate are shown when NetworkManager exposes them
- Weak signal and insecure-network warnings are surfaced
- Channel congestion detection remains a future enhancement

### Smart connection behavior

- Auto-connect to saved networks when detected in scan results (implemented)
- Per-network auto-reconnect control (roadmap)
- Add optional roaming assist for switching to stronger known networks (roadmap)
- Show explicit failure reasons for common connection problems
  - wrong password
  - authentication failure
  - DHCP timeout
  - disconnected by AP
- Remember the last successful network per session or location

### Captive portal handling

- Detect captive portal state separately from normal connection state
- Show a non-blocking banner in the results shell
- Provide an `Open Login Page` action when a portal is detected

### Advanced network actions

- Edit saved network settings, including priority and auto-connect
- Show a detailed info panel for the selected network
- Offer `Reconnect` as a separate troubleshooting action
- Support `Forget all networks` with confirmation

### Performance and scanning

- Support background scanning with throttling
- Debounce search input so large lists stay responsive
- Cache the last scan for instant repainting
- Show a freshness label such as `Last updated 2s ago`
- Group duplicate SSIDs from multiple access points into one logical network

### UX and visual behavior

- Keep the connected network as a compact dashboard card
- Show SSID, signal strength, IP address, and speed in the hero area
- Use skeleton rows for initial loading instead of only a spinner
- Animate scanning, connecting, and error states subtly
- Keep keyboard navigation and row activation fully accessible
- Support context menus on rows for desktop and long-press interaction

### Diagnostics

- Run quick ping checks to the gateway and a public endpoint
- Expose latency and connection health
- Show DNS and gateway information in the details panel
- Classify connection health as stable, weak, or unstable

### Security and trust

- Label encryption type clearly: WPA2, WPA3, Open, Enterprise
- Warn on open networks without overwhelming the UI
- Show enterprise auth requirements explicitly
- Add an optional setting to ignore open networks automatically

## Recommended Architecture for the Enhanced Spec

Keep the current separation, then extend it in layers:

- `MainWindow` and row widgets remain the GTK4 UI layer
- `NetworkManagerService` remains the thin D-Bus / libnm adapter
- `WifiViewModel` remains the GTK-facing state layer
- add a diagnostics layer for ping, latency, and health checks
- add an insight layer for signal dBm, speed, band, portal state, and trust
- keep UI updates diff-based so scan updates do not rebuild everything
- if libadwaita is introduced later, keep it isolated to presentation only

Suggested additions:

- `models/NetworkMetrics.vala` for signal, speed, latency, and health values
- `models/ConnectionState.vala` for portal, roaming, and error state
- `services/NetworkDiagnosticsService.vala` for ping and health probes
- `viewmodels/WifiViewModel.vala` extended with derived UI state and diffs
- `viewmodels/NetworkRowState.vala` for row-level badge, warning, and action
  state
- `services/CaptivePortalService.vala` for portal detection and banner actions
- `services/RoamingAssistService.vala` for optional stronger-network switching

## Base Feature Mapping

- Scan nearby networks -> continuous scanning plus cached freshness labels
- Wireless toggle -> closes the app when turned OFF, plus auto-reconnect policy handling
- Search by SSID -> debounced search with persistent search field
- Connected hero + available scan results -> same grouping, plus richer badges
- Connected hero row -> compact dashboard with SSID, signal, IP, and speed
- Open network connect -> same flow, plus trust warnings and ignore controls
- Password / enterprise prompts -> same dialogs, plus clearer failure reasons
- Connect / Disconnect / Forget -> add reconnect, edit, and bulk forget actions
- Loading / empty / error / search-empty -> add skeleton loading and portal banners
- GTK theme-aware UI -> keep native GTK surfaces, optionally layer libadwaita later

## UI / UX Layout Suggestions

- Keep a single native header bar with refresh, menu, and title area
- Preserve the centered results shell and search field at the top of content
- Keep the connected network as a compact dashboard card with:
  - SSID
  - signal dBm
  - IP address
  - link speed
  - latency/health state
- Render available scan-result networks in a single grouped list panel
- Use subtle badges for encryption, band, warnings, and portal state
- Keep row activation, context menus, and keyboard navigation consistent
- Prefer expandable details for advanced metadata instead of cramming
  everything into the main row

## Implementation Outline

Pseudo-code for the state split:

```vala
class WifiViewModel : Object {
    public ListStore items { get; private set; }
    public bool scanning { get; private set; }
    public bool search_active { get; private set; }
    public bool has_visible_networks { get; private set; }

    // Derived UI state
    public NetworkMetrics? hero_metrics { get; private set; }
    public CaptivePortalState portal_state { get; private set; }
    public ConnectionHealth health { get; private set; }

    // Actions
    public async void scan ()
    public async void connect_network (...)
    public async void reconnect_network (...)
    public async void disconnect_network (...)
    public async void forget_network (...)
    public async void edit_network (...)
}
```

Recommended diff-based update strategy:

1. Update raw NetworkManager models in the service layer.
2. Recompute derived network objects in the viewmodel.
3. Only rebuild rows whose state changed.
4. Keep search/filter state separate from network discovery state.
5. Keep captive portal and diagnostics state as orthogonal flags.

## UI structure

The results page is built from native GTK4 widgets:

- `GtkHeaderBar` in the window titlebar
- `GtkStack` for loading, empty, error, and results states
- centered content shell with fixed width
- `Gtk.SearchEntry` inside the content area (uses `Gtk.Editable.changed` signal)
- a status strip under search showing scan freshness and connectivity state
- a portal banner that appears when NetworkManager reports captive portal state
- hero container for the connected network
- search-empty state block shown only when search text yields no matches
- `GtkListBox` for available scan-result networks
- an expandable details dialog for advanced network data

## Styling

The app uses a single CSS resource loaded from `style.css` through GTK
resources. The stylesheet is theme-aware and keeps the shell neutral while
reserving strong accent styling for the connected hero row.

Dark mode colors are defined as `@define-color` variables at the top of the
file (`@dark-bg`, `@dark-surface`, `@dark-text`, `@dark-accent`, etc.) and
referenced throughout the dark-mode section. All `rgba()` calls in dark mode
use `alpha(@variable, ...)` instead.

Popover styles are split into a base section (applies to both light and dark
modes: `border-radius: 12px`, `border: none`, `padding: 0`, `box-shadow`) and
a dark-mode-only override section (background colors only).

Key style classes:

- `.content-shell`
- `.premium-search`
- `.network-panel`
- `.network-listbox`
- `.network-row`
- `.network-row-content`
- `.hero-network`
- `.status-badge`
- `.network-metric`
- `.section-title`
- `.search-empty`
- `.portal-banner`
- `.details-grid`
- `.dialog-window`
- `.dialog-headerbar`
- `.dialog-close` — 46×46px hit-box, `border-radius: 0 12px 0 0`,
  zero padding/margin/border, hover background
- `.dialog-body`
- `.dialog-input` — compact entry styling (28px min-height, 6px border-radius)
- `.dialog-field-label`
- `.dialog-cancel`
- `.dialog-error`

Dark mode uses `.dark-mode` class on windows and popovers (not `@media`
queries), toggled at runtime via CSS class sync.
