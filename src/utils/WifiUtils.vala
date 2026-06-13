using NM;

/**
 * Static utility methods for Wi-Fi data conversion and formatting.
 */
public class WifiUtils : GLib.Object {
    /**
     * Estimate dBm signal value from strength percentage (0–100).
     *
     * Uses a simple linear mapping: clamped(strength) / 2 - 100.
     *
     * @param strength  Signal strength percentage (0–100).
     * @return Estimated dBm value (typically -100 to -50).
     */
    public static int estimate_signal_dbm (int strength) {
        var clamped = strength.clamp (0, 100);
        return (clamped / 2) - 100;
    }

    /**
     * Format signal strength as "X dBm".
     *
     * @param strength  Signal strength percentage (0–100).
     * @return A string like "-65 dBm".
     */
    public static string signal_dbm_label (int strength) {
        return "%d dBm".printf (estimate_signal_dbm (strength));
    }

    /**
     * Format bitrate as "X Mbps" or empty string for zero.
     *
     * @param bitrate_mbps  Bitrate in megabits per second.
     * @return "1300 Mbps" or "" if bitrate is zero or negative.
     */
    public static string format_bitrate (int bitrate_mbps) {
        if (bitrate_mbps <= 0) {
            return "";
        }

        return "%d Mbps".printf (bitrate_mbps);
    }

    /**
     * Format a scan age timestamp into a human-readable relative
     * time string.
     *
     * @param last_scan_msec  Timestamp in milliseconds (from NM.Utils.get_timestamp_msec).
     * @return "Updated just now", "Updated 30 seconds ago", "Updated 2 minutes ago", etc.
     */
    public static string format_scan_age (int64 last_scan_msec) {
        if (last_scan_msec <= 0) {
            return "No recent scan";
        }

        var now = (int64) NM.Utils.get_timestamp_msec ();
        var age_seconds = (now - last_scan_msec) / 1000;
        if (age_seconds < 1) {
            return "Updated just now";
        }
        if (age_seconds == 1) {
            return "Updated 1 second ago";
        }
        if (age_seconds < 60) {
            return "Updated %ld seconds ago".printf ((long) age_seconds);
        }

        var age_minutes = age_seconds / 60;
        if (age_minutes == 1) {
            return "Updated 1 minute ago";
        }
        if (age_minutes < 60) {
            return "Updated %ld minutes ago".printf ((long) age_minutes);
        }

        var age_hours = age_minutes / 60;
        if (age_hours == 1) {
            return "Updated 1 hour ago";
        }
        return "Updated %ld hours ago".printf ((long) age_hours);
    }

    /**
     * Convert a connectivity state to a human-readable label.
     *
     * @param connectivity  The NM.ConnectivityState value.
     * @return "Internet access", "Limited connectivity", etc.
     */
    public static string connectivity_to_label (NM.ConnectivityState connectivity) {
        switch (connectivity) {
            case NM.ConnectivityState.FULL:
                return "Internet access";
            case NM.ConnectivityState.LIMITED:
                return "Limited connectivity";
            case NM.ConnectivityState.PORTAL:
                return "Captive portal detected";
            case NM.ConnectivityState.NONE:
                return "No network connection";
            default:
                return "Connectivity unknown";
        }
    }

    /**
     * Generate a connection health label based on signal strength,
     * security, and connectivity state.
     *
     * @param strength      Signal strength percentage (0–100).
     * @param insecure      Whether the network uses weak/no encryption.
     * @param connectivity  The current connectivity state.
     * @return "Captive portal", "Unstable", "Weak signal", "Open network", or "Stable".
     */
    public static string connection_health_label (int strength, bool insecure, NM.ConnectivityState connectivity) {
        if (connectivity == NM.ConnectivityState.PORTAL) {
            return "Captive portal";
        }
        if (connectivity == NM.ConnectivityState.LIMITED) {
            return "Unstable";
        }
        if (strength < 35) {
            return "Weak signal";
        }
        if (insecure) {
            return "Open network";
        }
        return "Stable";
    }

    /**
     * Get a human-readable security description from a type string.
     *
     * @param security_type  One of "WPA3", "WPA2", "WPA", "WEP",
     *                       "Enterprise", or any other value for Open.
     * @return "WPA3 Personal", "WPA2 Personal", "Enterprise", etc.
     */
    public static string get_security_description (string security_type) {
        switch (security_type) {
            case "WPA3":
                return "WPA3 Personal";
            case "WPA2":
                return "WPA2 Personal";
            case "WPA":
                return "WPA Personal";
            case "WEP":
                return "WEP";
            case "Enterprise":
                return "Enterprise";
            default:
                return "Open Network";
        }
    }

    /**
     * Convert a Bytes object to a valid UTF-8 SSID string.
     *
     * SSID is arbitrary bytes — it is NOT guaranteed to be
     * null-terminated or valid UTF-8.  This method:
     *
     *  1. Creates a properly null-terminated copy of the raw data.
     *  2. Checks for valid UTF-8.
     *  3. Falls back to escaped-hex representation for non-UTF-8
     *     and non-printable bytes.
     *
     * @param ssid  The raw SSID bytes from NetworkManager.
     * @return A clean display string, or "" if null or empty.
     */
    public static string ssid_to_string (GLib.Bytes? ssid) {
        if (ssid == null) {
            return "";
        }

        unowned uint8[] data = ssid.get_data ();
        if (data.length == 0) {
            return "";
        }

        uint8[] nt = new uint8[data.length + 1];
        GLib.Memory.copy (nt, data, data.length);
        nt[data.length] = 0;

        string raw = (string) nt;
        if (raw.validate ()) {
            return raw.strip ();
        }

        var sb = new StringBuilder ();
        for (int i = 0; i < data.length; i++) {
            if (data[i] >= 32 && data[i] <= 126) {
                sb.append_c ((char) data[i]);
            } else {
                sb.append_printf ("\\x%02x", data[i]);
            }
        }
        return sb.str;
    }

    /**
     * Determine WifiSecurity enum from access point flags and
     * capabilities.
     *
     * Checks RSN and WPA flags for 802.1X (Enterprise), SAE (WPA3),
     * PSK (WPA2/WPA), and the PRIVACY flag for WEP.
     *
     * @param ap  The access point to inspect.
     * @return The detected WifiSecurity value.
     */
    public static WifiSecurity security_from_access_point (NM.AccessPoint ap) {
        var flags = ap.get_flags ();
        var wpa_flags = ap.get_wpa_flags ();
        var rsn_flags = ap.get_rsn_flags ();

        if ((rsn_flags & NM.@80211ApSecurityFlags.KEY_MGMT_802_1X) != 0 ||
            (wpa_flags & NM.@80211ApSecurityFlags.KEY_MGMT_802_1X) != 0) {
            return WifiSecurity.ENTERPRISE;
        }
        if ((rsn_flags & NM.@80211ApSecurityFlags.KEY_MGMT_SAE) != 0) {
            return WifiSecurity.WPA3;
        }
        if ((rsn_flags & NM.@80211ApSecurityFlags.KEY_MGMT_PSK) != 0) {
            return WifiSecurity.WPA2;
        }
        if ((wpa_flags & NM.@80211ApSecurityFlags.KEY_MGMT_PSK) != 0) {
            return WifiSecurity.WPA;
        }
        if ((flags & NM.@80211ApFlags.PRIVACY) != 0) {
            return WifiSecurity.WEP;
        }
        return WifiSecurity.OPEN;
    }
}
