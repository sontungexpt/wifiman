using NM;

/**
 * Errors that can originate from the NetworkManager service layer.
 */
public errordomain NetworkManagerServiceError {
    /**
     * NetworkManager client could not be initialised or is not running.
     */
    UNAVAILABLE,

    /**
     * The scan request failed (e.g. no Wi-Fi adapter).
     */
    SCAN_FAILED,

    /**
     * The connection request was rejected by NetworkManager.
     */
    CONNECTION_FAILED
}

/**
 * Low-level wrapper around the NetworkManager client.
 *
 * Manages the NM.Client lifecycle, subscribes to device,
 * connection, and active-connection signals, and exposes
 * async methods for scanning, connecting, disconnecting,
 * and forgetting networks.
 */
public class NetworkManagerService : GLib.Object {
    /**
     * Emitted when any relevant NetworkManager state changes.
     *
     * Connected to device add/remove, AP add/remove, connection
     * add/remove, active connection state changes, and
     * wireless-enabled changes.
     */
    public signal void changed ();

    /**
     * Emitted when a scan is initiated on all Wi-Fi devices.
     */
    public signal void scan_started ();

    /**
     * Emitted when a scan completes (successfully or not).
     */
    public signal void scan_finished ();

    /**
     * Emitted when an unrecoverable error occurs.
     *
     * @param message  Human-readable error description.
     */
    public signal void error (string message);

    /**
     * Emitted when an active connection reaches DEACTIVATED state.
     *
     * Only emitted for 802-11-wireless connections.  Consumers should
     * check whether this corresponds to their manual connect attempt.
     *
     * @param ssid    The SSID of the failed connection.
     * @param reason  The reason the connection was deactivated.
     */
    public signal void connection_failed (string ssid, NM.ActiveConnectionStateReason reason);

    private NM.Client? client;
    private ulong device_added_id = 0;
    private ulong device_removed_id = 0;
    private ulong connection_added_id = 0;
    private ulong connection_removed_id = 0;
    private ulong active_connection_added_id = 0;
    private ulong active_connection_removed_id = 0;
    private ulong wireless_enabled_id = 0;
    private ulong connectivity_notify_id = 0;
    private class WifiDeviceSignals {
        public ulong access_point_added_id;
        public ulong access_point_removed_id;
        public ulong active_access_point_id;
        public ulong state_id;
        public ulong notify_id;
    }

    private GLib.HashTable<NM.DeviceWifi, WifiDeviceSignals> wifi_signal_ids =
        new GLib.HashTable<NM.DeviceWifi, WifiDeviceSignals> (GLib.direct_hash, GLib.direct_equal);
    private GLib.HashTable<NM.ActiveConnection, ulong> active_signal_ids =
        new GLib.HashTable<NM.ActiveConnection, ulong> (GLib.direct_hash, GLib.direct_equal);

    /**
     * Whether the NetworkManager client was successfully initialised.
     */
    public bool available { get; private set; default = false; }

    /**
     * The current connectivity state from NetworkManager.
     *
     * @return NM.ConnectivityState, or UNKNOWN if client is null.
     */
    public NM.ConnectivityState connectivity {
        get {
            if (client == null) {
                return NM.ConnectivityState.UNKNOWN;
            }
            return client.get_connectivity ();
        }
    }

    /**
     * Human-readable label for the current connectivity state.
     */
    public string connectivity_label {
        owned get { return WifiUtils.connectivity_to_label (connectivity); }
    }

    /**
     * Initialise the NetworkManager client and connect to all signals.
     *
     * Creates an NM.Client and subscribes to device, connection, and
     * active-connection signals.  Also connects to any already-known
     * Wi-Fi devices and active connections.
     */
    public NetworkManagerService () {
        try {
            Log.info ("NetworkManager", "Initializing NetworkManager client");
            client = new NM.Client (null);
            available = true;
            connect_client_signals ();
            foreach (var device in client.get_devices ()) {
                if (device is NM.DeviceWifi) {
                    connect_wifi_device ((NM.DeviceWifi) device);
                }
            }
            foreach (var active in client.get_active_connections ()) {
                connect_active_connection (active);
            }
        } catch (GLib.Error e) {
            available = false;
            Log.warn ("NetworkManager", "Failed to initialize NM.Client: %s", e.message);
        }
    }

