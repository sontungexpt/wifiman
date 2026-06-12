using Gtk;
using GLib;

/**
 * Main application class for the Wi-Fi manager.
 *
 * Handles command-line argument parsing, window lifecycle,
 * and color-scheme management.
 */
public class Application : Gtk.Application {
    private const GLib.ActionEntry[] action_entries = {
        { "toggle", on_toggle_action }
    };

    /**
     * Whether debug logging is enabled.
     *
     * Set via the --debug command-line flag.  When true, verbose
     * log output is written to ~/.local/state/wifiman/wifiman.log.
     */
    public bool debug_mode { get; private set; default = false; }

    /**
     * Initialise the application with command-line options and actions.
     *
     * Registers --version, --toggle, and --debug flags.
     */
    public Application () {
        GLib.Object (
            application_id: Config.APPLICATION_ID,
            flags: GLib.ApplicationFlags.HANDLES_COMMAND_LINE
        );
        add_main_option ("version", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Show version information", null);
        add_main_option ("toggle", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Toggle window visibility", null);
        add_main_option ("debug", 'd', GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Enable debug logging to ~/.config/wifiman/debug.log", null);
        add_action_entries (action_entries, this);
    }

    /**
     * Handle the toggle action from a remote instance.
     *
     * Triggered when a second process sends --toggle to the
     * already-running primary instance.
     */
    private void on_toggle_action () {
        Logger.info ("Application", "Toggle action received");
        var window = get_active_window () as MainWindow;
        if (window != null) {
            window.toggle_visibility ();
        }
    }

    /**
     * Activate the application window, creating it if needed.
     *
     * Called when the application is started or when a remote
     * activation request arrives.  Applies the saved color scheme
     * and presents the window.
     */
    protected override void activate () {
        Logger.info ("Application", "Activating application window");
        var window = get_active_window ();
        if (window == null) {
            window = new MainWindow (this);
        }
        apply_saved_color_scheme ();
        if (window is MainWindow) {
            ((MainWindow) window).sync_popover_class ();
        }
        window.present ();
    }

    /**
     * Parse command-line arguments and start the application.
     *
     * Handles --version (prints version and exits), --toggle
     * (forwards to the primary instance), and --debug (enables
     * file logging).
     *
     * @param command_line  The parsed command-line object.
     * @return 0 on success, non-zero on error.
     */
    protected override int command_line (GLib.ApplicationCommandLine command_line) {
        var options = command_line.get_options_dict ();

        if (options.contains ("version")) {
            GLib.print ("%s %s\n", Config.APPLICATION_ID, Config.VERSION);
            return 0;
        }

        if (options.contains ("toggle") && command_line.get_is_remote ()) {
            activate_action ("toggle", null);
            return 0;
        }

        if (options.contains ("debug")) {
            debug_mode = true;
        }

        Logger.init (debug_mode);
        Logger.info ("Application", "Started (debug=%s)", debug_mode.to_string ());

        activate ();
        return 0;
    }

    /**
     * Apply dark or light mode CSS class to all windows.
     *
     * @param dark  Whether to apply the dark-mode class.
     */
    private void apply_class_to_windows (bool dark) {
        Logger.debug ("Application", "Applying class to windows: dark=%s", dark.to_string ());
        foreach (var w in get_windows ()) {
            if (dark) w.add_css_class ("dark-mode");
            else w.remove_css_class ("dark-mode");
        }
    }

    /**
     * Apply the given color-scheme setting.
     *
     * Supports "dark", "light", and "system".  The "system" value
     * reads the GNOME preference via GSettings.
     *
     * @param scheme  One of "dark", "light", or "system".
     */
    public void apply_color_scheme (string scheme) {
        Logger.info ("Application", "Applying color scheme: %s", scheme);
        bool is_dark = false;
        switch (scheme) {
            case "dark":
                is_dark = true;
                break;
            case "light":
                is_dark = false;
                break;
            default:
                try {
                    var gnome_settings = new GLib.Settings ("org.gnome.desktop.interface");
                    var color_scheme = gnome_settings.get_string ("color-scheme");
                    is_dark = color_scheme == "prefer-dark";
                } catch (GLib.Error e) {
                    is_dark = false;
                }
                break;
        }
        apply_class_to_windows (is_dark);
    }

    /**
     * Load and apply the saved color-scheme setting.
     *
     * Reads the saved scheme from settings.ini and applies it.
     */
    private void apply_saved_color_scheme () {
        apply_color_scheme (load_color_scheme ());
    }

    /**
     * Load the color-scheme setting from settings.ini.
     *
     * Falls back to "system" if the file is missing or unreadable.
     *
     * @return "dark", "light", or "system".
     */
    public string load_color_scheme () {
        var config_file = Path.build_filename (
            Environment.get_user_config_dir (), "wifiman", "settings.ini"
        );
        try {
            var keyfile = new GLib.KeyFile ();
            keyfile.load_from_file (config_file, GLib.KeyFileFlags.NONE);
            return keyfile.get_string ("Settings", "color-scheme");
        } catch (GLib.Error e) {
            return "system";
        }
    }

    /**
     * Save the color-scheme setting to settings.ini.
     *
     * Creates the config directory if it does not exist.
     *
     * @param scheme  One of "dark", "light", or "system".
     */
    public void save_color_scheme (string scheme) {
        var config_dir = Path.build_filename (Environment.get_user_config_dir (), "wifiman");
        DirUtils.create_with_parents (config_dir, 0755);
        var config_file = Path.build_filename (config_dir, "settings.ini");
        try {
            var keyfile = new GLib.KeyFile ();
            keyfile.set_string ("Settings", "color-scheme", scheme);
            keyfile.save_to_file (config_file);
        } catch (GLib.Error e) {
            Logger.warn ("Application", "Failed to save color scheme to settings.ini: %s", e.message);
        }
    }
}

// Configuration constants
namespace Config {
    public const string APPLICATION_ID = "io.github.sontungexpt.wifiman";
    public const string VERSION = "0.1.0";
}
