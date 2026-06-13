using Gtk;

/**
 * Application entry point.
 *
 * Creates the Application instance and hands control to the
 * GLib main loop.
 *
 * @param args  Command-line arguments.
 * @return Exit code from Gtk.Application.run().
 */
public static int main (string[] args) {
    var application = new Application ();
    return application.run (args);
}
