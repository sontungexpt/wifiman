using Gtk;
using GLib;

public class Application : Gtk.Application {
    private const GLib.ActionEntry[] action_entries = {
        { "toggle", on_toggle_action }
    };

    public Application () {
        GLib.Object (
            application_id: Config.APPLICATION_ID,
            flags: GLib.ApplicationFlags.HANDLES_COMMAND_LINE
        );
        add_main_option ("version", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Show version information", null);
        add_main_option ("toggle", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Toggle window visibility", null);
        add_action_entries (action_entries, this);
    }

    private void on_toggle_action () {
        var window = get_active_window () as MainWindow;
        if (window != null) {
            window.toggle_visibility ();
        }
    }

    protected override void activate () {
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

        activate ();
        return 0;
    }

    private void apply_class_to_windows (bool dark) {
        foreach (var w in get_windows ()) {
            if (dark) w.add_css_class ("dark-mode");
            else w.remove_css_class ("dark-mode");
        }
    }

    public void apply_color_scheme (string scheme) {
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

    private void apply_saved_color_scheme () {
        apply_color_scheme (load_color_scheme ());
    }

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

    public void save_color_scheme (string scheme) {
        var config_dir = Path.build_filename (Environment.get_user_config_dir (), "wifiman");
        DirUtils.create_with_parents (config_dir, 0755);
        var config_file = Path.build_filename (config_dir, "settings.ini");
        try {
            var keyfile = new GLib.KeyFile ();
            keyfile.set_string ("Settings", "color-scheme", scheme);
            keyfile.save_to_file (config_file);
        } catch (GLib.Error e) {
            warning ("Failed to save color scheme: %s", e.message);
        }
    }
}

// Configuration constants
namespace Config {
    public const string APPLICATION_ID = "io.github.sontungexpt.wifiman";
    public const string VERSION = "0.1.0";
}