    /**
     * Shut down the service.
     *
     * Disconnects all signal handlers — from NM.Client, per-device,
     * and per-active-connection — so that callbacks stop firing before
     * the ViewModel stops listening.
     *
     * Per-device and per-active-connection signal handlers are NOT
     * disconnected in the device_removed / active_connection_removed
     * callbacks because the NM proxy objects may already be partially
     * finalized.  Here in shutdown(), however, the NM.Client and all
     * its sub-objects are still alive, so it is safe to disconnect.
     */
    public void shutdown () {
        Log.info ("NetworkManager", "Shutting down NetworkManager service");
        if (client == null) return;

        if (device_added_id != 0) {
            SignalHandler.disconnect (client, device_added_id);
            device_added_id = 0;
        }
        if (device_removed_id != 0) {
            SignalHandler.disconnect (client, device_removed_id);
            device_removed_id = 0;
        }
        if (connection_added_id != 0) {
            SignalHandler.disconnect (client, connection_added_id);
            connection_added_id = 0;
        }
        if (connection_removed_id != 0) {
            SignalHandler.disconnect (client, connection_removed_id);
            connection_removed_id = 0;
        }
        if (active_connection_added_id != 0) {
            SignalHandler.disconnect (client, active_connection_added_id);
            active_connection_added_id = 0;
        }
        if (active_connection_removed_id != 0) {
            SignalHandler.disconnect (client, active_connection_removed_id);
            active_connection_removed_id = 0;
        }
        if (wireless_enabled_id != 0) {
            SignalHandler.disconnect (client, wireless_enabled_id);
            wireless_enabled_id = 0;
        }
        if (connectivity_notify_id != 0) {
            SignalHandler.disconnect (client, connectivity_notify_id);
            connectivity_notify_id = 0;
        }

        // Disconnect per-device signal handlers.  Unlike during a
        // device_removed callback (where the NM proxy may already be
        // partially finalized), at shutdown time the NM.Client and all
        // its sub-objects are still alive, so it is safe to disconnect.
        Log.debug ("NetworkManager", "Disconnecting %d per-device signal handler sets",
            wifi_signal_ids.size ());
        wifi_signal_ids.foreach ((device, ids) => {
            SignalHandler.disconnect (device, ids.access_point_added_id);
            SignalHandler.disconnect (device, ids.access_point_removed_id);
            SignalHandler.disconnect (device, ids.active_access_point_id);
            SignalHandler.disconnect (device, ids.state_id);
            SignalHandler.disconnect (device, ids.notify_id);
        });
        wifi_signal_ids.remove_all ();

        // Same for active-connection signal handlers.
        Log.debug ("NetworkManager", "Disconnecting %d active-connection signal handlers",
            active_signal_ids.size ());
        active_signal_ids.foreach ((active, id) => {
            SignalHandler.disconnect (active, id);
        });
        active_signal_ids.remove_all ();
    }

    /**
     * Enable or disable the Wi-Fi radio.
     */
    public bool wireless_enabled {
        get { return client != null && client.wireless_enabled; }
        set {
            if (client != null) {
                client.wireless_enabled = value;
            }
        }
    }

    /**
     * Get all network devices from NetworkManager.
     *
     * @return An array of NM.Device objects.
     */
    public unowned GLib.GenericArray<NM.Device> get_devices () {
        return client.get_devices ();
    }

    /**
     * Get all saved connections from NetworkManager.
     *
     * @return An array of NM.RemoteConnection objects.
     */
    public unowned GLib.GenericArray<NM.RemoteConnection> get_connections () {
        return client.get_connections ();
    }

    /**
     * Get all active connections from NetworkManager.
     *
     * @return An array of NM.ActiveConnection objects.
     */
    public unowned GLib.GenericArray<NM.ActiveConnection> get_active_connections () {
        return client.get_active_connections ();
    }

