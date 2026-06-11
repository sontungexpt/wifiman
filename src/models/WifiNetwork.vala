using GLib;
using NM;

public enum WifiSecurity {
    OPEN,
    WEP,
    WPA,
    WPA2,
    WPA3,
    ENTERPRISE
}

public class WifiNetwork : GLib.Object {
    public string ssid { get; set; default = ""; }
    public string bssid { get; set; default = ""; }
    public int strength { get; set; default = 0; }
    public uint frequency { get; set; default = 0; }
    public WifiSecurity security { get; set; default = WifiSecurity.OPEN; }
    public bool is_connected { get; set; default = false; }
    public bool is_saved { get; set; default = false; }
    public NM.AccessPoint? access_point { get; set; default = null; }
    public NM.DeviceWifi? device { get; set; default = null; }
    public NM.RemoteConnection? saved_connection { get; set; default = null; }
    public NM.ActiveConnection? active_connection { get; set; default = null; }
    public GLib.Bytes? ssid_bytes { get; set; default = null; }

    public string security_type {
        owned get {
            switch (security) {
                case WifiSecurity.WEP:
                    return "WEP";
                case WifiSecurity.WPA:
                    return "WPA";
                case WifiSecurity.WPA2:
                    return "WPA2";
                case WifiSecurity.WPA3:
                    return "WPA3";
                case WifiSecurity.ENTERPRISE:
                    return "Enterprise";
                default:
                    return "Open";
            }
        }
    }

    public bool secured {
        get { return security != WifiSecurity.OPEN; }
    }

    public bool enterprise {
        get { return security == WifiSecurity.ENTERPRISE; }
    }

    public bool is_connecting {
        get {
            return active_connection != null
                && active_connection.get_state () == NM.ActiveConnectionState.ACTIVATING;
        }
    }

    public bool connection_failed {
        get {
            if (active_connection == null) {
                return false;
            }

            var state = active_connection.get_state ();
            if (state != NM.ActiveConnectionState.DEACTIVATED) {
                return false;
            }

            return active_connection.get_state_reason () != NM.ActiveConnectionStateReason.NONE;
        }
    }

    public string primary_status {
        owned get {
            if (is_connected) {
                return "Connected";
            }
            if (is_connecting) {
                return "Connecting";
            }
            if (connection_failed) {
                return "Failed";
            }
            if (is_saved) {
                return "Saved";
            }
            return "";
        }
    }

    public string primary_status_style {
        owned get {
            if (is_connected) {
                return "connected";
            }
            if (is_connecting) {
                return "connecting";
            }
            if (connection_failed) {
                return "failed";
            }
            if (is_saved) {
                return "saved";
            }
            return "";
        }
    }

    public string band {
        owned get {
            if (frequency >= 5925) {
                return "6 GHz";
            }
            if (frequency >= 4900) {
                return "5 GHz";
            }
            if (frequency >= 2400) {
                return "2.4 GHz";
            }
            return "";
        }
    }

    public string subtitle {
        owned get {
            var security_label = WifiUtils.get_security_description (security_type);
            var band_label = band;
            if (band_label.length == 0) {
                return security_label;
            }
            return "%s  %s".printf (security_label, band_label);
        }
    }

    public string signal_icon_name {
        owned get { return WifiUtils.signal_strength_to_icon (strength); }
    }

    public void update_from_ap (NM.DeviceWifi wifi_device, NM.AccessPoint ap) {
        access_point = ap;
        device = wifi_device;
        ssid_bytes = ap.get_ssid ();
        ssid = WifiUtils.ssid_to_string (ssid_bytes);
        bssid = ap.get_bssid ();
        strength = ap.get_strength ();
        frequency = ap.get_frequency ();
        security = WifiUtils.security_from_access_point (ap);
    }
}
