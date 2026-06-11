using GLib;
using NM;

public class WifiUtils : GLib.Object {
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