    /**
     * Request a scan on all Wi-Fi devices.
     *
     * Async method, does not block the UI thread.  Emits
     * scan_started before scanning and scan_finished afterwards
     * (even on failure).
     *
     * @throws NetworkManagerServiceError.UNAVAILABLE if the client is null.
     * @throws NetworkManagerServiceError.SCAN_FAILED if no Wi-Fi adapter is found.
     */
    public async void request_scan () throws GLib.Error {
        if (client == null) {
            Log.warn ("NetworkManager", "request_scan called but client is null");
            throw new NetworkManagerServiceError.UNAVAILABLE ("NetworkManager is unavailable");
        }

        Log.info ("NetworkManager", "Requesting Wi-Fi scan");

        scan_started ();
        try {
            bool scanned = false;
            foreach (var device in client.get_devices ()) {
                if (device is NM.DeviceWifi) {
                    scanned = true;
                    yield ((NM.DeviceWifi) device).request_scan_async (null);
                }
            }
            if (!scanned) {
                throw new NetworkManagerServiceError.SCAN_FAILED ("No Wi-Fi adapter found");
            }
        } finally {
            scan_finished ();
        }
    }

    /**
     * Connect to a network, using a saved connection or creating a
     * new one.
     *
     * Async method, does not block the UI thread.  If a saved
     * connection exists, secrets (password/username) are applied
     * in-place before activation.
     *
     * @param network   The network to connect to.
     * @param password  Optional WPA or 802.1X password.
     * @param username  Optional 802.1X username.
     * @throws NetworkManagerServiceError.CONNECTION_FAILED if prerequisites are missing.
     * @throws Error if NetworkManager rejects the activation.
     */
    public async void connect_network (WifiNetwork network, string? password, string? username) throws GLib.Error {
        if (client == null || network.access_point == null || network.device == null) {
            Log.warn ("NetworkManager", "connect_network: prerequisites missing: client=%s ap=%s device=%s",
                (client != null).to_string (),
                (network.access_point != null).to_string (),
                (network.device != null).to_string ());
            throw new NetworkManagerServiceError.CONNECTION_FAILED ("Network is no longer available");
        }

        Log.info ("NetworkManager", "connect_network: ssid='%s' has_password=%s has_username=%s saved=%s",
            network.ssid,
            (password != null && password.length > 0).to_string (),
            (username != null && username.length > 0).to_string (),
            (network.saved_connection != null).to_string ());

        var existing = network.saved_connection;
        if (existing != null) {
            if (password != null && password.length > 0) {
                Log.info ("NetworkManager", "Updating saved connection for: %s", network.ssid);
                // Delete the old saved connection first, then create+a new one.
                // This avoids orphaned duplicate connections in NM's database.
                try {
                    yield existing.delete_async (null);
                } catch (GLib.Error e) {
                    Log.warn ("NetworkManager", "Failed to delete old saved connection for %s: %s", network.ssid, e.message);
                }
                var new_conn = create_connection (network, password, username);
                yield client.add_and_activate_connection_async (new_conn, network.device, network.access_point.get_path (), null);
                Log.info ("NetworkManager", "add_and_activate_connection_async succeeded for: %s", network.ssid);
                return;
            }

            Log.info ("NetworkManager", "Using saved connection for: %s", network.ssid);
            yield client.activate_connection_async (existing, network.device, network.access_point.get_path (), null);
            Log.info ("NetworkManager", "activate_connection_async succeeded for: %s", network.ssid);
            return;
        }

        Log.info ("NetworkManager", "Creating new connection for: %s", network.ssid);
        var connection = create_connection (network, password, username);
        Log.info ("NetworkManager", "Calling add_and_activate_connection_async for: %s", network.ssid);
        yield client.add_and_activate_connection_async (connection, network.device, network.access_point.get_path (), null);
        Log.info ("NetworkManager", "add_and_activate_connection_async succeeded for: %s", network.ssid);
    }

    /**
     * Disconnect an active network connection.
     *
     * Async method, does not block the UI thread.
     *
     * @param network  The network whose active connection should be deactivated.
     * @throws Error if NetworkManager rejects the deactivation.
     */
    public async void disconnect_network (WifiNetwork network) throws GLib.Error {
        if (client == null || network.active_connection == null) {
            return;
        }
        yield client.deactivate_connection_async (network.active_connection, null);
    }

