namespace Logger {
    private static FileStream? file_stream = null;
    private static string? file_path = null;
    private static uint max_size = 0;
    private static bool enabled = false;
    private static bool debug_on = false;

    private static string timestamp () {
        var now = new DateTime.now_local ();
        return now.format ("%Y-%m-%d %H:%M:%S");
    }

    private static void rotate () {
        if (file_path == null) return;
        if (file_stream != null) {
            file_stream.flush ();
            file_stream = null;
        }
        var old = file_path + ".old";
        FileUtils.remove (old);
        FileUtils.rename (file_path, old);
        file_stream = FileStream.open (file_path, "a");
    }

    private static void write_file (string level, string module, string msg) {
        if (file_stream == null || file_path == null) return;
        var line = "[%s] [%s] [%s] %s\n".printf (timestamp (), level, module, msg);
        file_stream.printf (line);
        if (max_size > 0 && file_stream.tell () >= (long) max_size) {
            rotate ();
        }
    }

    /**
     * Flush buffered data and release the file handle.
     *
     * Optional — on normal exit the C runtime closes all
     * FILE* handles automatically.  Call explicitly only
     * when you need guaranteed flush mid-process (e.g.
     * before fork or exec).
     */
    public static void shutdown () {
        if (file_stream != null) {
            write_file ("INFO", "Logger", "Session ended");
            file_stream.flush ();
            file_stream = null;
        }
        enabled = false;
        file_path = null;
    }

    /**
     * Initialise the logging system.
     *
     * When @enable_file is true, logs are written to
     * ~/.local/state/wifiman/wifiman.log in addition to
     * journald/stderr.  Old logs are rotated once the file
     * exceeds @log_max_size bytes.
     *
     * @enable_file:
     *   Whether to enable persistent file logging.
     *
     * @log_max_size:
     *   Maximum file size in bytes before rotation.
     *   Default: 1 MB.
     */
    public static void init (bool enable_file = false, uint log_max_size = 1024 * 1024) {
        enabled = true;
        debug_on = enable_file;
        if (!enable_file) return;
        var dir = Path.build_filename (Environment.get_user_state_dir (), "wifiman");
        DirUtils.create_with_parents (dir, 0755);
        file_path = Path.build_filename (dir, "wifiman.log");
        file_stream = FileStream.open (file_path, "a");
        max_size = log_max_size;
        if (file_stream != null) {
            file_stream.printf ("\n=== Session started %s ===\n", timestamp ());
            file_stream.flush ();
        }
    }

    /**
     * Log a debug message.
     *
     * @module:
     *   Source module or class name (e.g. "MainWindow").
     *
     * @format:
     *   Printf-style format string.
     *
     * @...:
     *   Format arguments.
     */
    public static void debug (string module, string format, ...) {
        if (!debug_on) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        GLib.debug ("[%s] %s", module, msg);
        write_file ("DEBUG", module, msg);
    }

    /**
     * Log an informational message.
     *
     * @module:
     *   Source module or class name.
     *
     * @format:
     *   Printf-style format string.
     *
     * @...:
     *   Format arguments.
     */
    public static void info (string module, string format, ...) {
        if (!debug_on) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        GLib.message ("[%s] %s", module, msg);
        write_file ("INFO", module, msg);
    }

    /**
     * Log a warning message.
     *
     * Always written to journald/stderr and to the log file
     * when file logging is enabled.
     *
     * @module:
     *   Source module or class name.
     *
     * @format:
     *   Printf-style format string.
     *
     * @...:
     *   Format arguments.
     */
    public static void warn (string module, string format, ...) {
        var args = va_list ();
        var msg = format.vprintf (args);
        GLib.warning ("[%s] %s", module, msg);
        write_file ("WARN", module, msg);
    }

    /**
     * Log an error message.
     *
     * Always written to journald/stderr and to the log file
     * when file logging is enabled.
     *
     * @module:
     *   Source module or class name.
     *
     * @format:
     *   Printf-style format string.
     *
     * @...:
     *   Format arguments.
     */
    public static void error (string module, string format, ...) {
        var args = va_list ();
        var msg = format.vprintf (args);
        GLib.critical ("[%s] %s", module, msg);
        write_file ("ERROR", module, msg);
    }
}
