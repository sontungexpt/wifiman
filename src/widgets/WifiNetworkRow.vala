using Gtk;
using GLib;

public class WifiNetworkRow : Gtk.Box {
    public signal void request_actions (WifiNetwork network);

    private Gtk.Label section_label;
    private Gtk.Box row_box;
    private Gtk.Image signal_icon;
    private Gtk.Label ssid_label;
    private Gtk.Label subtitle_label;
    private Gtk.Box metrics_box;
    private Gtk.Label signal_metric_label;
    private Gtk.Label speed_metric_label;
    private Gtk.Label primary_status_label;
    private Gtk.Label security_status_label;

    private WifiNetwork? network;
    private ulong strength_id = 0;
    private ulong connected_id = 0;
    private ulong saved_id = 0;
    private ulong auto_connecting_id = 0;
    private ulong connecting_text_id = 0;
    private ulong security_id = 0;
    private ulong frequency_id = 0;

    public WifiNetwork? item_network {
        get { return network; }
    }

    public WifiNetworkRow () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        add_css_class ("wifi-list-item");

        section_label = new Gtk.Label ("");
        section_label.xalign = 0.0f;
        section_label.visible = false;
        section_label.add_css_class ("section-header");
        append (section_label);

        row_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row_box.hexpand = true;
        row_box.add_css_class ("network-row");
        row_box.set_cursor_from_name ("pointer");
        append (row_box);

        var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        content_box.hexpand = true;
        row_box.append (content_box);

        var title_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        title_row.hexpand = true;
        content_box.append (title_row);

        ssid_label = new Gtk.Label ("");
        ssid_label.xalign = 0.0f;
        ssid_label.hexpand = true;
        ssid_label.ellipsize = Pango.EllipsizeMode.END;
        ssid_label.add_css_class ("ssid");
        title_row.append (ssid_label);

        var status_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        status_box.halign = Gtk.Align.END;
        status_box.valign = Gtk.Align.CENTER;
        title_row.append (status_box);

        var badge_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        badge_box.halign = Gtk.Align.CENTER;
        badge_box.valign = Gtk.Align.CENTER;
        badge_box.add_css_class ("status-badges");
        status_box.append (badge_box);

        primary_status_label = new Gtk.Label ("");
        primary_status_label.visible = false;
        primary_status_label.add_css_class ("status-badge");
        primary_status_label.valign = Gtk.Align.CENTER;
        badge_box.append (primary_status_label);

        security_status_label = new Gtk.Label ("Secured");
        security_status_label.visible = false;
        security_status_label.add_css_class ("status-badge");
        security_status_label.add_css_class ("secured");
        security_status_label.valign = Gtk.Align.CENTER;
        badge_box.append (security_status_label);

        signal_icon = new Gtk.Image.from_icon_name ("network-wireless-signal-none-symbolic");
        signal_icon.pixel_size = 24;
        signal_icon.valign = Gtk.Align.CENTER;
        signal_icon.add_css_class ("signal-icon");
        signal_icon.margin_start = 0;
        signal_icon.margin_top = 0;
        signal_icon.margin_bottom = 0;
        status_box.append (signal_icon);

        subtitle_label = new Gtk.Label ("");
        subtitle_label.xalign = 0.0f;
        subtitle_label.ellipsize = Pango.EllipsizeMode.END;
        subtitle_label.wrap = false;
        subtitle_label.add_css_class ("network-subtitle");
        content_box.append (subtitle_label);

        metrics_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        metrics_box.visible = false;
        metrics_box.add_css_class ("network-metrics");
        content_box.append (metrics_box);

        signal_metric_label = build_metric_label ();
        metrics_box.append (signal_metric_label);

        speed_metric_label = build_metric_label ();
        metrics_box.append (speed_metric_label);