    /**
     * Delete a saved network connection from NetworkManager.
     *
     * Async method, does not block the UI thread.
     *
     * @param network  The network whose saved connection should be removed.
     * @throws Error if NetworkManager rejects the deletion.
     */
    public async void forget_network (WifiNetwork network) throws GLib.Error {
        if (network.saved_connection == null) {
            return;
        }
        yield network.saved_connection.delete_async (null);
    }

    /**
     * Connect to all relevant NetworkManager client signals.
     *
     * Subscribes to device_added, device_removed, connection_added,
     * connection_removed, active_connection_added, and
     * active_connection_removed signals, as well as property
     * notifications for wireless-enabled and connectivity.
     */
    private void connect_client_signals () {
        Log.debug ("NetworkManager", "Connecting client signals");
        device_added_id = client.device_added.connect ((device) => {
            if (device is NM.DeviceWifi) {
                connect_wifi_device ((NM.DeviceWifi) device);
            }
            changed ();
        });

        device_removed_id = client.device_removed.connect ((device) => {
            if (device is NM.DeviceWifi) {
                disconnect_wifi_device ((NM.DeviceWifi) device);
            }
            changed ();
        });

        connection_added_id = client.connection_added.connect (() => changed ());
        connection_removed_id = client.connection_removed.connect (() => changed ());
        active_connection_added_id = client.active_connection_added.connect ((active) => {
            connect_active_connection (active);
            changed ();
        });
        active_connection_removed_id = client.active_connection_removed.connect ((active) => {
            disconnect_active_connection (active);
            changed ();
        });
        wireless_enabled_id = client.notify["wireless-enabled"].connect (() => changed ());
        connectivity_notify_id = client.notify["connectivity"].connect (() => changed ());
    }

    /**
     * Connect signal handlers for a Wi-Fi device to track access
     * point changes.
     *
     * Registers handlers for access_point_added, access_point_removed,
     * active-access-point, state, and general notify (for
     * access-points and last-scan).
     *
     * @param device  The Wi-Fi device to monitor.
     */
    private void connect_wifi_device (NM.DeviceWifi device) {
        if (wifi_signal_ids.contains (device)) {
            Log.debug ("NetworkManager", "Wi-Fi device already connected: %s", device.get_iface ());
            return;
        }
        Log.debug ("NetworkManager", "Connecting Wi-Fi device: %s", device.get_iface ());

        var ids = new WifiDeviceSignals ();
        ids.access_point_added_id = device.access_point_added.connect (() => changed ());
        ids.access_point_removed_id = device.access_point_removed.connect (() => changed ());
        ids.active_access_point_id = device.notify["active-access-point"].connect (() => changed ());
        ids.state_id = device.notify["state"].connect (() => changed ());

        ids.notify_id = device.notify.connect ((pspec) => {
            if (pspec.name == "access-points" || pspec.name == "last-scan") {
                changed ();
            }
        });
        wifi_signal_ids.insert (device, ids);
    }

    /**
     * Disconnect signal handlers for a Wi-Fi device that was removed.
     *
     * When a device is removed by NetworkManager, the NM.DeviceWifi proxy
     * passed to the device_removed callback may already be partially
     * finalized.  Calling SignalHandler.disconnect on such an object
     * triggers g_signal_handler_disconnect: assertion
     * 'G_TYPE_CHECK_INSTANCE (instance)' failed.
     *
     * Instead we just drop our tracking.  GObject will clean up the
     * signal handlers automatically when the proxy is eventually
     * finalized by libnm.
     *
     * Note: during service shutdown() we DO disconnect these handlers
     * because at that point all NM proxy objects are still alive.
     *
     * @param device  The device that was removed.
     */
    private void disconnect_wifi_device (NM.DeviceWifi device) {
        wifi_signal_ids.remove (device);
    }

    /**
     * Connect state-changed signal for an active connection.
     *
     * @param active  The active connection to monitor.
     */
    private void connect_active_connection (NM.ActiveConnection active) {
        if (active_signal_ids.contains (active)) {
            return;
        }
        var id = active.state_changed.connect ((state, reason) => {
            if ((NM.ActiveConnectionState) state == NM.ActiveConnectionState.DEACTIVATED
                && active.get_connection_type () == "802-11-wireless") {
                var ssid = resolve_ssid_from_active (active);
                if (ssid != null) {
                    connection_failed (ssid, (NM.ActiveConnectionStateReason) reason);
                }
            }
            changed ();
        });
        active_signal_ids.insert (active, id);
    }

