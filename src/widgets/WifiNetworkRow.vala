using Gtk;

/**
 * A row widget for displaying a Wi-Fi network in a list.
 *
 * Shows an SSID label, signal icon, security badge, status badge,
 * subtitle, and metrics (signal dBm, bitrate).  Supports both
 * normal and hero (connected) styling and emits request_actions
 * on right-click.
 */
public class WifiNetworkRow : Gtk.Box {
    /**
     * Emitted when the user requests action on the network (e.g.
     * right-click).
     *
     * @param network  The network associated with this row.
     */
    public signal void request_actions (WifiNetwork network);

    private Gtk.Box row_box;
    private SignalIcon signal_icon;
    private Gtk.Label ssid_label;
    private Gtk.Label subtitle_label;
    private Gtk.Box metrics_box;
    private Gtk.Label signal_metric_label;
    private Gtk.Label speed_metric_label;
    private Gtk.Label primary_status_label;
    private Gtk.Label security_status_label;

    private unowned WifiNetwork? network;
    private GLib.Binding? signal_binding = null;
    private ulong connected_id = 0;
    private ulong saved_id = 0;
    private ulong auto_connecting_id = 0;
    private ulong connecting_text_id = 0;
    private ulong bitrate_id = 0;
    private ulong scan_age_id = 0;
    private ulong signal_dbm_id = 0;
    private ulong ip_address_id = 0;
    private ulong gateway_id = 0;
    private ulong dns_id = 0;
    private ulong warning_id = 0;
    private ulong health_id = 0;

    /**
     * The currently displayed network, or null if the row is empty.
     */
    public unowned WifiNetwork? item_network {
        get { return network; }
    }

    /**
     * Construct the network row widget with signal icon, labels,
     * and metrics.
     *
     * Builds the full row layout including SSID, status badges,
     * security badge, signal icon, subtitle, and metric labels.
     * Attaches a right-click gesture for the context menu.
     */
    public WifiNetworkRow () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        add_css_class ("wifi-list-item");

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

        status_box.append (badge_box);

        primary_status_label = new Gtk.Label ("");
        primary_status_label.visible = false;
        primary_status_label.add_css_class ("status-badge");
        primary_status_label.valign = Gtk.Align.CENTER;
        badge_box.append (primary_status_label);

        security_status_label = new Gtk.Label ("Secured");
        security_status_label.visible = false;
        security_status_label.add_css_class ("status-badge");

        security_status_label.valign = Gtk.Align.CENTER;
        badge_box.append (security_status_label);

        signal_icon = new SignalIcon ();
        signal_icon.valign = Gtk.Align.CENTER;
        signal_icon.add_css_class ("signal-icon");
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

    /**
     * Create a reusable metric label (hidden by default).
     *
     * @return A hidden Gtk.Label with the network-metric style class.
     */
    private Gtk.Label build_metric_label () {
        var label = new Gtk.Label ("");
        label.visible = false;
        label.valign = Gtk.Align.CENTER;
        label.add_css_class ("network-metric");
        return label;
    }

    /**
     * Toggle between hero (connected) and normal row styling.
     *
     * @param hero  Whether to apply hero (connected) styling.
     */
    public void set_hero (bool hero) {
        if (hero) {
            add_css_class ("hero-network");
        } else {
            remove_css_class ("hero-network");
        }
    }

    /**
     * Populate the row with data from a WifiListItem and bind
     * property notifications.
     *
     * All fields are populated and property change handlers are
     * attached to the WifiNetwork.
     *
     * @param item  The WifiListItem to render.
     */
    public void set_item (WifiListItem item) {
        Logger.debug ("NetworkRow", "Setting item: kind=%s", item.kind.to_string ());
        disconnect_network ();
        set_hero (false);

        network = item.network;
        row_box.visible = true;

        if (network == null) {
            return;
        }

        update_all ();
        signal_binding = network.bind_property ("strength", signal_icon, "strength",
            BindingFlags.SYNC_CREATE, null, null);
        connected_id = network.notify["is-connected"].connect (() => update_status ());
        saved_id = network.notify["is-saved"].connect (() => update_status ());
        auto_connecting_id = network.notify["auto-connecting"].connect (() => update_status ());
        connecting_text_id = network.notify["connecting-status-text"].connect (() => update_status ());
        bitrate_id = network.notify["bitrate-mbps"].connect (() => update_metrics ());
        scan_age_id = network.notify["scan-age-text"].connect (() => update_metrics ());
        signal_dbm_id = network.notify["signal-dbm-text"].connect (() => update_metrics ());
        ip_address_id = network.notify["ip-address"].connect (() => update_metrics ());
        gateway_id = network.notify["gateway"].connect (() => update_metrics ());
        dns_id = network.notify["dns-summary"].connect (() => update_metrics ());
        warning_id = network.notify["warning-text"].connect (() => update_metrics ());
        health_id = network.notify["health-text"].connect (() => update_metrics ());
    }

    /**
     * Disconnect all property change handlers from the current
     * network.
     */
    private void disconnect_network () {
        if (network == null) {
            return;
        }

        if (signal_binding != null) {
            signal_binding.unbind ();
            signal_binding = null;
        }
        if (connected_id != 0) SignalHandler.disconnect (network, connected_id);
        if (saved_id != 0) SignalHandler.disconnect (network, saved_id);
        if (auto_connecting_id != 0) SignalHandler.disconnect (network, auto_connecting_id);
        if (connecting_text_id != 0) SignalHandler.disconnect (network, connecting_text_id);
        if (bitrate_id != 0) SignalHandler.disconnect (network, bitrate_id);
        if (scan_age_id != 0) SignalHandler.disconnect (network, scan_age_id);
        if (signal_dbm_id != 0) SignalHandler.disconnect (network, signal_dbm_id);
        if (ip_address_id != 0) SignalHandler.disconnect (network, ip_address_id);
        if (gateway_id != 0) SignalHandler.disconnect (network, gateway_id);
        if (dns_id != 0) SignalHandler.disconnect (network, dns_id);
        if (warning_id != 0) SignalHandler.disconnect (network, warning_id);
        if (health_id != 0) SignalHandler.disconnect (network, health_id);

        connected_id = 0;
        saved_id = 0;
        auto_connecting_id = 0;
        connecting_text_id = 0;
        bitrate_id = 0;
        scan_age_id = 0;
        signal_dbm_id = 0;
        ip_address_id = 0;
        gateway_id = 0;
        dns_id = 0;
        warning_id = 0;
        health_id = 0;
        network = null;
    }

    /**
     * Refresh all UI elements from the current network state.
     */
    private void update_all () {
        ssid_label.label = network.ssid;
        update_status ();
        update_security ();
        update_metrics ();
    }

    /**
     * Update the connected/connecting/saved/failed status badge.
     *
     * Reads network.primary_status and primary_status_style to
     * set both the label text and CSS style class.
     */
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

    /**
     * Update the security badge and subtitle text.
     *
     * Reads network.security_badge_text, security_badge_style,
     * and subtitle to update the corresponding labels.
     */
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
    }

    /**
     * Update signal and speed metric labels.
     *
     * Reads network.signal_dbm_text and bitrate_detail to update
     * the metric labels.  Hides the metrics box if both are empty.
     */
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