        var context_menu = new Gtk.GestureClick ();
        context_menu.set_button (3);
        context_menu.released.connect ((n_press, x, y) => {
            if (network != null) {
                request_actions (network);
            }
        });
        add_controller (context_menu);
    }

    private Gtk.Label build_metric_label () {
        var label = new Gtk.Label ("");
        label.visible = false;
        label.valign = Gtk.Align.CENTER;
        label.add_css_class ("network-metric");
        return label;
    }

    public void set_hero (bool hero) {
        if (hero) {
            add_css_class ("hero-network");
            row_box.add_css_class ("hero-network");
        } else {
            remove_css_class ("hero-network");
            row_box.remove_css_class ("hero-network");
        }
    }

    public void set_item (WifiListItem item) {
        disconnect_network ();
        set_hero (false);

        if (item.kind == WifiListItemKind.HEADER) {
            section_label.label = item.title;
            section_label.visible = true;
            row_box.visible = false;
            add_css_class ("header-item");
            remove_css_class ("network-item");
            return;
        }

        network = item.network;
        section_label.visible = false;
        row_box.visible = true;
        remove_css_class ("header-item");
        add_css_class ("network-item");

        if (network == null) {
            return;
        }

        update_all ();
        strength_id = network.notify["strength"].connect (() => update_signal ());
        connected_id = network.notify["is-connected"].connect (() => update_status ());
        saved_id = network.notify["is-saved"].connect (() => update_status ());
        auto_connecting_id = network.notify["auto-connecting"].connect (() => update_status ());
        connecting_text_id = network.notify["connecting-status-text"].connect (() => update_status ());
        security_id = network.notify["security"].connect (() => update_security ());
        frequency_id = network.notify["frequency"].connect (() => update_security ());
        network.notify["access-point-count"].connect (() => update_security ());
        network.notify["bitrate-mbps"].connect (() => update_metrics ());
        network.notify["scan-age-text"].connect (() => update_metrics ());
        network.notify["signal-dbm-text"].connect (() => update_metrics ());
        network.notify["ip-address"].connect (() => update_metrics ());
        network.notify["gateway"].connect (() => update_metrics ());
        network.notify["dns-summary"].connect (() => update_metrics ());
        network.notify["warning-text"].connect (() => update_metrics ());
        network.notify["health-text"].connect (() => update_metrics ());
    }

    public void clear () {
        disconnect_network ();
        section_label.visible = false;
        row_box.visible = false;
    }

    private void disconnect_network () {
        if (network == null) {
            return;
        }

        if (strength_id != 0) SignalHandler.disconnect (network, strength_id);
        if (connected_id != 0) SignalHandler.disconnect (network, connected_id);
        if (saved_id != 0) SignalHandler.disconnect (network, saved_id);
        if (auto_connecting_id != 0) SignalHandler.disconnect (network, auto_connecting_id);
        if (connecting_text_id != 0) SignalHandler.disconnect (network, connecting_text_id);
        if (security_id != 0) SignalHandler.disconnect (network, security_id);
        if (frequency_id != 0) SignalHandler.disconnect (network, frequency_id);

        strength_id = 0;
        connected_id = 0;
        saved_id = 0;
        auto_connecting_id = 0;
        connecting_text_id = 0;
        security_id = 0;
        frequency_id = 0;
        network = null;
    }

    private void update_all () {
        ssid_label.label = network.ssid;
        update_signal ();
        update_status ();
        update_security ();
        update_metrics ();
    }

    private void update_signal () {
        signal_icon.icon_name = network.signal_icon_name;
    }

    private void update_status () {
        var primary_status = network.primary_status;
        primary_status_label.label = primary_status;
        primary_status_label.visible = primary_status.length > 0;
        primary_status_label.remove_css_class ("connected");
        primary_status_label.remove_css_class ("connecting");
        primary_status_label.remove_css_class ("failed");
        primary_status_label.remove_css_class ("saved");
        row_box.remove_css_class ("connected");
        row_box.remove_css_class ("connecting");
        row_box.remove_css_class ("failed");
        row_box.remove_css_class ("saved");
        if (primary_status.length > 0) {
            primary_status_label.add_css_class (network.primary_status_style);
            row_box.add_css_class (network.primary_status_style);
        }
    }

    private void update_security () {
        subtitle_label.label = network.subtitle;
        security_status_label.label = network.security_badge_text;
        security_status_label.visible = network.security_badge_text.length > 0;
        security_status_label.remove_css_class ("warning");
        security_status_label.remove_css_class ("open");
        security_status_label.remove_css_class ("wep");
        security_status_label.remove_css_class ("wpa");
        security_status_label.remove_css_class ("wpa2");
        security_status_label.remove_css_class ("wpa3");
        security_status_label.remove_css_class ("enterprise");
        security_status_label.add_css_class (network.security_badge_style);
        metrics_box.visible = network.metrics_text.length > 0;
        update_metrics ();
    }

    private void update_metrics () {
        if (network == null) {
            return;
        }

        signal_metric_label.label = network.signal_dbm_text;
        signal_metric_label.visible = signal_metric_label.label.length > 0;

        speed_metric_label.label = network.bitrate_detail;
        speed_metric_label.visible = speed_metric_label.label.length > 0;

        metrics_box.visible = signal_metric_label.visible
            || speed_metric_label.visible;
    }
}
