using Gtk;

/**
 * Main application window for the Wi-Fi manager.
 *
 * Builds and manages the full UI: header bar, network list,
 * status strip, portal banner, and dialogs.  Binds to a
 * WifiViewModel to reflect network state changes.
 */
public class MainWindow : Gtk.ApplicationWindow {
    private WifiViewModel manager;
    private Gtk.Button refresh_button;
    private Gtk.Popover? menu_popover = null;
    private Gtk.Spinner spinner;
    private Gtk.SearchEntry search_entry;
    private Gtk.Stack stack;
    private Gtk.Box content_shell;
    private Gtk.Box status_strip;
    private Gtk.Label scan_status_label;
    private Gtk.Label connectivity_status_label;
    private Gtk.Box portal_banner;
    private Gtk.Label portal_label;
    private Gtk.Button portal_refresh_button;
    private Gtk.Box hero_container;
    private Gtk.ListBox network_list;
    private Gtk.Box search_empty_box;
    private Gtk.Label search_empty_title;
    private Gtk.Label search_empty_subtitle;
    private Gtk.Label empty_title;
    private Gtk.Label empty_subtitle;
    private Gtk.Label error_title;
    private Gtk.Label error_subtitle;
    private uint search_debounce_id = 0;
    private bool _quitting = false;
    private bool _rendering = false;
    private bool _render_needed = false;
    private bool _connect_dialog_active = false;

    /**
     * Construct the main window, initialise services and UI.
     *
     * Creates a NetworkManagerService and WifiViewModel, builds
     * the full interface, binds state signals, and starts the
     * first scan.
     *
     * @param application  The owning Gtk.Application.
     */
    public MainWindow (Gtk.Application application) {
        Object (
            application: application,
            title: "Wi-Fi",
            default_width: 460,
            default_height: 680
        );

        Logger.info ("MainWindow", "Initializing MainWindow");
        load_css ();

        var nm_service = new NetworkManagerService ();
        manager = new WifiViewModel (nm_service);

        build_ui ();
        bind_state ();
        manager.scan.begin ();

        close_request.connect (() => {
            quit_application ();
            return true;
        });

        notify["visible"].connect (() => {
            manager.set_window_hidden (!visible);
        });
    }

    /**
     * Fully shut down the application and exit the process.
     *
     * Cleans up timers and signal handlers, then calls
     * Gtk.Application.quit() to destroy windows, remove the
     * D-Bus name, and exit the main loop.
     */
    private void quit_application () {
        if (_quitting) return;
        _quitting = true;
        Logger.info ("MainWindow", "Shutting down application");
        manager.shutdown ();
        application.quit ();
    }

    /**
     * Toggle window visibility between shown and hidden.
     */
    public void toggle_visibility () {
        Logger.debug ("MainWindow", "Toggling window visibility, currently: %s", visible.to_string ());
        if (visible) {
            quit_application ();
        } else {
            present ();
        }
    }

