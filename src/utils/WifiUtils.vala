using GLib;
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
     * Format signal strength as a percentage string.
     *
     * @param strength  Signal strength percentage (0–100).
     * @return A string like "75%".
     */
    public static string signal_quality_label (int strength) {
        return "%d%%".printf (strength.clamp (0, 100));
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
     * Join an array of strings with a separator, skipping null
     * and empty values.
     *
     * @param values     The array of strings to join.
     * @param separator  The separator string.
     * @return The joined string.
     */
    public static string join_nonempty (string[] values, string separator) {
        var builder = new GLib.StringBuilder ();
        bool first = true;

        foreach (var value in values) {
            if (value == null || value.length == 0) {
                continue;
            }

            if (!first) {
                builder.append (separator);
            }
            builder.append (value);
            first = false;
        }

        return builder.str;
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
     * Convert a connectivity state to a CSS style class.
     *
     * @param connectivity  The NM.ConnectivityState value.
     * @return "connected", "warning", "connecting", "failed", or "saved".
     */
    public static string connectivity_to_style (NM.ConnectivityState connectivity) {
        switch (connectivity) {
            case NM.ConnectivityState.FULL:
                return "connected";
            case NM.ConnectivityState.PORTAL:
                return "warning";
            case NM.ConnectivityState.LIMITED:
                return "connecting";
            case NM.ConnectivityState.NONE:
                return "failed";
            default:
                return "saved";
        }
    }

    /**
     * Convert an active connection state reason to a human-readable
     * description.
     *
     * @param reason  The NM.ActiveConnectionStateReason value.
     * @return "Disconnected by user", "Authentication failed", etc.
     */
    public static string active_connection_reason_to_label (NM.ActiveConnectionStateReason reason) {
        switch (reason) {
            case NM.ActiveConnectionStateReason.USER_DISCONNECTED:
                return "Disconnected by user";
            case NM.ActiveConnectionStateReason.DEVICE_DISCONNECTED:
                return "Device disconnected";
            case NM.ActiveConnectionStateReason.IP_CONFIG_INVALID:
                return "IP configuration invalid";
            case NM.ActiveConnectionStateReason.NO_SECRETS:
                return "Missing credentials";
            case NM.ActiveConnectionStateReason.LOGIN_FAILED:
                return "Authentication failed";
            default:
                return "Connection failed";
        }
    }

    /**
     * Convert a device state reason to a human-readable description.
     *
     * @param reason  The NM.DeviceStateReason value.
     * @return "Missing credentials", "Authentication failed", etc.
     */
    public static string device_state_reason_to_label (NM.DeviceStateReason reason) {
        switch (reason) {
            case NM.DeviceStateReason.NO_SECRETS:
                return "Missing credentials";
            case NM.DeviceStateReason.SUPPLICANT_DISCONNECT:
            case NM.DeviceStateReason.SUPPLICANT_FAILED:
            case NM.DeviceStateReason.SUPPLICANT_TIMEOUT:
                return "Authentication failed";
            case NM.DeviceStateReason.DHCP_START_FAILED:
            case NM.DeviceStateReason.DHCP_ERROR:
            case NM.DeviceStateReason.DHCP_FAILED:
                return "DHCP timeout";
            case NM.DeviceStateReason.IP_CONFIG_UNAVAILABLE:
            case NM.DeviceStateReason.IP_CONFIG_EXPIRED:
                return "IP configuration unavailable";
            default:
                return "Connection failed";
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
     * Map signal strength (0–100) to a symbolic icon name.
     *
     * @param strength  Signal strength percentage (0–100).
     * @return Icon name like "network-wireless-signal-excellent-symbolic".
     */
    public static string signal_strength_to_icon (int strength) {
        if (strength >= 80) return "network-wireless-signal-excellent-symbolic";
        if (strength >= 60) return "network-wireless-signal-good-symbolic";
        if (strength >= 40) return "network-wireless-signal-ok-symbolic";
        if (strength >= 20) return "network-wireless-signal-weak-symbolic";
        return "network-wireless-signal-none-symbolic";
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
     * Handles non-UTF-8 data via make_valid() and strips
     * leading/trailing whitespace.
     *
     * @param ssid  The raw SSID bytes from NetworkManager.
     * @return A clean UTF-8 string, or "" if null or empty.
     */
    public static string ssid_to_string (GLib.Bytes? ssid) {
        if (ssid == null) {
            return "";
        }

        unowned uint8[] data = ssid.get_data ();
        if (data.length == 0) {
            return "";
        }

        return ((string) data).make_valid ().strip ();
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

    /**
     * Compare two SSID byte arrays for equality.
     *
     * @param a  First SSID bytes.
     * @param b  Second SSID bytes.
     * @return true if both are null or both have identical content.
     */
    public static bool ssid_equal (GLib.Bytes? a, GLib.Bytes? b) {
        if (a == null || b == null) {
            return a == b;
        }
        return a.compare (b) == 0;
    }
}
