using NM;

/**
 * Kinds of items that can appear in the network list.
 */
public enum WifiListItemKind {
    /**
     * A section header label (e.g. "Connected", "Available").
     */
    HEADER,

    /**
     * A concrete WifiNetwork entry.
     */
    NETWORK
}

/**
 * A display item in the flat network list, wrapping either a
 * header title or a WifiNetwork.
 */
public class WifiListItem : GLib.Object {
    /**
     * Whether this item is a section header or a network entry.
     */
    public WifiListItemKind kind { get; construct; }

    /**
     * The section title (for HEADER items) or empty.
     */
    public string title { get; construct; default = ""; }

    /**
     * The wrapped WifiNetwork (for NETWORK items) or null.
     */
    public WifiNetwork? network { get; construct; default = null; }

    /**
     * Construct a header list item for section titles.
     *
     * @param title  The section header text.
     */
    public WifiListItem.header (string title) {
        GLib.Object (kind: WifiListItemKind.HEADER, title: title);
    }

    /**
     * Construct a network list item wrapping a WifiNetwork.
     *
     * @param network  The network to wrap.
     */
    public WifiListItem.for_network (WifiNetwork network) {
        GLib.Object (kind: WifiListItemKind.NETWORK, network: network);
    }
}

/**
 * ViewModel for the Wi-Fi manager UI.
 *
 * Owns the full list of networks as a GLib.ListStore, manages
 * scanning, auto-connect, search filtering, and connectivity
 * state.  Connects to NetworkManagerService for all NM events.
 */
public class WifiViewModel : GLib.Object {
    /**
     * Emitted when a non-recoverable error occurs.
     *
     * @param message  Human-readable error description.
     */
    public signal void error (string message);

    /**
     * The flat list of items (headers + networks) displayed in the UI.
     */
    public GLib.ListStore items { get; private set; }

    /**
     * Whether a scan is currently in progress.
     */
    public bool scanning { get; private set; default = false; }

    /**
     * Whether any networks have been discovered via scanning.
     */
    public bool has_networks { get; private set; default = false; }

    /**
     * Whether the user has entered a search query.
     */
    public bool search_active { get; private set; default = false; }

    /**
     * Whether any networks match the current search filter.
     */
    public bool has_visible_networks { get; private set; default = false; }

    /**
     * Whether a network is currently connected.
     */
    public bool has_connected_network { get; private set; default = false; }

    /**
     * Whether a captive portal is detected.
     */
    public bool captive_portal { get; private set; default = false; }

    /**
     * Human-readable connectivity label (e.g. "Internet access").
     */
    public string connectivity_text { get; private set; default = ""; }

    /**
     * Human-readable scan age text (e.g. "Updated 30 seconds ago").
     */
    public string scan_freshness { get; private set; default = "No recent scan"; }

    /**
     * SSID of the last successfully connected network.
     */
    public string last_successful_network { get; private set; default = ""; }

    /**
     * Whether the Wi-Fi radio is enabled.
     *
     * Setting this property toggles the radio via NetworkManagerService.
     */
    public bool wireless_enabled {
        get { return service.wireless_enabled; }
        set {
            service.wireless_enabled = value;
            rebuild ();
        }
    }

    private NetworkManagerService service;
    private GLib.HashTable<string, WifiNetwork> networks_by_ssid =
        new GLib.HashTable<string, WifiNetwork> (GLib.str_hash, GLib.str_equal);
    private string search_text = "";
    private uint settle_scan_id = 0;
    private uint background_scan_id = 0;
    private uint freshness_timer_id = 0;
    private int64 freshest_scan = -1;
    private GLib.HashTable<string, bool> auto_connect_cooldowns;
    private GLib.HashTable<string, bool> disconnect_cooldowns;
    private const uint AUTO_CONNECT_COOLDOWN_MS = 20000;
    private const uint DISCONNECT_COOLDOWN_MS = 30000;
    private bool _started = false;
    private bool _hidden = false;
    private bool _manual_connecting = false;
    private string _manual_connecting_ssid = "";
    private uint _manual_connect_timeout_id = 0;
    private const uint MANUAL_CONNECT_TIMEOUT_MS = 120000;
    private ulong service_changed_id = 0;
    private ulong service_scan_started_id = 0;
    private ulong service_scan_finished_id = 0;
    private ulong service_error_id = 0;