    /**
     * Extract the SSID string from an active connection.
     *
     * @param active  The active connection to inspect.
     * @return The SSID as a string, or null if it cannot be resolved.
     */
    private string? resolve_ssid_from_active (NM.ActiveConnection active) {
        var connection = active.get_connection ();
        if (connection == null) {
            return null;
        }
        var wifi = connection.get_setting_wireless ();
        if (wifi == null || wifi.get_ssid () == null) {
            return null;
        }
        return WifiUtils.ssid_to_string (wifi.get_ssid ());
    }

    /**
     * Disconnect signal handler for an active connection that was
     * removed.
     *
     * Same rationale as disconnect_wifi_device: the NM.ActiveConnection
     * proxy passed by the signal may already be partially finalized.
     * We just drop our tracking and let GObject clean up the signal
     * handler during the proxy's eventual finalization.
     *
     * Note: during service shutdown() we DO disconnect these handlers
     * because at that point all NM proxy objects are still alive.
     *
     * @param active  The active connection that was removed.
     */
    private void disconnect_active_connection (NM.ActiveConnection active) {
        active_signal_ids.remove (active);
    }

    /**
     * Create a new NM.SimpleConnection for connecting to a Wi-Fi
     * network.
     *
     * Builds the connection with 802-11-wireless settings, security
     * (WPA/WPA2/WPA3/Enterprise), and auto IP configuration for
     * both IPv4 and IPv6.
     *
     * @param network   The network to create a connection for.
     * @param password  Optional password or passphrase.
     * @param username  Optional 802.1X username.
     * @return A fully configured NM.Connection.
     */
    private NM.Connection create_connection (WifiNetwork network, string? password, string? username) {
        var connection = GLib.Object.new (typeof (NM.SimpleConnection)) as NM.SimpleConnection;

        var s_con = new NM.SettingConnection ();
        s_con.uuid = GLib.Uuid.string_random ();
        s_con.id = network.ssid;
        s_con.type = "802-11-wireless";
        connection.add_setting (s_con);

        var s_wifi = new NM.SettingWireless ();
        s_wifi.ssid = network.ssid_bytes;
        s_wifi.mode = "infrastructure";
        connection.add_setting (s_wifi);

        add_security_settings (connection, network, password, username);

        var s_ipv4 = new NM.SettingIP4Config ();
        s_ipv4.method = "auto";
        connection.add_setting (s_ipv4);

        var s_ipv6 = new NM.SettingIP6Config ();
        s_ipv6.method = "auto";
        connection.add_setting (s_ipv6);

        return connection;
    }

    /**
     * Add wireless security and 802.1X settings to a connection.
     *
     * For enterprise networks, WPA-EAP with PEAP/MSCHAPv2 is
     * configured.  For personal networks, SAE (WPA3) or WPA-PSK
     * is used depending on the network's security type.
     *
     * @param connection  The connection to add settings to.
     * @param network     The network, used to determine security type.
     * @param password    Optional password or passphrase.
     * @param username    Optional 802.1X username.
     */
    private void add_security_settings (NM.SimpleConnection connection, WifiNetwork network, string? password, string? username) {
        if (!network.secured) {
            return;
        }

        var s_wsec = new NM.SettingWirelessSecurity ();

        if (network.enterprise) {
            s_wsec.key_mgmt = "wpa-eap";
            connection.add_setting (s_wsec);

            var s_8021x = new NM.Setting8021x ();
            s_8021x.add_eap_method ("peap");
            s_8021x.phase2_auth = "mschapv2";
            if (username != null && username.length > 0) {
                s_8021x.identity = username;
            }
            if (password != null && password.length > 0) {
                s_8021x.password = password;
            }
            connection.add_setting (s_8021x);
        } else {
            s_wsec.key_mgmt = network.security_type == "WPA3" ? "sae" : "wpa-psk";
            if (password != null && password.length > 0) {
                s_wsec.psk = password;
            }
            connection.add_setting (s_wsec);
        }
    }
}
