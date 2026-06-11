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

        rebuild ();
    }

    ~WifiViewModel () {
        if (settle_scan_id != 0) {
            Source.remove (settle_scan_id);
            settle_scan_id = 0;
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

    public async void disconnect_network (WifiNetwork network) throws GLib.Error {
        yield service.disconnect_network (network);
    }

    public async void forget_network (WifiNetwork network) throws GLib.Error {
        yield service.forget_network (network);
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
        rebuild_items ();
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
            if (network == null) {
                network = new WifiNetwork ();
                network.ssid = ssid;
                network.ssid_bytes = wifi.get_ssid ();
                networks_by_ssid.insert (ssid, network);
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
                continue;
            }

            network.is_connected = active.get_state () == NM.ActiveConnectionState.ACTIVATED;
            network.active_connection = active;
            network.is_saved = true;
            network.saved_connection = connection as NM.RemoteConnection;
        }
    }

    private void rebuild_items () {
        items.remove_all ();

        var connected = new GLib.GenericArray<WifiNetwork> ();
        var saved = new GLib.GenericArray<WifiNetwork> ();
        var available = new GLib.GenericArray<WifiNetwork> ();

        networks_by_ssid.foreach ((ssid, network) => {
            if (!matches_search (network)) {
                return;
            }
            if (network.is_connected) {
                connected.add (network);
            } else if (network.is_saved) {
                saved.add (network);
            } else {
                available.add (network);
            }
        });

        sort_networks (connected);
        sort_networks (saved);
        sort_networks (available);

        append_section ("Connected", connected);
        append_section ("Saved", saved);
        append_section ("Available", available);

        bool now_has_networks = items.get_n_items () > 0;
        if (has_networks != now_has_networks) {
            has_networks = now_has_networks;
            notify_property ("has-networks");
        }

        bool now_has_visible_networks = connected.length > 0 || saved.length > 0 || available.length > 0;
        if (has_visible_networks != now_has_visible_networks) {
            has_visible_networks = now_has_visible_networks;
            notify_property ("has-visible-networks");
        }
    }

    private bool matches_search (WifiNetwork network) {
        if (search_text.length == 0) {
            return true;
        }
        return network.ssid.down ().contains (search_text);
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
