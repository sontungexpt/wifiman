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
}

// Configuration constants
namespace Config {
    public const string APPLICATION_ID = "io.github.sontungexpt.wifiman";
    public const string VERSION = "0.1.0";
}
