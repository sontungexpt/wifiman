using Gtk;
using GLib;

public class MainWindow : Gtk.ApplicationWindow {
    private WifiViewModel manager;
    private Gtk.Button refresh_button;
    private Gtk.Spinner spinner;
    private Gtk.SearchEntry search_entry;
    private Gtk.Stack stack;
    private Gtk.Box content_shell;
    private Gtk.Box hero_container;
    private Gtk.ListBox network_list;
    private Gtk.Box search_empty_box;
    private Gtk.Label search_empty_title;
    private Gtk.Label search_empty_subtitle;
    private Gtk.Label empty_title;
    private Gtk.Label empty_subtitle;
    private Gtk.Label error_title;
    private Gtk.Label error_subtitle;

    public MainWindow (Gtk.Application application) {
        Object (
            application: application,
            title: "Wi-Fi",
            default_width: 460,
            default_height: 680
        );

        load_css ();

        var nm_service = new NetworkManagerService ();
        manager = new WifiViewModel (nm_service);

        build_ui ();
        bind_state ();
        manager.scan.begin ();
    }

    private void load_css () {
        var provider = new Gtk.CssProvider ();
        provider.load_from_resource ("/org/example/WifiVala/style.css");
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    private void build_ui () {
        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        set_child (root);

        var header = new Gtk.HeaderBar ();
        header.show_title_buttons = true;
        set_titlebar (header);

        refresh_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic");
        refresh_button.tooltip_text = "Refresh";
        refresh_button.add_css_class ("flat");
        refresh_button.clicked.connect (() => manager.scan.begin ());
        header.pack_start (refresh_button);

        var menu_button = new Gtk.MenuButton ();
        menu_button.icon_name = "open-menu-symbolic";
        menu_button.tooltip_text = "Menu";
        menu_button.add_css_class ("flat");
        menu_button.popover = build_menu_popover ();
        header.pack_end (menu_button);

        spinner = new Gtk.Spinner ();
        spinner.width_request = 28;
        spinner.height_request = 28;
        header.pack_end (spinner);

        stack = new Gtk.Stack ();
        stack.vexpand = true;
        stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
        stack.transition_duration = 140;
        root.append (stack);

        stack.add_named (build_loading_page (), "loading");
        stack.add_named (build_empty_page (), "empty");
        stack.add_named (build_error_page (), "error");
        stack.add_named (build_results_page (), "results");
    }

    private Gtk.Popover build_menu_popover () {
        var popover = new Gtk.Popover ();
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;
        popover.set_child (box);

        var wifi_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        var label = new Gtk.Label ("Wi-Fi");
        label.hexpand = true;
        label.xalign = 0.0f;
        var wifi_switch = new Gtk.Switch ();
        wifi_switch.active = manager.wireless_enabled;
        wifi_switch.notify["active"].connect (() => {
            manager.wireless_enabled = wifi_switch.active;
        });
        wifi_row.append (label);
        wifi_row.append (wifi_switch);
        box.append (wifi_row);

        var refresh = new Gtk.Button.with_label ("Refresh Networks");
        refresh.clicked.connect (() => {
            manager.scan.begin ();
            popover.popdown ();
        });
        box.append (refresh);

        return popover;
    }

    private Gtk.Widget build_loading_page () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.add_css_class ("state-page");
        box.valign = Gtk.Align.CENTER;
        box.halign = Gtk.Align.CENTER;

        var loading = new Gtk.Spinner ();
        loading.spinning = true;
        loading.width_request = 40;
        loading.height_request = 40;
        box.append (loading);

        var label = new Gtk.Label ("Scanning for networks");
        label.add_css_class ("dim-label");
        box.append (label);
        return box;
    }

    private Gtk.Widget build_empty_page () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.add_css_class ("state-page");
        box.valign = Gtk.Align.CENTER;
        box.halign = Gtk.Align.CENTER;

        var icon = new Gtk.Image.from_icon_name ("network-wireless-symbolic");
        icon.pixel_size = 56;
        icon.add_css_class ("dim-label");
        box.append (icon);

        empty_title = new Gtk.Label ("No Networks Found");
        empty_title.add_css_class ("state-title");
        box.append (empty_title);

        empty_subtitle = new Gtk.Label ("Refresh to scan again.");
        empty_subtitle.add_css_class ("dim-label");
        box.append (empty_subtitle);