    /**
     * Whether auto-reconnect to previously saved networks is enabled.
     */
    public bool auto_reconnect_enabled { get; set; default = true; }

    /**
     * Notify the ViewModel when the window becomes hidden or visible.
     * While hidden, periodic timers (freshness, background scan) are
     * skipped to save CPU.
     */
    public void set_window_hidden (bool hidden) {
        _hidden = hidden;
    }

    /**
     * Shut down the ViewModel: remove all timers and disconnect
     * service signal handlers.  Call this before application quit
     * to ensure the process can exit cleanly.
     */
    public void shutdown () {
        Logger.info ("WifiViewModel", "Shutting down");
        _started = false;
        if (settle_scan_id != 0) {
            Source.remove (settle_scan_id);
            settle_scan_id = 0;
        }
        if (background_scan_id != 0) {
            Source.remove (background_scan_id);
            background_scan_id = 0;
        }
        if (freshness_timer_id != 0) {
            Source.remove (freshness_timer_id);
            freshness_timer_id = 0;
        }
        if (_manual_connect_timeout_id != 0) {
            Source.remove (_manual_connect_timeout_id);
            _manual_connect_timeout_id = 0;
        }

    }

    /**
     * Initialise the ViewModel, connect service signals, and start
     * background scanning.
     *
     * @param service  The NetworkManagerService to bind to.
     */
    public WifiViewModel (NetworkManagerService service) {
        Logger.info ("WifiViewModel", "Initializing WifiViewModel");
        this.service = service;
        items = new GLib.ListStore (typeof (WifiListItem));

        service_changed_id = service.changed.connect (() => schedule_rebuild ());
        service_scan_started_id = service.scan_started.connect (() => {
            scanning = true;
        });
        service_scan_finished_id = service.scan_finished.connect (() => {
            scanning = false;
            schedule_rebuild ();
        });
        service_error_id = service.error.connect ((message) => error (message));

        auto_connect_cooldowns = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
        disconnect_cooldowns = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);

