using GLib;
using NM;

public enum WifiListItemKind {
    HEADER,
    NETWORK
}

public class WifiListItem : GLib.Object {
    public WifiListItemKind kind { get; construct; }
    public string title { get; construct; default = ""; }
    public WifiNetwork? network { get; construct; default = null; }

    public WifiListItem.header (string title) {
        GLib.Object (kind: WifiListItemKind.HEADER, title: title);
    }

    public WifiListItem.for_network (WifiNetwork network) {
        GLib.Object (kind: WifiListItemKind.NETWORK, network: network);
    }
}

public class WifiViewModel : GLib.Object {
    public signal void error (string message);

    public GLib.ListStore items { get; private set; }
    public bool scanning { get; private set; default = false; }
    public bool has_networks { get; private set; default = false; }
    public bool search_active { get; private set; default = false; }
    public bool has_visible_networks { get; private set; default = false; }
    public bool has_connected_network { get; private set; default = false; }
    public bool captive_portal { get; private set; default = false; }
    public string connectivity_text { get; private set; default = ""; }
    public string scan_freshness { get; private set; default = "No recent scan"; }
    public string last_successful_network { get; private set; default = ""; }
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

    public bool auto_reconnect_enabled { get; set; default = true; }

    public WifiViewModel (NetworkManagerService service) {
        this.service = service;
        items = new GLib.ListStore (typeof (WifiListItem));

        service.changed.connect (() => schedule_rebuild ());
        service.scan_started.connect (() => {
            scanning = true;
            notify_property ("scanning");
        });
        service.scan_finished.connect (() => {
            scanning = false;
            notify_property ("scanning");
            schedule_rebuild ();
        });
        service.error.connect ((message) => error (message));

        auto_connect_cooldowns = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);
        disconnect_cooldowns = new GLib.HashTable<string, bool> (GLib.str_hash, GLib.str_equal);

        rebuild ();
        update_connectivity_state ();
        start_background_scan ();
        freshness_timer_id = Timeout.add_seconds (5, tick_freshness);
        _started = true;
    }

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
    }

    public void set_search_text (string text) {
        var normalized = text.strip ().down ();
        if (normalized == search_text) {
            return;
        }

        search_text = normalized;
        search_active = search_text.length > 0;
        notify_property ("search-active");
        rebuild_items ();
    }

    public async void scan () {
        if (scanning) {
            return;
        }

        try {
            yield service.request_scan ();
            schedule_rebuild ();
        } catch (GLib.Error e) {
            scanning = false;
            notify_property ("scanning");
            error (e.message);
            rebuild ();
        }
    }

    public async void connect_network (WifiNetwork network, string? password = null, string? username = null) throws GLib.Error {
        yield service.connect_network (network, password, username);
    }

    public async void reconnect_network (WifiNetwork network, string? password = null, string? username = null) throws GLib.Error {
        if (network.active_connection != null) {
            yield service.disconnect_network (network);
        }
        yield service.connect_network (network, password, username);
    }

    public async void disconnect_network (WifiNetwork network) throws GLib.Error {
        yield service.disconnect_network (network);
    }

    public async void forget_network (WifiNetwork network) throws GLib.Error {
        yield service.forget_network (network);
    }

    public async void try_auto_connect (WifiNetwork network) {
        if (!_started || !auto_reconnect_enabled) return;
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
            yield service.connect_network (network, null, null);
        } catch (GLib.Error e) {
            network.auto_connecting = false;
            network.connecting_status_text = "";
        }
    }

    public void record_disconnect (string ssid) {
        disconnect_cooldowns.insert (ssid, true);
        Timeout.add (DISCONNECT_COOLDOWN_MS, () => {
            disconnect_cooldowns.remove (ssid);
            return Source.REMOVE;
        });
    }

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

    private void try_auto_connect_all () {
        if (!_started || !auto_reconnect_enabled) return;
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

    private void schedule_rebuild () {
        if (settle_scan_id != 0) {
            return;
        }

        settle_scan_id = Timeout.add (120, () => {
            settle_scan_id = 0;
            rebuild ();
            return Source.REMOVE;
        });
    }

    private void start_background_scan () {
        if (background_scan_id != 0) {
            return;
        }

        background_scan_id = Timeout.add_seconds (45, () => {
            if (service.wireless_enabled) {
                scan.begin ();
            }
            return Source.CONTINUE;
        });
    }

    private void rebuild () {
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

    private void apply_saved_connections () {
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

    private void apply_active_connections () {
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
                notify_property ("last-successful-network");
            }
        }
    }

    private WifiNetwork? create_connected_network (string ssid, GLib.Bytes ssid_bytes) {
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

    private void refresh_runtime_details () {
        var connectivity = service.connectivity;

        networks_by_ssid.foreach ((ssid, network) => {
            network.update_runtime_details (connectivity);
        });

        captive_portal = connectivity == NM.ConnectivityState.PORTAL;
        connectivity_text = service.connectivity_label;
        notify_property ("captive-portal");
        notify_property ("connectivity-text");
    }

    private void update_connectivity_state () {
        var connectivity = service.connectivity;
        captive_portal = connectivity == NM.ConnectivityState.PORTAL;
        connectivity_text = service.connectivity_label;
        notify_property ("captive-portal");
        notify_property ("connectivity-text");
    }

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

    private void apply_freshness () {
        scan_freshness = WifiUtils.format_scan_age (freshest_scan);
        notify_property ("scan-freshness");
    }

    private bool tick_freshness () {
        apply_freshness ();
        return Source.CONTINUE;
    }

    private void rebuild_items () {
        items.remove_all ();

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

        append_section ("Connected", connected);
        append_section ("Available", available);

        bool now_has_connected = connected.length > 0;
        if (has_connected_network != now_has_connected) {
            has_connected_network = now_has_connected;
            notify_property ("has-connected-network");
        }

        bool now_has_networks = total_scan_results > 0 || now_has_connected;
        if (has_networks != now_has_networks) {
            has_networks = now_has_networks;
            notify_property ("has-networks");
        }

        bool now_has_visible_networks = visible_scan_results > 0;
        if (has_visible_networks != now_has_visible_networks) {
            has_visible_networks = now_has_visible_networks;
            notify_property ("has-visible-networks");
        }
    }

    private bool is_scanned (WifiNetwork network) {
        return network.access_point != null;
    }

    private bool matches_search (WifiNetwork network) {
        if (search_text.length == 0) {
            return true;
        }
        return network.lower_ssid.contains (search_text);
    }

    private void append_section (string title, GLib.GenericArray<WifiNetwork> networks) {
        if (networks.length == 0) {
            return;
        }

        items.append (new WifiListItem.header (title));
        for (uint i = 0; i < networks.length; i++) {
            items.append (new WifiListItem.for_network (networks.get (i)));
        }
    }

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