    /**
     * Load the application CSS from the GResource bundle.
     */
    private void load_css () {
        Logger.debug ("MainWindow", "Loading CSS");
        var provider = new Gtk.CssProvider ();
        provider.load_from_resource ("/io/github/sontungexpt/wifiman/style.css");
        Gtk.StyleContext.add_provider_for_display (
            Gdk.Display.get_default (),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }

    /**
     * Build the main user interface layout.
     *
     * Constructs the header bar, stack (loading/empty/error/results
     * pages), and wires navigation.
     */
    private void build_ui () {
        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        set_child (root);

        var header = new Gtk.HeaderBar ();
        header.show_title_buttons = true;
        var title_label = new Gtk.Label ("Wi-Fi");
        title_label.add_css_class ("app-title");
        header.title_widget = title_label;
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

    /**
     * Build the popover menu with Wi-Fi toggle, colour scheme, and refresh.
     *
     * @return The configured Gtk.Popover.
     */
    private Gtk.Popover build_menu_popover () {
        menu_popover = new Gtk.Popover ();
        if (this.has_css_class ("dark-mode"))
            menu_popover.add_css_class ("dark-mode");

        try {
            var css = new Gtk.CssProvider ();
            css.load_from_string (
                ".dark-mode { background: #111827; border: none; outline: none; padding: 0; } " +
                "popover:not(.dark-mode) { background: #ffffff; border: none; outline: none; padding: 0; }"
            );
            menu_popover.get_style_context().add_provider (css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        } catch (GLib.Error e) {
            Logger.warn ("MainWindow", "Failed to load popover CSS override: %s", e.message);
        }

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
        box.add_css_class ("popover-content");
        menu_popover.set_child (box);

        var wifi_switch = new Gtk.Switch ();
        wifi_switch.active = manager.wireless_enabled;
        wifi_switch.notify["active"].connect (() => {
            manager.wireless_enabled = wifi_switch.active;
            if (!wifi_switch.active) {
                this.close ();
            }
        });
        box.append (build_setting_row ("Wi-Fi", wifi_switch));

        var app = this.application as Application;
        if (app != null)
            box.append (build_setting_row ("Color Scheme", build_color_scheme_radios (app)));

        var refresh = new Gtk.Button.with_label ("Refresh Networks");
        refresh.clicked.connect (() => {
            manager.scan.begin ();
            menu_popover.popdown ();
        });
        box.append (refresh);

        return menu_popover;
    }

    /**
     * Build a labelled row with a control widget for the popover.
     *
     * @param text     The label text.
     * @param control  The widget to place to the right of the label.
     * @return A horizontal Gtk.Box containing the label and control.
     */
    private Gtk.Box build_setting_row (string text, Gtk.Widget control) {
        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        var label = new Gtk.Label (text);
        label.hexpand = true;
        label.xalign = 0.0f;
        label.add_css_class ("popover-label");
        row.append (label);
        row.append (control);
        return row;
    }

    /**
     * Build radio buttons for system/light/dark colour scheme selection.
     *
     * @param app  The Application instance to read/save the scheme.
     * @return A horizontal Gtk.Box with check buttons.
     */
    private Gtk.Box build_color_scheme_radios (Application app) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        string current = app.load_color_scheme ();
        string[] schemes = {"system", "light", "dark"};
        Gtk.CheckButton? group = null;

        foreach (string scheme in schemes) {
            var rb = new Gtk.CheckButton.with_label (
                scheme == "system" ? "System" : scheme == "light" ? "Light" : "Dark"
            );
            if (group == null)
                group = rb;
            else
                rb.group = group;

            if (current == scheme)
                rb.active = true;

            rb.toggled.connect (() => {
                if (rb.active) {
                    app.save_color_scheme (scheme);
                    app.apply_color_scheme (scheme);
                    sync_popover_class ();
                }
            });
            box.append (rb);
        }

        return box;
    }

    /**
     * Sync the dark-mode CSS class to the popover surface.
     *
     * Should be called whenever the window's colour scheme changes.
     */
    public void sync_popover_class () {
        if (menu_popover == null) return;
        if (this.has_css_class ("dark-mode"))
            menu_popover.add_css_class ("dark-mode");
        else
            menu_popover.remove_css_class ("dark-mode");
    }

    /**
     * Build the loading spinner page shown during a scan.
     *
     * @return A Gtk.Widget displaying a spinner and "Scanning" text.
     */
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

    /**
     * Build the empty state page shown when no networks are found.
     *
     * @return A Gtk.Widget with an icon and "No Networks Found" text.
     */
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

    /**
     * Build the error state page shown on connection failures.
     *
     * @return A Gtk.Widget with a warning icon and error labels.
     */
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

    /**
     * Build the results page with search, status strip, and network list.
     *
     * @return A scrolled Gtk.Widget containing the full results layout.
     */
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
        ((Gtk.Editable) search_entry).changed.connect (() => queue_search_update ());
        content_shell.append (search_entry);

        status_strip = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        status_strip.hexpand = true;
        status_strip.add_css_class ("status-strip");

        scan_status_label = new Gtk.Label ("");
        scan_status_label.hexpand = true;
        scan_status_label.xalign = 0.0f;
        scan_status_label.add_css_class ("dim-label");
        status_strip.append (scan_status_label);

        connectivity_status_label = new Gtk.Label ("");
        connectivity_status_label.xalign = 1.0f;
        connectivity_status_label.add_css_class ("dim-label");
        status_strip.append (connectivity_status_label);

        content_shell.append (status_strip);

        portal_banner = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        portal_banner.hexpand = true;
        portal_banner.visible = false;
        portal_banner.add_css_class ("portal-banner");

        var portal_icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
        portal_icon.pixel_size = 16;
        portal_banner.append (portal_icon);

        portal_label = new Gtk.Label ("Captive portal detected. Sign-in may be required.");
        portal_label.hexpand = true;
        portal_label.xalign = 0.0f;
        portal_label.wrap = true;
        portal_banner.append (portal_label);

        portal_refresh_button = new Gtk.Button.with_label ("Refresh");
        portal_refresh_button.add_css_class ("flat");
        portal_refresh_button.clicked.connect (() => manager.scan.begin ());
        portal_banner.append (portal_refresh_button);

        content_shell.append (portal_banner);

        hero_container = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        hero_container.hexpand = true;
        content_shell.append (hero_container);

        search_empty_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        search_empty_box.hexpand = true;
        search_empty_box.valign = Gtk.Align.CENTER;
        search_empty_box.halign = Gtk.Align.CENTER;
        search_empty_box.add_css_class ("search-empty");

        search_empty_title = new Gtk.Label ("No available networks match your search");
        search_empty_title.add_css_class ("state-title");
        search_empty_box.append (search_empty_title);

        search_empty_subtitle = new Gtk.Label ("Clear the search field to show all available networks again.");
        search_empty_subtitle.add_css_class ("dim-label");
        search_empty_box.append (search_empty_subtitle);

        content_shell.append (search_empty_box);

        network_list = new Gtk.ListBox ();
        network_list.hexpand = true;
        network_list.selection_mode = Gtk.SelectionMode.NONE;
        network_list.show_separators = true;
        network_list.activate_on_single_click = true;
        network_list.row_activated.connect (on_row_activated);
        network_list.add_css_class ("network-listbox");
        network_list.add_css_class ("network-panel");

        content_shell.append (network_list);
        scrolled.set_child (content_shell);
        return scrolled;
    }

    /**
     * Bind ViewModel state changes to UI updates.
     *
     * Connects notify signals on the WifiViewModel to the
     * update_state and update_status_strip methods.
     */
    private void bind_state () {
        manager.notify["scanning"].connect (update_state);
        manager.notify["has-networks"].connect (update_state);
        manager.notify["search-active"].connect (update_state);
        manager.notify["has-visible-networks"].connect (update_state);
        manager.notify["has-connected-network"].connect (update_state);
        manager.notify["captive-portal"].connect (update_status_strip);
        manager.notify["connectivity-text"].connect (update_status_strip);
        manager.notify["scan-freshness"].connect (update_status_strip);
        manager.items.items_changed.connect (() => update_state ());
        manager.error.connect ((message) => {
            error_subtitle.label = message;
            stack.visible_child_name = "error";
        });
        update_state ();
    }

    /**
     * Update the visible stack page and refresh the network list.
     *
     * Decides which of loading/empty/error/results pages to show
     * based on the current ViewModel state.
     */
    private void update_state () {
        Logger.debug ("MainWindow", "Updating state: scanning=%s, has_networks=%s", manager.scanning.to_string (), manager.has_networks.to_string ());
        refresh_button.sensitive = !manager.scanning;
        spinner.spinning = manager.scanning;
        spinner.visible = manager.scanning;

        if (manager.scanning && !manager.has_networks) {
            stack.visible_child_name = "loading";
        } else if (manager.has_networks || manager.search_active) {
            stack.visible_child_name = "results";
        } else {
            stack.visible_child_name = "empty";
        }

        update_status_strip ();
        render_networks ();
    }

    /**
     * Update the status labels and portal banner.
     *
     * Reads scan_freshness, connectivity_text, and captive_portal
     * from the ViewModel.
     */
    private void update_status_strip () {
        if (scan_status_label == null || connectivity_status_label == null || portal_banner == null) {
            return;
        }

        scan_status_label.label = manager.scan_freshness;
        connectivity_status_label.label = manager.connectivity_text;
        portal_banner.visible = manager.captive_portal;
    }

    /**
     * Debounce search input and apply the filter after a short delay.
     *
     * Cancels any pending debounce timer and starts a new 120 ms
     * timeout before calling set_search_text.
     */
    private void queue_search_update () {
        Logger.debug ("MainWindow", "Queueing search update");
        if (search_debounce_id != 0) {
            Source.remove (search_debounce_id);
            search_debounce_id = 0;
        }

        search_debounce_id = Timeout.add (120, () => {
            search_debounce_id = 0;
            manager.set_search_text (search_entry.text);
            return Source.REMOVE;
        });
    }

    /**
     * Render the connected hero row and available network list.
     *
     * Iterates over the ViewModel's items list and populates the
     * hero container and network list box accordingly.
     */
    private void render_networks () {
        if (_rendering) {
            _render_needed = true;
            return;
        }

        Logger.debug ("MainWindow", "Rendering networks");
        if (hero_container == null || network_list == null) {
            return;
        }

        _rendering = true;
        _render_needed = false;

        clear_container (hero_container);
        network_list.remove_all ();

        bool show_search_empty = manager.search_active && !manager.has_visible_networks;
        search_empty_box.visible = show_search_empty;
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

        hero_container.visible = hero_container.get_first_child () != null;

        _rendering = false;
        if (_render_needed) {
            _render_needed = false;
            render_networks ();
        }
    }

    /**
     * Remove all children from a box container.
     *
     * @param box  The container to clear.
     */
    private void clear_container (Gtk.Box box) {
        var child = box.get_first_child ();
        while (child != null) {
            var next = child.get_next_sibling ();
            box.remove (child);
            child = next;
        }
    }

    /**
     * Build a section header row for network list categories.
     *
     * @param title  The section title text.
     * @return A non-activatable Gtk.ListBoxRow label.
     */
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

    /**
     * Build a network list row widget for non-hero (non-connected) networks.
     *
     * @param item  The WifiListItem to render.
     * @param hero  Whether to style as a hero row.
     * @return A Gtk.ListBoxRow containing a WifiNetworkRow.
     */
    private Gtk.Widget build_network_row (WifiListItem item, bool hero) {
        var row = new Gtk.ListBoxRow ();
        row.selectable = false;
        row.activatable = true;

        var widget = new WifiNetworkRow ();
        widget.set_item (item);
        widget.set_hero (hero);
        widget.request_actions.connect ((network) => show_network_actions (network));
        row.set_child (widget);
        return row;
    }

    /**
     * Build the hero row for the currently connected network.
     *
     * @param item  The WifiListItem for the connected network.
     * @return A WifiNetworkRow styled as a hero element.
     */
    private Gtk.Widget build_hero_row (WifiListItem item) {
        var widget = new WifiNetworkRow ();
        widget.set_item (item);
        widget.set_hero (true);
        widget.request_actions.connect ((network) => show_network_actions (network));

        var gesture = new Gtk.GestureClick ();
        gesture.released.connect ((n_press, x, y) => {
            activate_network (item.network);
        });
        widget.add_controller (gesture);

        return widget;
    }

    /**
     * Handle click on a network list row.
     *
     * Extracts the WifiNetwork from the activated row and
     * delegates to activate_network.
     *
     * @param row  The activated Gtk.ListBoxRow.
     */
    private void on_row_activated (Gtk.ListBoxRow row) {
        Logger.info ("MainWindow", "Network row activated");
        var child = row.get_child ();
        var network_row = child as WifiNetworkRow;
        if (network_row == null || network_row.item_network == null) {
            return;
        }

        activate_network (network_row.item_network);
    }

    /**
     * Activate a network: show info, connect directly, or show password dialog.
     *
     * Decides the action based on whether the network is connected,
     * saved, secured, or open.
     *
     * @param network  The network to act on.  If null, a warning is logged.
     */
    private void activate_network (WifiNetwork? network) {
        if (network == null) {
            Logger.warn ("MainWindow", "activate_network called with null network");
            return;
        }
        Logger.info ("MainWindow", "Activating network: %s", network.ssid);

        if (network.is_connected || network.is_saved) {
            show_network_actions (network);
        } else if (!network.secured) {
            connect_network.begin (network);
        } else {
            show_connect_dialog (network);
        }
    }

    /**
     * Initiate connection to a network via the ViewModel.
     *
     * Async method, does not block the UI thread.  On failure the
     * error page is shown.
     *
     * @param network   The network to connect to.
     * @param password  Optional WPA password or 802.1X password.
     * @param username  Optional 802.1X username.
     */
    private async void connect_network (WifiNetwork network, string? password = null, string? username = null) {
        try {
            Logger.info ("MainWindow", "Connecting to network: %s", network.ssid);
            yield manager.connect_network (network, password, username);
        } catch (GLib.Error e) {
            Logger.warn ("MainWindow", "Failed to connect to '%s': %s", network.ssid, e.message);
            error_subtitle.label = e.message;
            stack.visible_child_name = "error";
        }
    }

    /**
     * Show a dialog prompting for password (and optionally username) to connect.
     *
     * For enterprise networks a username field is also displayed.
     *
     * @param network  The secured network to connect to.
     */
    private void show_connect_dialog (WifiNetwork network) {
        Logger.info ("MainWindow", "Showing connect dialog for: %s", network.ssid);
        var dialog = new Gtk.Window ();
        dialog.title = network.ssid;
        dialog.transient_for = this;
        dialog.modal = true;
        dialog.resizable = false;
        dialog.default_width = 400;
        dialog.add_css_class ("dialog-window");
        if (this.has_css_class ("dark-mode")) {
            dialog.add_css_class ("dark-mode");
        }
        build_dialog_titlebar (dialog, "Connect to " + network.ssid);

        var body = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        body.add_css_class ("dialog-body");
        dialog.set_child (body);

        Gtk.Entry? username_entry = null;
        if (network.enterprise) {
            username_entry = new Gtk.Entry ();
            username_entry.placeholder_text = "Enter username";
            username_entry.add_css_class ("dialog-input");
            body.append (build_dialog_field ("Username", username_entry));
        }

        var password_entry = new Gtk.PasswordEntry ();
        password_entry.placeholder_text = "Enter password";
        password_entry.show_peek_icon = true;
        password_entry.add_css_class ("dialog-input");
        body.append (build_dialog_field ("Password", password_entry));

        var error_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        error_box.add_css_class ("dialog-error");
        error_box.visible = false;

        var error_icon = new Gtk.Image.from_icon_name ("dialog-warning-symbolic");
        error_icon.pixel_size = 16;
        error_box.append (error_icon);

        var error_label = new Gtk.Label ("");
        error_label.xalign = 0.0f;
        error_label.hexpand = true;
        error_label.wrap = true;
        error_box.append (error_label);
        body.append (error_box);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        actions.add_css_class ("dialog-actions");
        actions.halign = Gtk.Align.END;

        var cancel = new Gtk.Button.with_label ("Cancel");
        cancel.add_css_class ("dialog-cancel");
        var connect = new Gtk.Button.with_label ("Connect");
        connect.add_css_class ("suggested-action");
        actions.append (cancel);
        actions.append (connect);
        body.append (actions);

        cancel.clicked.connect (() => dialog.close ());

        connect.clicked.connect (() => {
            connect.sensitive = false;
            error_box.visible = false;
            var username = username_entry != null ? username_entry.text : null;
            manager.connect_network.begin (network, password_entry.text, username, (obj, res) => {
                if (!_connect_dialog_active) {
                    return;
                }
                try {
                    manager.connect_network.end (res);
                    dialog.close ();
                } catch (GLib.Error e) {
                    error_label.label = e.message;
                    error_box.visible = true;
                    connect.sensitive = true;
                }
            });
        });

        password_entry.activate.connect (() => {
            connect.sensitive = false;
            error_box.visible = false;
            var username = username_entry != null ? username_entry.text : null;
            manager.connect_network.begin (network, password_entry.text, username, (obj, res) => {
                if (!_connect_dialog_active) {
                    return;
                }
                try {
                    manager.connect_network.end (res);
                    dialog.close ();
                } catch (GLib.Error e) {
                    error_label.label = e.message;
                    error_box.visible = true;
                    connect.sensitive = true;
                }
            });
        });

        _connect_dialog_active = true;
        dialog.close_request.connect (() => {
            _connect_dialog_active = false;
            manager.cancel_manual_connect ();
            dialog.destroy ();
            return true;
        });

        dialog.present ();
        password_entry.grab_focus ();
    }

    /**
     * Show a dialog with network details and action buttons.
     *
     * Displays SSID, security, band, signal, speed, IP, gateway,
     * DNS, and scan freshness.  Offers Connect/Disconnect/Forget
     * actions depending on the network state.
     *
     * @param network  The network to show details for.
     */
    private void show_network_actions (WifiNetwork network) {
        Logger.info ("MainWindow", "Showing network actions for: %s", network.ssid);
        var dialog = new Gtk.Window ();
        dialog.title = network.ssid;
        dialog.transient_for = this;
        dialog.modal = true;
        dialog.resizable = false;
        dialog.default_width = 400;
        dialog.add_css_class ("dialog-window");
        if (this.has_css_class ("dark-mode")) {
            dialog.add_css_class ("dark-mode");
        }
        build_dialog_titlebar (dialog, "Network");

        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.add_css_class ("dialog-body");
        dialog.set_child (box);

        var heading = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        var title = new Gtk.Label (network.ssid);
        title.xalign = 0.0f;
        title.ellipsize = Pango.EllipsizeMode.END;
        title.add_css_class ("dialog-network-name");
        heading.append (title);

        var detail = new Gtk.Label (network.detail_summary);
        detail.xalign = 0.0f;
        detail.add_css_class ("dialog-network-meta");
        detail.wrap = true;
        heading.append (detail);
        box.append (heading);

        var expander = new Gtk.Expander ("Network details");
        expander.expanded = true;
        expander.add_css_class ("details-expander");
        box.append (expander);

        var grid = new Gtk.Grid ();
        grid.column_spacing = 18;
        grid.row_spacing = 8;
        grid.add_css_class ("details-grid");
        expander.set_child (grid);

        var row = 0;
        add_detail_row (grid, row++, "Security", network.security_badge_text);
        add_detail_row (grid, row++, "Band", network.band);
        add_detail_row (grid, row++, "Signal", network.signal_dbm_text);
        add_detail_row (grid, row++, "Speed", network.bitrate_detail);
        add_detail_row (grid, row++, "Health", network.health_text);
        add_detail_row (grid, row++, "IP address", network.ip_address);
        add_detail_row (grid, row++, "Gateway", network.gateway);
        add_detail_row (grid, row++, "DNS", network.dns_summary);
        add_detail_row (grid, row++, "Scan freshness", network.scan_age_text);
        add_detail_row (grid, row++, "Warnings", network.warning_text);

        var actions = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
        actions.add_css_class ("dialog-actions");
        actions.halign = Gtk.Align.END;
        var close = new Gtk.Button.with_label ("Close");
        close.add_css_class ("dialog-cancel");
        actions.append (close);

        if (network.is_connected) {
            var reconnect = new Gtk.Button.with_label ("Reconnect");
            reconnect.clicked.connect (() => {
                manager.reconnect_network.begin (network);
                dialog.close ();
            });
            actions.append (reconnect);

            var disconnect = new Gtk.Button.with_label ("Disconnect");
            disconnect.add_css_class ("destructive-action");
            disconnect.clicked.connect (() => {
                manager.record_disconnect (network.ssid);
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

        close.clicked.connect (() => dialog.destroy ());
        box.append (actions);
        dialog.close_request.connect (() => {
            dialog.destroy ();
            return true;
        });
        dialog.present ();
    }

    /**
     * Build a custom header bar for dialogs with a close button.
     *
     * @param dialog  The window to attach the titlebar to.
     * @param title   The header title text.
     */
    private void build_dialog_titlebar (Gtk.Window dialog, string title) {
        var header = new Gtk.HeaderBar ();
        header.show_title_buttons = false;
        header.add_css_class ("dialog-headerbar");

        var title_label = new Gtk.Label (title);
        title_label.add_css_class ("dialog-header-title");
        header.title_widget = title_label;

        var close_icon = new Gtk.Image.from_icon_name ("window-close-symbolic");
        close_icon.tooltip_text = "Close";
        close_icon.add_css_class ("dialog-close");
        close_icon.halign = Gtk.Align.END;
        close_icon.valign = Gtk.Align.CENTER;

        var click = new Gtk.GestureClick ();
        click.released.connect (() => dialog.close ());
        close_icon.add_controller (click);

        header.pack_end (close_icon);

        dialog.set_titlebar (header);
    }

    /**
     * Build a labelled input field for dialogs.
     *
     * @param label_text  The field label text.
     * @param field       The input widget.
     * @return A vertical Gtk.Box containing the label and field.
     */
    private Gtk.Box build_dialog_field (string label_text, Gtk.Widget field) {
        var container = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);

        var label = new Gtk.Label (label_text);
        label.xalign = 0.0f;
        label.add_css_class ("dialog-field-label");
        container.append (label);
        container.append (field);

        return container;
    }

    /**
     * Add a key-value row to the network details grid.
     *
     * @param grid   The Gtk.Grid to attach to.
     * @param row    The grid row index.
     * @param key    The field name label.
     * @param value  The field value label (shows em dash if empty).
     */
    private void add_detail_row (Gtk.Grid grid, int row, string key, string value) {
        var key_label = new Gtk.Label (key);
        key_label.xalign = 0.0f;
        key_label.add_css_class ("detail-key");

        var value_label = new Gtk.Label (value.length > 0 ? value : "\u2014");
        value_label.xalign = 0.0f;
        value_label.wrap = true;
        value_label.add_css_class ("detail-value");

        grid.attach (key_label, 0, row, 1, 1);
        grid.attach (value_label, 1, row, 1, 1);
    }
}
