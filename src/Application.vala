using Gtk;
using GLib;

public class Application : Gtk.Application {

    public Application () {
        GLib.Object (
            application_id: Config.APPLICATION_ID,
            flags: GLib.ApplicationFlags.HANDLES_COMMAND_LINE
        );
        add_main_option ("version", 0, GLib.OptionFlags.NONE, GLib.OptionArg.NONE, "Show version information", null);
    }

    protected override void activate () {
        var window = get_active_window ();
        if (window == null) {
            window = new MainWindow (this);
        }
        window.present ();
    }

    protected override void open (GLib.File[] files, string hint) {
        // Handle opening files, if applicable for this application
        base.open (files, hint);
    }

    protected override int command_line (GLib.ApplicationCommandLine command_line) {
        var options = command_line.get_options_dict ();
        if (options.contains ("version")) {
            GLib.print ("%s %s
", Config.APPLICATION_ID, Config.VERSION);
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