        return box;
    }

    private Gtk.Widget build_error_page () {
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
        box.add_css_class ("state-page");
        box.valign = Gtk.Align.CENTER;
        box.halign = Gtk.Align.CENTER;

        var icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
        icon.pixel_size = 56;
        icon.add_css_class ("error");
        box.append (icon);

        error_title = new Gtk.Label ("Wi-Fi Error");
        error_title.add_css_class ("state-title");
        box.append (error_title);

        error_subtitle = new Gtk.Label ("");
        error_subtitle.add_css_class ("dim-label");
        error_subtitle.wrap = true;
        error_subtitle.max_width_chars = 42;
        box.append (error_subtitle);

        return box;
    }

    private Gtk.Widget build_results_page () {
        var scrolled = new Gtk.ScrolledWindow ();
        scrolled.vexpand = true;
        scrolled.hscrollbar_policy = Gtk.PolicyType.NEVER;
        scrolled.add_css_class ("content-scroll");

        content_shell = new Gtk.Box (Gtk.Orientation.VERTICAL, 18);
        content_shell.halign = Gtk.Align.CENTER;
        content_shell.hexpand = false;
        content_shell.width_request = 600;
        content_shell.add_css_class ("content-shell");

        search_entry = new Gtk.SearchEntry ();
        search_entry.placeholder_text = "Search networks";
        search_entry.hexpand = true;
        search_entry.add_css_class ("premium-search");
        search_entry.search_changed.connect (() => manager.set_search_text (search_entry.text));
        content_shell.append (search_entry);

        hero_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        hero_container.hexpand = true;
        hero_container.add_css_class ("hero-container");
        content_shell.append (hero_container);

        search_empty_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        search_empty_box.hexpand = true;
        search_empty_box.valign = Gtk.Align.CENTER;
        search_empty_box.halign = Gtk.Align.CENTER;
        search_empty_box.add_css_class ("search-empty");

        search_empty_title = new Gtk.Label ("No networks match your search");
        search_empty_title.add_css_class ("state-title");
        search_empty_box.append (search_empty_title);

        search_empty_subtitle = new Gtk.Label ("Clear the search field to show all networks again.");
        search_empty_subtitle.add_css_class ("dim-label");
        search_empty_box.append (search_empty_subtitle);

        content_shell.append (search_empty_box);

        var network_panel = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        network_panel.hexpand = true;
        network_panel.add_css_class ("network-panel");

        network_list = new Gtk.ListBox ();
        network_list.hexpand = true;
        network_list.selection_mode = Gtk.SelectionMode.NONE;
        network_list.show_separators = true;
        network_list.activate_on_single_click = true;
        network_list.row_activated.connect (on_row_activated);
        network_list.add_css_class ("network-listbox");
        network_panel.append (network_list);

        content_shell.append (network_panel);
        scrolled.set_child (content_shell);
        return scrolled;
    }

    private void bind_state () {
        manager.notify["scanning"].connect (update_state);
        manager.notify["has-networks"].connect (update_state);
        manager.notify["search-active"].connect (update_state);
        manager.notify["has-visible-networks"].connect (update_state);
        manager.items.items_changed.connect (() => {
            update_state ();
            render_networks ();
        });
        manager.error.connect ((message) => {
            error_subtitle.label = message;
            stack.visible_child_name = "error";
        });
        update_state ();
    }

    private void update_state () {
        refresh_button.sensitive = !manager.scanning;
        spinner.spinning = manager.scanning;
        spinner.visible = manager.scanning;

        if (manager.scanning && !manager.has_networks) {
            stack.visible_child_name = "loading";
        } else if (manager.search_active && !manager.has_visible_networks) {
            stack.visible_child_name = "results";
        } else if (manager.has_networks) {
            stack.visible_child_name = "results";
        } else {
            stack.visible_child_name = "empty";
        }

        render_networks ();
    }

    private void render_networks () {
        if (hero_container == null || network_list == null) {
            return;
        }

        clear_container (hero_container);
        network_list.remove_all ();

        bool show_search_empty = manager.search_active && !manager.has_visible_networks;
        search_empty_box.visible = show_search_empty;
        hero_container.visible = !show_search_empty;
        network_list.visible = !show_search_empty;

        bool hero_rendered = false;
        string current_section = "";

        for (uint i = 0; i < manager.items.get_n_items (); i++) {
            var item = manager.items.get_item (i) as WifiListItem;
            if (item == null) {
                continue;
            }

            if (item.kind == WifiListItemKind.HEADER) {
                current_section = item.title;
                if (current_section == "Connected") {
                    continue;
                }

                network_list.append (build_section_row (current_section));
                continue;
            }

            var network = item.network;
            if (network == null) {
                continue;
            }

            if (network.is_connected && !hero_rendered) {
                hero_container.append (build_hero_row (item));
                hero_rendered = true;
                continue;
            }

            if (current_section == "Connected") {
                continue;
            }

            network_list.append (build_network_row (item, false));
        }

        if (!show_search_empty) {
            hero_container.visible = hero_container.get_first_child () != null;
        }
    }

    private void clear_container (Gtk.Box box) {
        while (true) {
            var child = box.get_first_child ();
            if (child == null) {
                break;
            }
            box.remove (child);
        }
    }

    private Gtk.Widget build_section_row (string title) {
        var row = new Gtk.ListBoxRow ();
        row.selectable = false;
        row.activatable = false;
        row.add_css_class ("section-row");

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        box.add_css_class ("section-row-box");

        var label = new Gtk.Label (title);
        label.xalign = 0.0f;
        label.add_css_class ("section-title");
        box.append (label);

        row.set_child (box);
        return row;
    }

    private Gtk.Widget build_network_row (WifiListItem item, bool hero) {
        var row = new Gtk.ListBoxRow ();
        row.selectable = false;
        row.activatable = true;
        row.add_css_class ("network-list-row");

        var widget = new WifiNetworkRow ();
        widget.set_item (item);
        widget.set_hero (hero);
        row.set_child (widget);
        return row;
    }

    private Gtk.Widget build_hero_row (WifiListItem item) {
        var widget = new WifiNetworkRow ();
        widget.set_item (item);
        widget.set_hero (true);

        var gesture = new Gtk.GestureClick ();
        gesture.released.connect ((n_press, x, y) => {
            activate_network (item.network);
        });
        widget.add_controller (gesture);

        return widget;
    }

    private void on_row_activated (Gtk.ListBoxRow row) {
        var child = row.get_child ();
        var network_row = child as WifiNetworkRow;
        if (network_row == null || network_row.item_network == null) {
            return;
        }

        activate_network (network_row.item_network);
    }

    private void activate_network (WifiNetwork? network) {
        if (network == null) {
            return;
        }

        if (network.is_connected || network.is_saved) {
            show_network_actions (network);
        } else if (!network.secured) {
            connect_network.begin (network);
        } else {
            show_connect_dialog (network);
        }
    }

    private async void connect_network (WifiNetwork network, string? password = null, string? username = null) {
        try {
            yield manager.connect_network (network, password, username);
        } catch (GLib.Error e) {
            error_subtitle.label = e.message;
            stack.visible_child_name = "error";
        }
    }

    private void show_connect_dialog (WifiNetwork network) {
        var dialog = new Gtk.Window ();
        dialog.title = "Connect to %s".printf (network.ssid);
        dialog.transient_for = this;
        dialog.modal = true;
        dialog.resizable = false;
        dialog.default_width = 360;
        dialog.add_css_class ("dialog-window");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18);
        box.margin_top = 24;
        box.margin_bottom = 24;
        box.margin_start = 24;
        box.margin_end = 24;
        dialog.set_child (box);

        var title = new Gtk.Label ("Connect to %s".printf (network.ssid));
        title.xalign = 0.0f;
        title.add_css_class ("dialog-title");
        box.append (title);

        Gtk.Entry? username_entry = null;
        if (network.enterprise) {
            username_entry = new Gtk.Entry ();
            username_entry.placeholder_text = "Username";
            box.append (username_entry);
        }

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.placeholder_text = "Password";
        box.append (password_entry);

        var error_label = new Gtk.Label ("");
        error_label.xalign = 0.0f;
        error_label.wrap = true;
        error_label.visible = false;
        error_label.add_css_class ("error");
        box.append (error_label);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        actions.halign = Gtk.Align.END;
        var cancel = new Gtk.Button.with_label ("Cancel");
        var connect = new Gtk.Button.with_label ("Connect");
        connect.add_css_class ("suggested-action");
        actions.append (cancel);
        actions.append (connect);
        box.append (actions);

        cancel.clicked.connect (() => dialog.close ());
        connect.clicked.connect (() => {
            connect.sensitive = false;
            var username = username_entry != null ? username_entry.text : null;
            manager.connect_network.begin (network, password_entry.text, username, (obj, res) => {
                try {
                    manager.connect_network.end (res);
                    dialog.close ();
                } catch (GLib.Error e) {
                    error_label.label = e.message;
                    error_label.visible = true;
                    connect.sensitive = true;
                }
            });
        });

        dialog.present ();
    }

    private void show_network_actions (WifiNetwork network) {
        var dialog = new Gtk.Window ();
        dialog.title = network.ssid;
        dialog.transient_for = this;
        dialog.modal = true;
        dialog.resizable = false;
        dialog.default_width = 360;
        dialog.add_css_class ("dialog-window");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 18);
        box.margin_top = 24;
        box.margin_bottom = 24;
        box.margin_start = 24;
        box.margin_end = 24;
        dialog.set_child (box);

        var title = new Gtk.Label (network.ssid);
        title.xalign = 0.0f;
        title.add_css_class ("dialog-title");
        box.append (title);

        var detail = new Gtk.Label (network.subtitle);
        detail.xalign = 0.0f;
        detail.add_css_class ("dim-label");
        box.append (detail);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        actions.halign = Gtk.Align.END;
        var close = new Gtk.Button.with_label ("Close");
        actions.append (close);

        if (network.is_connected) {
            var disconnect = new Gtk.Button.with_label ("Disconnect");
            disconnect.add_css_class ("destructive-action");
            disconnect.clicked.connect (() => {
                manager.disconnect_network.begin (network);
                dialog.close ();
            });
            actions.append (disconnect);
        } else {
            var connect = new Gtk.Button.with_label ("Connect");
            connect.add_css_class ("suggested-action");
            connect.clicked.connect (() => {
                connect_network.begin (network);
                dialog.close ();
            });
            actions.append (connect);
        }

        if (network.is_saved) {
            var forget = new Gtk.Button.with_label ("Forget");
            forget.add_css_class ("destructive-action");
            forget.clicked.connect (() => {
                manager.forget_network.begin (network);
                dialog.close ();
            });
            actions.append (forget);
        }

        close.clicked.connect (() => dialog.close ());
        box.append (actions);
        dialog.present ();
    }
}
