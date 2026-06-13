namespace Logger {
    private enum Level {
        DEBUG,
        INFO,
        WARN,
        ERROR;

        public string to_prefix () {
            switch (this) {
                case DEBUG: return "DEBUG";
                case INFO:  return "INFO";
                case WARN:  return "WARN";
                case ERROR: return "ERROR";
                default:    return "????";
            }
        }
    }

    [Compact]
    private class LogEntry {
        public Level level;
        public string module;
        public string message;

        public LogEntry (Level level, string module, string message) {
            this.level = level;
            this.module = module;
            this.message = message;
        }
    }

    private static AsyncQueue<LogEntry>? _queue = null;
    private static Thread<void*>? _writer = null;

    private static bool _debug_on = false;

    private static FileStream? _stream = null;
    private static string? _path = null;
    private static uint _max_size = 0;

    private static int _stopped = 0;

    private const int FLUSH_INTERVAL_US = 100000;

    private static string timestamp () {
        var now = new DateTime.now_local ();
        return now.format ("%Y-%m-%d %H:%M:%S");
    }

    private static void rotate () {
        if (_path == null) return;
        if (_stream != null) {
            _stream.flush ();
            _stream = null;
        }
        var old = _path + ".old";
        FileUtils.remove (old);
        FileUtils.rename (_path, old);
        _stream = FileStream.open (_path, "a");
    }

    private static void write_entry (LogEntry entry) {
        if (_stream == null) return;
        var line = "[%s] [%s] [%s] %s\n".printf (
            timestamp (), entry.level.to_prefix (), entry.module, entry.message
        );
        _stream.printf (line);
    }

    private static void flush () {
        if (_stream != null) {
            _stream.flush ();
        }
    }

    private static void* writer_func () {
        var queue = _queue;
        while (true) {
            var entry = queue.timeout_pop (FLUSH_INTERVAL_US);

            if (entry != null) {
                write_entry (entry);
                while ((entry = queue.try_pop ()) != null) {
                    write_entry (entry);
                }
                if (_max_size > 0 && _stream != null && _stream.tell () >= (long) _max_size) {
                    rotate ();
                }
                flush ();
            } else {
                flush ();
                if (AtomicInt.get (ref _stopped) != 0) {
                    while ((entry = queue.try_pop ()) != null) {
                        write_entry (entry);
                    }
                    if (_max_size > 0 && _stream != null && _stream.tell () >= (long) _max_size) {
                        rotate ();
                    }
                    flush ();
                    if (_stream != null) {
                        _stream = null;
                    }
                    break;
                }
            }
        }
        return null;
    }

    private static void log (Level level, string module, string format, va_list args) {
        var msg = format.vprintf (args);

        switch (level) {
            case DEBUG:
                GLib.debug ("[%s] %s", module, msg);
                break;
            case INFO:
                GLib.message ("[%s] %s", module, msg);
                break;
            case WARN:
                GLib.warning ("[%s] %s", module, msg);
                break;
            case ERROR:
                GLib.critical ("[%s] %s", module, msg);
                break;
        }

        if (_queue != null) {
            _queue.push (new LogEntry (level, module, msg));
        }
    }

    /**
     * Initialise the logging system.
     *
     * When @enable_file is true, logs are written to
     * ~/.local/state/wifiman/wifiman.log in addition to
     * journald/stderr.  Old logs are rotated once the file
     * exceeds @log_max_size bytes.
     *
     * A dedicated writer thread consumes an in-memory queue
     * so that callers never block on file I/O.
     *
     * @enable_file:
     *   Whether to enable persistent file logging.
     *
     * @log_max_size:
     *   Maximum file size in bytes before rotation.
     *   Default: 1 MB.
     */
    public static void init (bool enable_file = false, uint log_max_size = 1024 * 1024) {
        _debug_on = enable_file;

        if (!enable_file) return;

        var dir = Path.build_filename (Environment.get_user_state_dir (), "wifiman");
        DirUtils.create_with_parents (dir, 0755);
        _path = Path.build_filename (dir, "wifiman.log");
        _max_size = log_max_size;

        _queue = new AsyncQueue<LogEntry> ();

        try {
            _writer = new Thread<void*> ("wifiman-log", writer_func);
            _queue.push (new LogEntry (INFO, "Logger", "=== Session started %s ===".printf (timestamp ())));
        } catch (ThreadError e) {
            GLib.critical ("Failed to start logger thread: %s", e.message);
            _queue = null;
            _path = null;
        }
    }

    /**
     * Flush buffered data and release the file handle.
     *
     * Signals the writer thread to drain the queue and exit.
     * Blocks until all queued entries have been written and
     * the file handle is closed.
     */
    public static void shutdown () {
        _debug_on = false;

        if (_queue != null) {
            _queue.push (new LogEntry (INFO, "Logger", "Session ended"));
        }

        AtomicInt.set (ref _stopped, 1);

        if (_writer != null) {
            _writer.join ();
            _writer = null;
        }

        _path = null;
        _max_size = 0;
        _queue = null;
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
        if (!_debug_on) return;
        var args = va_list ();
        log (DEBUG, module, format, args);
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
        if (!_debug_on) return;
        var args = va_list ();
        log (INFO, module, format, args);
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
        log (WARN, module, format, args);
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
        log (ERROR, module, format, args);
    }
}
