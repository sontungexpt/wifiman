using NM;

/**
 * Security types for Wi-Fi networks.
 *
 * Ordered from least to most secure.
 */
public enum WifiSecurity {
    /**
     * No encryption — open network.
     */
    OPEN,

    /**
     * Wired Equivalent Privacy — deprecated, weak encryption.
     */
    WEP,

    /**
     * Wi-Fi Protected Access (original) — deprecated.
     */
    WPA,

    /**
     * Wi-Fi Protected Access II — current standard.
     */
    WPA2,

    /**
     * Wi-Fi Protected Access III — next-generation.
     */
    WPA3,

    /**
     * 802.1X / WPA-Enterprise — uses RADIUS authentication.
     */
    ENTERPRISE
}

/**
 * Model representing a single Wi-Fi network.
 *
 * Aggregates data from NetworkManager access points, active
 * connections, and saved connection profiles.  Provides computed
 * properties for signal strength, security, band, status, and
 * runtime details (IP, gateway, DNS).
 */
public class WifiNetwork : GLib.Object {
    private string _ssid = "";
    /**
     * The network SSID (human-readable).
     */
    public string ssid {
        get { return _ssid; }
        set {
            _ssid = value;
            lower_ssid = value.down ();
        }
    }

    /**
     * Lower-cased version of the SSID for case-insensitive search.
     */
    public string lower_ssid { get; private set; default = ""; }

    /**
     * BSSID (MAC address) of the access point.
     */
    public string bssid { get; set; default = ""; }

    /**
     * Signal strength as a percentage (0–100).
     */
    public int strength { get; set; default = 0; }

    /**
     * Frequency in MHz (e.g. 2412 for 2.4 GHz).
     */
    public uint frequency { get; set; default = 0; }

    /**
     * Number of access points broadcasting this SSID.
     */
    public int access_point_count { get; set; default = 0; }

    /**
     * Connection bitrate in Mbps.
     */
    public int bitrate_mbps { get; set; default = 0; }

    /**
     * IPv4 address of the active connection, or empty.
     */
    public string ip_address { get; set; default = ""; }

    /**
     * Default gateway IP, or empty.
     */
    public string gateway { get; set; default = ""; }

    /**
     * DNS server summary (e.g. "8.8.8.8 +1"), or empty.
     */
    public string dns_summary { get; set; default = ""; }

    /**
     * Human-readable scan age text (e.g. "Updated 30 seconds ago").
     */
    public string scan_age_text { get; set; default = ""; }

    /**
     * Signal strength in dBm as text.
     */
    public string signal_dbm_text { get; set; default = ""; }

    /**
     * Connection health label (e.g. "Stable", "Weak signal").
     */
    public string health_text { get; set; default = "Stable"; }

    /**
     * Warning text (e.g. "Open network", "Captive portal").
     */
    public string warning_text { get; set; default = ""; }

    /**
     * The detected security type.
     */
    public WifiSecurity security { get; set; default = WifiSecurity.OPEN; }

    /**
     * Whether this network is currently connected.
     */
    public bool is_connected { get; set; default = false; }

    /**
     * Whether this network has a saved NetworkManager connection profile.
     */
    public bool is_saved { get; set; default = false; }

    /**
     * Whether the system is currently attempting to auto-connect.
     */
    public bool auto_connecting { get; set; default = false; }

    /**
     * Custom status text shown during an auto-connect attempt.
     */
    public string connecting_status_text { get; set; default = ""; }

    /**
     * The best access point for this network.
     */
    public NM.AccessPoint? access_point { get; set; default = null; }

    /**
     * The Wi-Fi device this network was found on.
     */
    public NM.DeviceWifi? device { get; set; default = null; }

    /**
     * The saved NM.RemoteConnection, if any.
     */
    public NM.RemoteConnection? saved_connection { get; set; default = null; }

    /**
     * The active NM.ActiveConnection, if connected or connecting.
     */
    public NM.ActiveConnection? active_connection { get; set; default = null; }

