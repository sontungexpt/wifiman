using GLib;
using NM;

public class WifiUtils : GLib.Object {
    public static int estimate_signal_dbm (int strength) {
        var clamped = strength.clamp (0, 100);
        return (clamped / 2) - 100;
    }

    public static string signal_dbm_label (int strength) {
        return "%d dBm".printf (estimate_signal_dbm (strength));
    }

    public static string signal_quality_label (int strength) {
        return "%d%%".printf (strength.clamp (0, 100));
    }

    public static string format_bitrate (int bitrate_mbps) {
        if (bitrate_mbps <= 0) {
            return "";
        }

        return "%d Mbps".printf (bitrate_mbps);
    }

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

    public static string signal_strength_to_icon (int strength) {
        if (strength >= 80) return "network-wireless-signal-excellent-symbolic";
        if (strength >= 60) return "network-wireless-signal-good-symbolic";
        if (strength >= 40) return "network-wireless-signal-ok-symbolic";
        if (strength >= 20) return "network-wireless-signal-weak-symbolic";
        return "network-wireless-signal-none-symbolic";
    }

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

    public static string ssid_to_string (GLib.Bytes? ssid) {
        if (ssid == null) {
            return "";
        }

        unowned uint8[] data = ssid.get_data ();
        if (data.length == 0) {
            return "";
        }

        return ((string) data).make_valid ();
    }

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

    public static bool ssid_equal (GLib.Bytes? a, GLib.Bytes? b) {
        if (a == null || b == null) {
            return a == b;
        }
        return a.compare (b) == 0;
    }
}
