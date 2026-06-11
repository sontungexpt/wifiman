# Wi-Fi Vala

GTK4 Wi-Fi manager written in Vala. The app is intentionally dependency-light:
it uses GTK4 and libnm, and does not depend on libadwaita.

## Architecture

The code is organized as a small GTK app with a clear split between window
logic, viewmodel state, NetworkManager access, data models, and reusable row
widgets.

### Runtime flow

1. `main.vala` creates `Application`.
2. `Application` creates/presents `MainWindow`.
3. `MainWindow` instantiates `NetworkManagerService`.
4. `WifiViewModel` consumes the service and exposes GTK-friendly state.
5. `MainWindow` renders the UI and reacts to viewmodel notifications.
6. Search updates are handled in the viewmodel and keep the results page
   visible even when there are no matches.

### Module layout

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
  widgets/WifiNetworkRow.vala
                              Reusable GTK row used for network rendering
  utils/WifiUtils.vala        SSID, security, and icon helper functions
data/
  resources.gresource.xml     Resource manifest for CSS and UI assets
style.css                    Theme-aware GTK CSS
```

## Responsibilities

### `Application`

- Owns the `Gtk.Application`
- Handles activation and command-line `--version`
- Keeps startup minimal

### `MainWindow`

- Owns the visible UI
- Sets up the native `GtkHeaderBar`
- Hosts the loading, empty, error, and results pages
- Keeps the search entry inside the results page so search stays visible when
  filtering down to zero matches
- Manages a separate connected-network hero container, search-empty state, and
  the listbox for saved/available rows
- Builds the connect/action dialogs
- Renders network rows from the viewmodel

### `WifiViewModel`

- Maintains `GLib.ListStore items`
- Tracks `scanning`, `has_networks`, `search_active`, `has_visible_networks`,
  and `wireless_enabled`
- Rebuilds the list from NetworkManager data
- Filters by search text
- Groups networks into:
  - Connected
  - Saved
  - Available
- Keeps the filtered-state distinction between "no networks found" and "no
  search matches"
- Forwards connect, disconnect, forget, and scan actions

### `NetworkManagerService`

- Talks to libnm directly
- Watches device, connection, and active-connection changes
- Requests scans
- Creates and activates connections
- Disconnects and forgets saved networks

### `WifiNetwork`

- Holds SSID, BSSID, signal strength, security, band, and state
- Exposes computed properties for:
  - `subtitle`
  - `signal_icon_name`
  - `primary_status`
  - `primary_status_style`

### `WifiNetworkRow`

- Renders one network row
- Handles header rows and network rows
- Updates live when network properties change
- Adds the hero styling for the connected network

### `WifiUtils`

- Converts SSID bytes to safe display strings
- Maps signal strength to symbolic icons
- Maps NM security flags to app-level security values

## Features

- Scan for nearby Wi-Fi networks
- Toggle wireless on or off from the menu
- Search networks by SSID
- Keep the search field visible even when no results match
- Show connected, saved, and available networks in separate sections
- Highlight the connected network as a hero row
- Connect to open networks directly
- Prompt for password or username/password when needed
- Show actions for connected or saved networks:
  - Connect
  - Disconnect
  - Forget
- Refresh network state from NetworkManager
- Show loading, empty, error, and search-empty states
- Use GTK theme colors and native GTK4 widgets only

## UI structure

The results page is built from native GTK4 widgets:

- `GtkHeaderBar` in the window titlebar
- `GtkStack` for loading, empty, error, and results states
- centered content shell with fixed width
- `GtkSearchEntry` inside the content area
- hero container for the connected network
- search-empty state block shown only when search text yields no matches
- `GtkListBox` for saved and available networks

## Styling

The app uses a single CSS resource loaded from `style.css` through GTK
resources. The stylesheet is theme-aware and keeps the shell neutral while
reserving strong accent styling for the connected hero row.

Key style classes:

- `.content-shell`
- `.premium-search`
- `.network-panel`
- `.network-listbox`
- `.network-row`
- `.network-row-content`
- `.hero-network`
- `.status-badge`
- `.section-title`
- `.search-empty`

## Build

```bash
meson setup build
meson compile -C build
```

Run the app with:

```bash
./build/wifi-vala
```

## Notes

- GTK4 only, no libadwaita
- libnm is required at runtime
- The UI is theme-aware and designed to work with standard GTK light/dark
  themes
- Search never hides the search bar; zero-match searches keep the results page
  visible and show a dedicated no-results message instead