    /**
     * Raw SSID bytes as stored in NetworkManager.
     */
    public GLib.Bytes? ssid_bytes { get; set; default = null; }

    /**
     * Human-readable security type string.
     *
     * @return "WEP", "WPA", "WPA2", "WPA3", "Enterprise", or "Open".
     */
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

    /**
     * Whether the network uses any form of encryption.
     */
    public bool secured {
        get { return security != WifiSecurity.OPEN; }
    }

    /**
     * Whether the network uses weak or no encryption (OPEN or WEP).
     */
    public bool insecure {
        get { return security == WifiSecurity.OPEN || security == WifiSecurity.WEP; }
    }

    /**
     * Whether the network uses 802.1X / WPA-Enterprise.
     */
    public bool enterprise {
        get { return security == WifiSecurity.ENTERPRISE; }
    }

    /**
     * Whether the active connection is in the ACTIVATING state.
     */
    public bool is_connecting {
        get {
            return active_connection != null
                && active_connection.get_state () == NM.ActiveConnectionState.ACTIVATING;
        }
    }

    /**
     * Whether an active connection exists and has failed (DEACTIVATED
     * with a non-NONE reason).
     */
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

    /**
     * Primary status label for display in the UI.
     *
     * Returns "Connected", "Connecting", "Auto-connecting",
     * "Failed", "Previously saved", or empty.
     */
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

    /**
     * CSS class name for the primary status badge.
     *
     * @return "connected", "connecting", "failed", "saved", or empty.
     */
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

    /**
     * Short badge text for the security type.
     *
     * @return "WEP", "WPA", "WPA2", "WPA3", "Enterprise", or "Open".
     */
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

    /**
     * Human-readable band label derived from the frequency.
     *
     * @return "6 GHz", "5 GHz", "2.4 GHz", or empty.
     */
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

    /**
     * Signal detail as dBm text.
     *
     * @return Empty string if strength is zero, otherwise the dBm label.
     */
    public string signal_detail {
        owned get {
            if (strength <= 0) {
                return "";
            }

            return "%s".printf (WifiUtils.signal_dbm_label (strength));
        }
    }

    /**
     * Formatted bitrate string (e.g. "1300 Mbps").
     *
     * @return Empty string if bitrate is zero.
     */
    public string bitrate_detail {
        owned get {
            return WifiUtils.format_bitrate (bitrate_mbps);
        }
    }

    /**
     * Subtitle combining security, band, and AP count.
     *
     * @return A string like "WPA2 Personal  ·  5 GHz  ·  2 APs".
     */
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

    /**
     * Metrics text combining signal, bitrate, and scan age.
     *
     * @return A string like "-65 dBm  ·  1300 Mbps  ·  Updated 30s ago".
     */
    public string metrics_text {
        owned get {
            var builder = new GLib.StringBuilder ();
            append_summary_part (builder, signal_detail);
            append_summary_part (builder, bitrate_detail);
            append_summary_part (builder, scan_age_text);
            return builder.str;
        }
    }

    /**
     * Detail summary for the network info dialog.
     *
     * @return A string with SSID, signal, bitrate, IP, gateway,
     *         DNS, and warnings.
     */
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

    /**
     * Populate network properties from a scanned access point.
     *
     * @param wifi_device  The Wi-Fi device the AP belongs to.
     * @param ap           The access point to read data from.
     */
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

    /**
     * Update runtime details such as bitrate, IP, gateway, DNS,
     * and health warnings.
     *
     * Called periodically and when connectivity state changes.
     *
     * @param connectivity  The current NetworkManager connectivity state.
     */
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

    /**
     * Append a part to a summary string builder, separated by
     * bullet dots.
     *
     * @param builder  The string builder to append to.
     * @param part     The text to append (skipped if empty).
     */
    private void append_summary_part (GLib.StringBuilder builder, string part) {
        if (part.length == 0) {
            return;
        }

        if (builder.len > 0) {
            builder.append ("  \u00b7  ");
        }
        builder.append (part);
    }
}
