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
            Logger.info ("NetworkManager", "Initializing NetworkManager client");
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
            Logger.warn ("NetworkManager", "Failed to initialize NM.Client: %s", e.message);
        }
    }

    /**
     * Disconnect all signals on cleanup.
     */
    ~NetworkManagerService () {
        disconnect_signals ();
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
            Logger.warn ("NetworkManager", "request_scan called but client is null");
            throw new NetworkManagerServiceError.UNAVAILABLE ("NetworkManager is unavailable");
        }

        Logger.info ("NetworkManager", "Requesting Wi-Fi scan");

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
            throw new NetworkManagerServiceError.CONNECTION_FAILED ("Network is no longer available");
        }

        var existing = network.saved_connection;
        if (existing != null) {
            apply_secrets (existing, network, password, username);
            yield client.activate_connection_async (existing, network.device, network.access_point.get_path (), null);
            return;
        }

        var connection = create_connection (network, password, username);
        yield client.add_and_activate_connection_async (connection, network.device, network.access_point.get_path (), null);
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
        Logger.debug ("NetworkManager", "Connecting client signals");
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
            Logger.debug ("NetworkManager", "Wi-Fi device already connected: %s", device.get_iface ());
            return;
        }
        Logger.debug ("NetworkManager", "Connecting Wi-Fi device: %s", device.get_iface ());

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
     * @param device  The device that was removed.
     */
    private void disconnect_wifi_device (NM.DeviceWifi device) {
        Logger.debug ("NetworkManager", "Disconnecting Wi-Fi device: %s", device.get_iface ());
        var ids = wifi_signal_ids.lookup (device);
        if (ids != null) {
            disconnect_wifi_device_signals (device, ids);
            wifi_signal_ids.remove (device);
        }
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
        var id = active.state_changed.connect (() => changed ());
        active_signal_ids.insert (active, id);
    }

    /**
     * Disconnect signal handler for an active connection that was
     * removed.
     *
     * @param active  The active connection that was removed.
     */
    private void disconnect_active_connection (NM.ActiveConnection active) {
        Logger.debug ("NetworkManager", "Disconnecting active connection signal");
        var id = active_signal_ids.lookup (active);
        if (id != 0) {
            SignalHandler.disconnect (active, id);
            active_signal_ids.remove (active);
        }
    }

    /**
     * Disconnect all signal handlers to prevent memory leaks.
     *
     * Iterates over all stored signal IDs and disconnects them
     * from the client, Wi-Fi devices, and active connections.
     */
    private void disconnect_signals () {
        if (client == null) {
            return;
        }
        Logger.debug ("NetworkManager", "Disconnecting all signals");

        if (device_added_id != 0) client.disconnect (device_added_id);
        if (device_removed_id != 0) client.disconnect (device_removed_id);
        if (connection_added_id != 0) client.disconnect (connection_added_id);
        if (connection_removed_id != 0) client.disconnect (connection_removed_id);
        if (active_connection_added_id != 0) client.disconnect (active_connection_added_id);
        if (active_connection_removed_id != 0) client.disconnect (active_connection_removed_id);
        if (wireless_enabled_id != 0) client.disconnect (wireless_enabled_id);
        if (connectivity_notify_id != 0) client.disconnect (connectivity_notify_id);

        wifi_signal_ids.foreach ((device, ids) => {
            disconnect_wifi_device_signals (device, ids);
        });
        wifi_signal_ids.remove_all ();

        active_signal_ids.foreach ((active, id) => {
            if (id != 0) {
                SignalHandler.disconnect (active, id);
            }
        });
        active_signal_ids.remove_all ();
    }

    /**
     * Disconnect all stored signal IDs for a Wi-Fi device.
     *
     * @param device  The device whose signals should be disconnected.
     * @param ids     The signal ID bundle for that device.
     */
    private void disconnect_wifi_device_signals (NM.DeviceWifi device, WifiDeviceSignals ids) {
        if (ids.access_point_added_id != 0) SignalHandler.disconnect (device, ids.access_point_added_id);
        if (ids.access_point_removed_id != 0) SignalHandler.disconnect (device, ids.access_point_removed_id);
        if (ids.active_access_point_id != 0) SignalHandler.disconnect (device, ids.active_access_point_id);
        if (ids.state_id != 0) SignalHandler.disconnect (device, ids.state_id);
        if (ids.notify_id != 0) SignalHandler.disconnect (device, ids.notify_id);
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
     * Apply password and username secrets to an existing NM
     * connection.
     *
     * Only sets secrets if a non-empty password is provided.
     *
     * @param connection  The existing NM connection to modify.
     * @param network     The network, used to determine enterprise vs personal.
     * @param password    The new password (or null to skip).
     * @param username    The new 802.1X username (or null).
     */
    private void apply_secrets (NM.Connection connection, WifiNetwork network, string? password, string? username) {
        if (password == null || password.length == 0) {
            return;
        }

        if (network.enterprise) {
            var s_8021x = connection.get_setting_802_1x ();
            if (s_8021x != null) {
                if (username != null && username.length > 0) {
                    s_8021x.identity = username;
                }
                s_8021x.password = password;
            }
        } else {
            var s_wsec = connection.get_setting_wireless_security ();
            if (s_wsec != null) {
                s_wsec.psk = password;
            }
        }
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
