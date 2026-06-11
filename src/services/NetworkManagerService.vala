using GLib;
using NM;

public errordomain NetworkManagerServiceError {
    UNAVAILABLE,
    SCAN_FAILED,
    CONNECTION_FAILED
}

public class NetworkManagerService : GLib.Object {
    public signal void changed ();
    public signal void scan_started ();
    public signal void scan_finished ();
    public signal void error (string message);

    private NM.Client? client;
    private ulong device_added_id = 0;
    private ulong device_removed_id = 0;
    private ulong connection_added_id = 0;
    private ulong connection_removed_id = 0;
    private ulong active_connection_added_id = 0;
    private ulong active_connection_removed_id = 0;
    private ulong wireless_enabled_id = 0;
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

    public bool available { get; private set; default = false; }

    public NetworkManagerService () {
        try {
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
            error ("NetworkManager is unavailable: %s".printf (e.message));
        }
    }

    ~NetworkManagerService () {
        disconnect_signals ();
    }

    public bool wireless_enabled {
        get { return client != null && client.wireless_enabled; }
        set {
            if (client != null) {
                client.wireless_enabled = value;
            }
        }
    }

    public unowned GLib.GenericArray<NM.Device> get_devices () {
        return client.get_devices ();
    }

    public unowned GLib.GenericArray<NM.RemoteConnection> get_connections () {
        return client.get_connections ();
    }

    public unowned GLib.GenericArray<NM.ActiveConnection> get_active_connections () {
        return client.get_active_connections ();
    }

    public async void request_scan () throws GLib.Error {
        if (client == null) {
            throw new NetworkManagerServiceError.UNAVAILABLE ("NetworkManager is unavailable");
        }

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

    public async void disconnect_network (WifiNetwork network) throws GLib.Error {
        if (client == null || network.active_connection == null) {
            return;
        }
        yield client.deactivate_connection_async (network.active_connection, null);
    }

    public async void forget_network (WifiNetwork network) throws GLib.Error {
        if (network.saved_connection == null) {
            return;
        }
        yield network.saved_connection.delete_async (null);
    }

    private void connect_client_signals () {
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
    }

    private void connect_wifi_device (NM.DeviceWifi device) {
        if (wifi_signal_ids.contains (device)) {
            return;
        }

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

    private void disconnect_wifi_device (NM.DeviceWifi device) {
        var ids = wifi_signal_ids.lookup (device);
        if (ids != null) {
            disconnect_wifi_device_signals (device, ids);
            wifi_signal_ids.remove (device);
        }
    }

    private void connect_active_connection (NM.ActiveConnection active) {
        if (active_signal_ids.contains (active)) {
            return;
        }
        var id = active.state_changed.connect (() => changed ());
        active_signal_ids.insert (active, id);
    }

    private void disconnect_active_connection (NM.ActiveConnection active) {
        var id = active_signal_ids.lookup (active);
        if (id != 0) {
            SignalHandler.disconnect (active, id);
            active_signal_ids.remove (active);
        }
    }

    private void disconnect_signals () {
        if (client == null) {
            return;
        }

        if (device_added_id != 0) client.disconnect (device_added_id);
        if (device_removed_id != 0) client.disconnect (device_removed_id);
        if (connection_added_id != 0) client.disconnect (connection_added_id);
        if (connection_removed_id != 0) client.disconnect (connection_removed_id);
        if (active_connection_added_id != 0) client.disconnect (active_connection_added_id);
        if (active_connection_removed_id != 0) client.disconnect (active_connection_removed_id);
        if (wireless_enabled_id != 0) client.disconnect (wireless_enabled_id);

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

    private void disconnect_wifi_device_signals (NM.DeviceWifi device, WifiDeviceSignals ids) {
        if (ids.access_point_added_id != 0) SignalHandler.disconnect (device, ids.access_point_added_id);
        if (ids.access_point_removed_id != 0) SignalHandler.disconnect (device, ids.access_point_removed_id);
        if (ids.active_access_point_id != 0) SignalHandler.disconnect (device, ids.active_access_point_id);
        if (ids.state_id != 0) SignalHandler.disconnect (device, ids.state_id);
        if (ids.notify_id != 0) SignalHandler.disconnect (device, ids.notify_id);
    }

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
