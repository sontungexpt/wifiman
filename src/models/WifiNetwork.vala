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
    public int access_point_count { get; set; default = 0; }
    public int bitrate_mbps { get; set; default = 0; }
    public string ip_address { get; set; default = ""; }
    public string gateway { get; set; default = ""; }
    public string dns_summary { get; set; default = ""; }
    public string scan_age_text { get; set; default = ""; }
    public string signal_dbm_text { get; set; default = ""; }
    public string health_text { get; set; default = "Stable"; }
    public string warning_text { get; set; default = ""; }
    public WifiSecurity security { get; set; default = WifiSecurity.OPEN; }
    public bool is_connected { get; set; default = false; }
    public bool is_saved { get; set; default = false; }
    public bool auto_connecting { get; set; default = false; }
    public string connecting_status_text { get; set; default = ""; }
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

    public bool insecure {
        get { return security == WifiSecurity.OPEN || security == WifiSecurity.WEP; }
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
            if (auto_connecting) {
                if (connecting_status_text.length > 0) return connecting_status_text;
                return "Auto-connecting";
            }
            if (connection_failed) {
                return "Failed";
            }
            if (is_saved) {
                return "Previously saved";
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
            if (auto_connecting) {
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

    public string security_badge_text {
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

    public string security_badge_style {
        owned get {
            switch (security) {
                case WifiSecurity.WEP:
                    return "warning";
                case WifiSecurity.WPA:
                    return "saved";
                case WifiSecurity.WPA2:
                    return "connected";
                case WifiSecurity.WPA3:
                    return "connected";
                case WifiSecurity.ENTERPRISE:
                    return "connecting";
                default:
                    return "warning";
            }
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

    public string signal_detail {
        owned get {
            if (strength <= 0) {
                return "";
            }

            return "%s".printf (WifiUtils.signal_dbm_label (strength));
        }
    }

    public string bitrate_detail {
        owned get {
            return WifiUtils.format_bitrate (bitrate_mbps);
        }
    }

    public string subtitle {
        owned get {
            var builder = new GLib.StringBuilder ();
            append_summary_part (builder, WifiUtils.get_security_description (security_type));
            append_summary_part (builder, band);
            if (access_point_count > 1) {
                append_summary_part (builder, "%u APs".printf ((uint) access_point_count));
            }
            return builder.str;
        }
    }

    public string metrics_text {
        owned get {
            var builder = new GLib.StringBuilder ();
            append_summary_part (builder, signal_detail);
            append_summary_part (builder, bitrate_detail);
            append_summary_part (builder, scan_age_text);
            return builder.str;
        }
    }

    public string detail_summary {
        owned get {
            var builder = new GLib.StringBuilder ();
            append_summary_part (builder, ssid);
            append_summary_part (builder, signal_detail);
            append_summary_part (builder, bitrate_detail);
            append_summary_part (builder, ip_address);
            if (gateway.length > 0) {
                append_summary_part (builder, "Gateway %s".printf (gateway));
            }
            if (dns_summary.length > 0) {
                append_summary_part (builder, "DNS %s".printf (dns_summary));
            }
            append_summary_part (builder, warning_text);
            return builder.str;
        }
    }

    public string signal_icon_name {
        owned get { return WifiUtils.signal_strength_to_icon (strength); }
    }

    public void update_from_ap (NM.DeviceWifi wifi_device, NM.AccessPoint ap) {
        access_point = ap;
        device = wifi_device;
        access_point_count = 1;
        ssid_bytes = ap.get_ssid ();
        ssid = WifiUtils.ssid_to_string (ssid_bytes);
        bssid = ap.get_bssid ();
        strength = ap.get_strength ();
        frequency = ap.get_frequency ();
        security = WifiUtils.security_from_access_point (ap);
        signal_dbm_text = WifiUtils.signal_dbm_label (strength);
        warning_text = insecure ? "Open network" : "";
        health_text = WifiUtils.connection_health_label (strength, insecure, NM.ConnectivityState.UNKNOWN);
    }

    public void update_runtime_details (NM.ConnectivityState connectivity) {
        if (device != null) {
            var bitrate = device.get_bitrate ();
            bitrate_mbps = bitrate > 0 ? (int) (bitrate / 1000) : 0;
            scan_age_text = WifiUtils.format_scan_age (device.get_last_scan ());
        } else {
            bitrate_mbps = 0;
            scan_age_text = "";
        }

        signal_dbm_text = WifiUtils.signal_dbm_label (strength);

        ip_address = "";
        gateway = "";
        dns_summary = "";

        if (active_connection != null) {
            var ip4 = active_connection.get_ip4_config ();
            if (ip4 != null) {
                gateway = ip4.get_gateway ();
                var addresses = ip4.get_addresses ();
                if (addresses != null && addresses.length > 0) {
                    unowned NM.IPAddress? address = addresses.get (0);
                    if (address != null) {
                        ip_address = address.get_address ();
                    }
                }

                var nameservers = ip4.get_nameservers ();
                if (nameservers != null && nameservers.length > 0) {
                    dns_summary = nameservers[0];
                    if (nameservers.length > 1) {
                        dns_summary = "%s +%d".printf (nameservers[0], nameservers.length - 1);
                    }
                }
            }
        }

        if (warning_text.length == 0) {
            if (connectivity == NM.ConnectivityState.PORTAL) {
                warning_text = "Captive portal";
            } else if (insecure) {
                warning_text = security == WifiSecurity.WEP ? "Weak encryption" : "Open network";
            } else if (strength < 35) {
                warning_text = "Weak signal";
            } else if (connectivity == NM.ConnectivityState.LIMITED) {
                warning_text = "Limited connectivity";
            } else {
                warning_text = "";
            }
        }

        health_text = WifiUtils.connection_health_label (strength, insecure, connectivity);
    }

    private void append_summary_part (GLib.StringBuilder builder, string part) {
        if (part.length == 0) {
            return;
        }

        if (builder.len > 0) {
            builder.append ("  ·  ");
        }
        builder.append (part);
    }
}