        rebuild ();
        start_background_scan ();
        freshness_timer_id = Timeout.add_seconds (5, tick_freshness);
        _started = true;
    }

    /**
     * Clean up timers and signal handlers on disposal.
     */
    ~WifiViewModel () {
        if (settle_scan_id != 0) {
            Source.remove (settle_scan_id);
            settle_scan_id = 0;
        }
        if (background_scan_id != 0) {
            Source.remove (background_scan_id);
            background_scan_id = 0;
        }
        if (freshness_timer_id != 0) {
            Source.remove (freshness_timer_id);
            freshness_timer_id = 0;
        }
        if (_manual_connect_timeout_id != 0) {
            Source.remove (_manual_connect_timeout_id);
            _manual_connect_timeout_id = 0;
        }
    }

    /**
     * Set the search filter text and rebuild the displayed items.
     *
     * The search is case-insensitive and stripped of leading/trailing
     * whitespace.
     *
     * @param text  The new search query.
     */
    public void set_search_text (string text) {
        Logger.debug ("WifiViewModel", "Setting search text: \"%s\"", text);
        var normalized = text.strip ().down ();
        if (normalized == search_text) {
            return;
        }

        search_text = normalized;
        search_active = search_text.length > 0;
        rebuild_items ();
    }

    /**
     * Request a new Wi-Fi scan from NetworkManager.
     *
     * Async method, does not block the UI thread.  The scanning
     * property is set to true during the scan.
     */
    public async void scan () {
        if (scanning) {
            Logger.debug ("WifiViewModel", "Scan already in progress, skipping");
            return;
        }

        Logger.info ("WifiViewModel", "Starting Wi-Fi scan");
        try {
            yield service.request_scan ();
            schedule_rebuild ();
        } catch (GLib.Error e) {
            scanning = false;
            error (e.message);
            rebuild ();
        }
    }

    /**
     * Connect to a network, optionally supplying a password and username.
     *
     * Async method, does not block the UI thread.
     *
     * @param network   The network to connect to.
     * @param password  Optional WPA password or 802.1X password.
     * @param username  Optional 802.1X username.
     * @throws Error if NetworkManager rejects the connection request.
     */
    public void cancel_manual_connect () {
        Logger.info ("WifiViewModel", "Manual connect cancelled for: %s", _manual_connecting_ssid);
        _manual_connecting = false;
        _manual_connecting_ssid = "";
        if (_manual_connect_timeout_id != 0) {
            Source.remove (_manual_connect_timeout_id);
            _manual_connect_timeout_id = 0;
        }
    }

    public async void connect_network (WifiNetwork network, string? password = null, string? username = null) throws GLib.Error {
        Logger.info ("WifiViewModel", "Connecting to network: %s", network.ssid);

        _manual_connecting = true;
        _manual_connecting_ssid = network.ssid;
        if (_manual_connect_timeout_id != 0) {
            Source.remove (_manual_connect_timeout_id);
        }
        _manual_connect_timeout_id = Timeout.add (MANUAL_CONNECT_TIMEOUT_MS, () => {
            Logger.warn ("WifiViewModel", "Manual connect timeout for: %s", _manual_connecting_ssid);
            _manual_connecting = false;
            _manual_connecting_ssid = "";
            _manual_connect_timeout_id = 0;
            return Source.REMOVE;
        });

        try {
            yield service.connect_network (network, password, username);
            Logger.info ("WifiViewModel", "connect_network returned successfully for: %s", network.ssid);

            // For saved connections with no new password, wait briefly for
            // NM to process the async auth result.
            if (network.saved_connection != null && (password == null || password.length == 0)) {
                for (int i = 0; i < 14; i++) {
                    yield sleep_ms (500);
                    if (network.is_connected) {
                        Logger.info ("WifiViewModel", "Connection confirmed for: %s", network.ssid);
                        return;
                    }
                    if (network.connection_failed) {
                        Logger.warn ("WifiViewModel", "Connection failed for %s: saved credentials rejected", network.ssid);
                        throw new NetworkManagerServiceError.CONNECTION_FAILED (
                            "Authentication failed. The saved password may have changed."
                        );
                    }
                }
                Logger.warn ("WifiViewModel", "Connection timed out (async) for: %s", network.ssid);
                throw new NetworkManagerServiceError.CONNECTION_FAILED (
                    "Connection timed out. The saved password may be incorrect."
                );
            }
        } catch (GLib.Error e) {
            Logger.warn ("WifiViewModel", "connect_network failed for %s: %s", network.ssid, e.message);
            _manual_connecting = false;
            _manual_connecting_ssid = "";
            if (_manual_connect_timeout_id != 0) {
                Source.remove (_manual_connect_timeout_id);
                _manual_connect_timeout_id = 0;
            }
            throw e;
        }
    }

    private async void sleep_ms (uint ms) {
        Timeout.add (ms, () => {
            sleep_ms.callback ();
            return Source.REMOVE;
        });
        yield;
    }

    /**
     * Disconnect and reconnect to a network.
     *
     * Useful for refreshing a stale connection without closing the
     * dialog.  Async, does not block the UI thread.
     *
     * @param network   The network to reconnect.
     * @param password  Optional new password.
     * @param username  Optional new 802.1X username.
     * @throws Error if NetworkManager rejects the request.
     */
    public async void reconnect_network (WifiNetwork network, string? password = null, string? username = null) throws GLib.Error {
        Logger.info ("WifiViewModel", "Reconnecting network: %s", network.ssid);
        if (network.active_connection != null) {
            yield service.disconnect_network (network);
        }
        yield service.connect_network (network, password, username);
    }

    /**
     * Disconnect an active network connection.
     *
     * Async, does not block the UI thread.
     *
     * @param network  The network to disconnect.
     * @throws Error if NetworkManager rejects the request.
     */
    public async void disconnect_network (WifiNetwork network) throws GLib.Error {
        Logger.info ("WifiViewModel", "Disconnecting network: %s", network.ssid);
        yield service.disconnect_network (network);
    }

    /**
     * Forget a saved network connection.
     *
     * Removes the connection profile from NetworkManager.  Async,
     * does not block the UI thread.
     *
     * @param network  The network to forget.
     * @throws Error if NetworkManager rejects the request.
     */
    public async void forget_network (WifiNetwork network) throws GLib.Error {
        Logger.info ("WifiViewModel", "Forgetting network: %s", network.ssid);
        yield service.forget_network (network);
    }

    /**
     * Attempt to auto-connect to a saved network if no active Wi-Fi
     * connection exists.
     *
     * Respects cooldown timers for auto-connect and manual disconnect.
     *
     * @param network  The saved network to try.
     */
    public async void try_auto_connect (WifiNetwork network) {
        if (!_started || !auto_reconnect_enabled) {
            Logger.debug ("WifiViewModel", "Auto-connect skipped: _started=%s, auto_reconnect_enabled=%s", _started.to_string (), auto_reconnect_enabled.to_string ());
            return;
        }
        if (has_active_wifi_connection ()) return;
        if (network.is_connected || network.is_connecting || network.auto_connecting) {
            return;
        }
        if (network.saved_connection == null) {
            return;
        }
        if (network.access_point == null || network.device == null) {
            return;
        }
        if (auto_connect_cooldowns.contains (network.ssid)) {
            return;
        }
        if (disconnect_cooldowns.contains (network.ssid)) {
            return;
        }

        network.auto_connecting = true;
        network.connecting_status_text = "Auto-connecting...";
        auto_connect_cooldowns.insert (network.ssid, true);
        Timeout.add (AUTO_CONNECT_COOLDOWN_MS, () => {
            auto_connect_cooldowns.remove (network.ssid);
            return Source.REMOVE;
        });

        try {
            Logger.info ("WifiViewModel", "Auto-connecting to: %s", network.ssid);
            yield service.connect_network (network, null, null);
        } catch (GLib.Error e) {
            Logger.warn ("WifiViewModel", "Auto-connect failed for %s: %s", network.ssid, e.message);
            network.auto_connecting = false;
            network.connecting_status_text = "";
        }
    }

    /**
     * Record a manual disconnect to prevent auto-reconnect for a
     * cooldown period.
     *
     * @param ssid  The SSID that was manually disconnected.
     */
    public void record_disconnect (string ssid) {
        Logger.debug ("WifiViewModel", "Recording disconnect cooldown for: %s", ssid);
        disconnect_cooldowns.insert (ssid, true);
        Timeout.add (DISCONNECT_COOLDOWN_MS, () => {
            disconnect_cooldowns.remove (ssid);
            return Source.REMOVE;
        });
    }

    /**
     * Check whether any Wi-Fi connection is in ACTIVATED or ACTIVATING
     * state.
     *
     * @return true if there is an active or activating Wi-Fi connection.
     */
    private bool has_active_wifi_connection () {
        foreach (var active in service.get_active_connections ()) {
            if (active.get_connection_type () != "802-11-wireless") continue;
            var state = active.get_state ();
            if (state == NM.ActiveConnectionState.ACTIVATED || state == NM.ActiveConnectionState.ACTIVATING) {
                return true;
            }
        }
        return false;
    }

    /**
     * Attempt auto-connect on all saved networks that are not currently
     * connected.
     *
     * Iterates over every known network and tries auto-connect if
     * eligible.
     */
    private void try_auto_connect_all () {
        if (!_started || !auto_reconnect_enabled) return;
        Logger.debug ("WifiViewModel", "Checking networks for auto-connect");

        if (_manual_connecting) {
            if (_manual_connecting_ssid.length > 0) {
                var network = networks_by_ssid.lookup (_manual_connecting_ssid);
                if (network != null && (network.is_connected || network.connection_failed)) {
                    Logger.info ("WifiViewModel", "Manual connect resolved for: %s (connected=%s, failed=%s)",
                        _manual_connecting_ssid,
                        network.is_connected.to_string (),
                        network.connection_failed.to_string ());
                    _manual_connecting = false;
                    _manual_connecting_ssid = "";
                    if (_manual_connect_timeout_id != 0) {
                        Source.remove (_manual_connect_timeout_id);
                        _manual_connect_timeout_id = 0;
                    }
                }
            }
            if (_manual_connecting) {
                Logger.debug ("WifiViewModel", "Auto-connect skipped: manual connection in progress to %s",
                    _manual_connecting_ssid);
                return;
            }
        }

        if (has_active_wifi_connection ()) return;
        networks_by_ssid.foreach ((ssid, network) => {
            if (network.saved_connection == null) return;
            if (network.is_connected || network.is_connecting || network.auto_connecting) return;
            if (network.access_point == null || network.device == null) return;
            if (auto_connect_cooldowns.contains (ssid)) return;
            if (disconnect_cooldowns.contains (ssid)) return;

            try_auto_connect.begin (network);
        });
    }

    /**
     * Debounce rebuild to settle rapid changes from NetworkManager
     * signals.
     *
     * Waits 120 ms after the last change signal before triggering
     * a full rebuild.
     */
    private void schedule_rebuild () {
        if (settle_scan_id != 0) {
            Logger.debug ("WifiViewModel", "Rebuild already scheduled, skipping");
            return;
        }
        Logger.debug ("WifiViewModel", "Scheduling rebuild in 120ms");

        settle_scan_id = Timeout.add (120, () => {
            settle_scan_id = 0;
            rebuild ();
            return Source.REMOVE;
        });
    }

    /**
     * Start a periodic background scan every 45 seconds.
     *
     * Only scans when the Wi-Fi radio is enabled.
     */
    private void start_background_scan () {
        if (background_scan_id != 0) {
            return;
        }

        background_scan_id = Timeout.add_seconds (45, () => {
            if (!_hidden && service.wireless_enabled) {
                scan.begin ();
            }
            return Source.CONTINUE;
        });
    }

    /**
     * Rebuild the internal network state from all devices and
     * connections.
     *
     * Clears the network hash table, iterates over all Wi-Fi
     * devices and their access points, applies saved and active
     * connections, refreshes runtime details, and triggers
     * auto-connect.
     */
    private void rebuild () {
        Logger.debug ("WifiViewModel", "Rebuilding network state");
        networks_by_ssid.remove_all ();

        foreach (var device in service.get_devices ()) {
            if (!(device is NM.DeviceWifi)) {
                continue;
            }

            var wifi_device = (NM.DeviceWifi) device;
            foreach (var ap in wifi_device.get_access_points ()) {
                add_or_update_access_point (wifi_device, ap);
            }
        }

        apply_saved_connections ();
        apply_active_connections ();
        refresh_runtime_details ();
        update_scan_freshness ();
        rebuild_items ();
        try_auto_connect_all ();
    }

    /**
     * Add or update a network entry from an access point, keeping
     * the strongest signal.
     *
     * If the network already exists and the new AP has a weaker
     * signal, the existing entry is preserved but its AP count
     * is incremented.
     *
     * @param device  The Wi-Fi device the AP was found on.
     * @param ap      The access point to incorporate.
     */
    private void add_or_update_access_point (NM.DeviceWifi device, NM.AccessPoint ap) {
        var ssid = WifiUtils.ssid_to_string (ap.get_ssid ());
        if (ssid.length == 0) {
            return;
        }

        var existing = networks_by_ssid.lookup (ssid);
        if (existing == null) {
            existing = new WifiNetwork ();
            existing.update_from_ap (device, ap);
            networks_by_ssid.insert (ssid, existing);
            return;
        }

        existing.access_point_count += 1;
        if (existing.access_point == null || ap.get_strength () >= existing.strength) {
            existing.update_from_ap (device, ap);
        }
    }

    /**
     * Mark networks that have saved connections in NetworkManager.
     *
     * Iterates over all NM.RemoteConnection objects and sets the
     * is_saved flag on matching WifiNetwork entries.
     */
    private void apply_saved_connections () {
        Logger.debug ("WifiViewModel", "Applying saved connections");
        foreach (var connection in service.get_connections ()) {
            var wifi = connection.get_setting_wireless ();
            if (wifi == null || wifi.get_ssid () == null) {
                continue;
            }

            var ssid = WifiUtils.ssid_to_string (wifi.get_ssid ());
            if (ssid.length == 0) {
                continue;
            }

            var network = networks_by_ssid.lookup (ssid);
            if (network == null || network.access_point == null) {
                continue;
            }

            network.is_saved = true;
            network.saved_connection = connection;
        }
    }

    /**
     * Apply active connection state to networks, marking connected
     * and saved status.
     *
     * Creates synthetic WifiNetwork entries for active connections
     * that were not discovered via access-point scanning.
     */
    private void apply_active_connections () {
        Logger.debug ("WifiViewModel", "Applying active connections");
        foreach (var active in service.get_active_connections ()) {
            if (active.get_connection_type () != "802-11-wireless") {
                continue;
            }

            var connection = active.get_connection ();
            if (connection == null) {
                continue;
            }

            var wifi = connection.get_setting_wireless ();
            if (wifi == null || wifi.get_ssid () == null) {
                continue;
            }

            var ssid = WifiUtils.ssid_to_string (wifi.get_ssid ());
            var network = networks_by_ssid.lookup (ssid);
            if (network == null) {
                network = create_connected_network (ssid, wifi.get_ssid ());
                if (network == null) {
                    continue;
                }
                networks_by_ssid.insert (ssid, network);
            }

            network.is_connected = active.get_state () == NM.ActiveConnectionState.ACTIVATED;
            network.active_connection = active;
            network.is_saved = true;
            network.saved_connection = connection as NM.RemoteConnection;
            if (network.is_connected) {
                last_successful_network = network.ssid;
            }
        }
    }

    /**
     * Create a network entry for the currently active connection by
     * scanning devices.
     *
     * Falls back to a minimal entry with just SSID if no matching
     * access point is found.
     *
     * @param ssid       The SSID string.
     * @param ssid_bytes  The raw SSID bytes.
     * @return A new WifiNetwork, or null on failure.
     */
    private WifiNetwork? create_connected_network (string ssid, GLib.Bytes ssid_bytes) {
        Logger.debug ("WifiViewModel", "Creating connected network entry for: %s", ssid);
        foreach (var device in service.get_devices ()) {
            if (!(device is NM.DeviceWifi)) {
                continue;
            }

            var wifi_device = (NM.DeviceWifi) device;
            var active_ap = wifi_device.get_active_access_point ();
            if (active_ap == null) {
                continue;
            }

            if (WifiUtils.ssid_to_string (active_ap.get_ssid ()) != ssid) {
                continue;
            }

            var network = new WifiNetwork ();
            network.update_from_ap (wifi_device, active_ap);
            return network;
        }

        var fallback = new WifiNetwork ();
        fallback.ssid = ssid;
        fallback.ssid_bytes = ssid_bytes;
        return fallback;
    }

    /**
     * Refresh runtime connection details (IP, gateway, DNS) for all
     * networks.
     *
     * Also updates the captive_portal and connectivity_text
     * properties.
     */
    private void refresh_runtime_details () {
        Logger.debug ("WifiViewModel", "Refreshing runtime details");
        var connectivity = service.connectivity;

        networks_by_ssid.foreach ((ssid, network) => {
            network.update_runtime_details (connectivity);
        });

        captive_portal = connectivity == NM.ConnectivityState.PORTAL;
        connectivity_text = service.connectivity_label;
    }

    /**
     * Determine the most recent scan timestamp across all Wi-Fi
     * devices.
     */
    private void update_scan_freshness () {
        freshest_scan = -1;

        foreach (var device in service.get_devices ()) {
            if (!(device is NM.DeviceWifi)) {
                continue;
            }

            var wifi = (NM.DeviceWifi) device;
            var last_scan = wifi.get_last_scan ();
            if (last_scan > freshest_scan) {
                freshest_scan = last_scan;
            }
        }

        apply_freshness ();
    }

    /**
     * Update the scan freshness display text.
     */
    private void apply_freshness () {
        scan_freshness = WifiUtils.format_scan_age (freshest_scan);
    }

    /**
     * Periodic timer callback to refresh scan age text.
     *
     * Called every 5 seconds.
     *
     * @return Source.CONTINUE to keep the timer alive.
     */
    private bool tick_freshness () {
        if (!_hidden) {
            apply_freshness ();
        }
        return Source.CONTINUE;
    }

    /**
     * Rebuild the list of items displayed in the UI from the
     * current network state.
     *
     * Sorts connected and available networks, creates section
     * headers, and updates has_networks / has_visible_networks /
     * has_connected_network properties.
     */
    private void rebuild_items () {
        Logger.debug ("WifiViewModel", "Rebuilding display items");

        var connected = new GLib.GenericArray<WifiNetwork> ();
        var available = new GLib.GenericArray<WifiNetwork> ();
        int total_scan_results = 0;
        int visible_scan_results = 0;

        networks_by_ssid.foreach ((ssid, network) => {
            if (network.is_connected) {
                connected.add (network);
                return;
            }

            if (!is_scanned (network)) {
                return;
            }

            total_scan_results++;

            if (!matches_search (network)) {
                return;
            }

            visible_scan_results++;
            available.add (network);
        });

        sort_networks (connected);
        sort_networks (available);

        int nitems = 0;
        if (connected.length > 0) {
            nitems += 1 + (int) connected.length;
        }
        if (available.length > 0) {
            nitems += 1 + (int) available.length;
        }
        var new_items = new GLib.Object[nitems];
        int idx = 0;
        if (connected.length > 0) {
            new_items[idx++] = new WifiListItem.header ("Connected");
            for (uint i = 0; i < connected.length; i++) {
                new_items[idx++] = new WifiListItem.for_network (connected.get (i));
            }
        }
        if (available.length > 0) {
            new_items[idx++] = new WifiListItem.header ("Available");
            for (uint i = 0; i < available.length; i++) {
                new_items[idx++] = new WifiListItem.for_network (available.get (i));
            }
        }
        items.splice (0, items.get_n_items (), new_items);

        bool now_has_connected = connected.length > 0;
            if (has_connected_network != now_has_connected) {
                has_connected_network = now_has_connected;
            }

            bool now_has_networks = total_scan_results > 0 || now_has_connected;
            if (has_networks != now_has_networks) {
                has_networks = now_has_networks;
            }

            bool now_has_visible_networks = visible_scan_results > 0;
            if (has_visible_networks != now_has_visible_networks) {
                has_visible_networks = now_has_visible_networks;
            }
    }

    /**
     * Check if the network was discovered via scanning (has an
     * access point).
     *
     * @param network  The network to check.
     * @return true if the network has a known access point.
     */
    private bool is_scanned (WifiNetwork network) {
        return network.access_point != null;
    }

    /**
     * Check if the network matches the current search filter.
     *
     * Search is case-insensitive and matches against the lowercased
     * SSID.
     *
     * @param network  The network to check.
     * @return true if the network passes the filter.
     */
    private bool matches_search (WifiNetwork network) {
        if (search_text.length == 0) {
            return true;
        }
        return network.lower_ssid.contains (search_text);
    }

    /**
     * Sort networks by weighted score descending, then stronger
     * signal, then alphabetical SSID.
     *
     * Score = band (6GHz=300, 5GHz=200, 2.4GHz=100) + signal
     * (dBm+100) + saved (+50) + connected/stability (+20) + WPA3 (+10).
     *
     * @param networks  The array to sort in-place.
     */
    private void sort_networks (GLib.GenericArray<WifiNetwork> networks) {
        networks.sort ((a, b) => {
            if (a == null && b == null) {
                return 0;
            }
            if (a == null) {
                return 1;
            }
            if (b == null) {
                return -1;
            }

            int band_a = a.frequency >= 5925 ? 300 : a.frequency >= 4900 ? 200 : a.frequency >= 2400 ? 100 : 0;
            int band_b = b.frequency >= 5925 ? 300 : b.frequency >= 4900 ? 200 : b.frequency >= 2400 ? 100 : 0;
            int signal_a = WifiUtils.estimate_signal_dbm (a.strength) + 100;
            int signal_b = WifiUtils.estimate_signal_dbm (b.strength) + 100;
            int saved_a = a.is_saved ? 50 : 0;
            int saved_b = b.is_saved ? 50 : 0;
            int stability_a = a.is_connected ? 20 : 0;
            int stability_b = b.is_connected ? 20 : 0;
            int security_a = a.security == WifiSecurity.WPA3 ? 10 : 0;
            int security_b = b.security == WifiSecurity.WPA3 ? 10 : 0;

            int sa = band_a + signal_a + saved_a + stability_a + security_a;
            int sb = band_b + signal_b + saved_b + stability_b + security_b;
            if (sa != sb) {
                return sb - sa;
            }

            if (a.strength != b.strength) {
                return b.strength - a.strength;
            }

            if (a.ssid == b.ssid) {
                return 0;
            }

            return a.ssid < b.ssid ? -1 : 1;
        });
    }
}
