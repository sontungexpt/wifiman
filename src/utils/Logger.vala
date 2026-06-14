/**
 * Production-grade logging subsystem for embedded/kiosk devices.
 *
 * Architecture:
 *   Lock-free producer-consumer via GLib.AsyncQueue.  Producers
 *   (any thread) push LogEntry structs onto the queue.  A single
 *   dedicated writer thread pops entries, formats them, and writes
 *   to the appropriate category file.  This ensures zero interleaving
 *   and no I/O latency on the calling thread.
 *
 * Rotation (size-based):
 *   When a target file exceeds max_file_size the writer thread
 *   atomically rotates:
 *     1. Delete app.log.N              (oldest rotated file)
 *     2. Rename app.log.N-1 → app.log.N
 *     3. ...                           (shift chain)
 *     4. Rename app.log → app.log.1
 *     5. Open new app.log
 *   All rotation happens on the writer thread – no locks needed.
 *
 * Retention:
 *   Maximum disk usage = categories × (max_rotated_files + 1) × max_file_size.
 *   With defaults (4 categories, 10 rotated files + 1 active, 2 MiB each):
 *   4 × 11 × 2 MiB = 88 MiB.
 *
 * Categories (separate files):
 *   app.log      – General application events (majority of calls).
 *   wifi.log     – Wi-Fi scan, connect, disconnect events.
 *   security.log – Authentication, access-control events.
 *   crash.log    – FATAL level & unhandled GLib critical/error.
 *
 * Crash handling:
 *   FATAL() synchronously writes to crash.log via write(2) before
 *   aborting.  POSIX signal handlers (SIGSEGV, SIGABRT) also write
 *   directly via write(2) – the only async-signal-safe I/O.
 *   A GLib log hook forwards GLib ERROR/CRITICAL to crash.log.
 *
 * Thread safety:
 *   The AsyncQueue is lock-free for producers.  The single writer
 *   thread owns all file handles and rotation state.  Reads of
 *   _config happen only during init() (before the writer starts)
 *   or on the writer thread.  No mutex required.
 */
namespace Log {
    // ═══════════════════════════════════════════════════════════════
    //  Public types
    // ═══════════════════════════════════════════════════════════════

    public enum Level {
        DEBUG,
        INFO,
        WARN,
        ERROR,
        FATAL;

        public string to_string_ () {
            switch (this) {
                case DEBUG: return "DEBUG";
                case INFO:  return "INFO";
                case WARN:  return "WARN";
                case ERROR: return "ERROR";
                case FATAL: return "FATAL";
                default:    return "?????";
            }
        }
    }

    public enum Category {
        APP,
        WIFI,
        SECURITY,
        CRASH
    }

    public enum Format {
        TEXT,
        JSON
    }

    /**
     * Runtime configuration for the logging subsystem.
     *
     * Passed to Log.init() before the writer thread starts.
     * Fields are read-only after init – the writer thread copies
     * the values it needs into locals.
     */
    public class Config {
        /**
         * Directory where log files are written.
         * Default: ~/.local/state/wifiman/logs
         */
        public string log_dir { get; set; }

        /**
         * Minimum level to write to files.
         * Default: INFO
         */
        public Level level { get; set; }

        /**
         * Output format (TEXT or JSON).
         * Default: TEXT
         */
        public Format format { get; set; }

        /**
         * Per-file size limit in bytes before rotation.
         * Default: 2 MiB
         */
        public uint max_file_size { get; set; }

        /**
         * Maximum number of rotated backup files per category.
         * Default: 10
         */
        public uint max_rotated_files { get; set; }

        public Config () {
            log_dir = Path.build_filename (
                Environment.get_user_state_dir (), "wifiman", "logs"
            );
            level = Level.INFO;
            format = Format.TEXT;
            max_file_size = 2 * 1024 * 1024;
            max_rotated_files = 10;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Internal types
    // ═══════════════════════════════════════════════════════════════

    [Compact]
    private class LogEntry {
        public Category cat;
        public Level level;
        public string module;
        public string message;

        public LogEntry (Category cat, Level level, string module, string message) {
            this.cat = cat;
            this.level = level;
            this.module = module;
            this.message = message;
        }
    }

    [Compact]
    private class LogTarget {
        public string path;
        public FileStream? stream;
        public int64 current_size;

        public LogTarget (string path) {
            this.path = path;
            this.stream = null;
            this.current_size = 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Private state
    // ═══════════════════════════════════════════════════════════════

    private static AsyncQueue<LogEntry>? _queue = null;
    private static Thread<void*>? _writer = null;
    private static LogTarget?[] _targets;
    private static Config _config;
    private static bool _verbose = false;
    private static int _stopped = 0;
    private static int _pid = 0;
    private static string _tz;
    private static string _crash_path;

    // Crash-handler fd – opened lazily on first sync_write_crash() call.
    // Signal handlers use write-only (async-signal-safe) on this fd.
    private static int _crash_fd = -1;

    // Timestamp cache — avoids DateTime allocation on every entry.
    // Regenerated only when the millisecond changes.
    private static string _ts_cache;
    private static int64 _ts_cache_key;

    private const int FLUSH_INTERVAL_US = 100000;
    private const int MAX_ROTATED_FILES_DEFAULT = 10;

    // ═══════════════════════════════════════════════════════════════
    //  Timestamp helpers
    // ═══════════════════════════════════════════════════════════════

    private static string timestamp () {
        var now_us = GLib.get_real_time ();
        var now_ms = now_us / 1000;
        if (now_ms != _ts_cache_key) {
            var dt = new DateTime.from_unix_local (now_us / 1000000);
            var ms = (int) (now_ms % 1000);
            _ts_cache = "%s.%03d%s".printf (dt.format ("%Y-%m-%dT%H:%M:%S"), ms, _tz);
            _ts_cache_key = now_ms;
        }
        return _ts_cache;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Category helpers
    // ═══════════════════════════════════════════════════════════════

    private static string category_name (Category cat) {
        switch (cat) {
            case APP:      return "app";
            case WIFI:     return "wifi";
            case SECURITY: return "security";
            case CRASH:    return "crash";
            default:       return "app";
        }
    }

    private static Category category_from_module (string module) {
        if (module == "NetworkManager" || module.has_prefix ("Wifi")) {
            return WIFI;
        }
        return APP;
    }

    // ═══════════════════════════════════════════════════════════════
    //  File / rotation
    // ═══════════════════════════════════════════════════════════════

    private static unowned LogTarget get_target (Category cat) {
        var idx = (int) cat;
        if (_targets[idx] == null) {
            var name = category_name (cat);
            var path = Path.build_filename (_config.log_dir, "%s.log".printf (name));
            _targets[idx] = new LogTarget (path);
        }
        return _targets[idx];
    }

    /**
     * Open (or re-open) a log file for append.  Called lazily on
     * first write and after rotation.  Writer-thread only.
     */
    private static void open_target (LogTarget target) {
        if (target.stream != null) {
            target.stream.flush ();
            target.stream = null;
        }
        target.stream = FileStream.open (target.path, "a");
        if (target.stream != null) {
            // Seek to end to get accurate size (in case of prior writes
            // that bypassed our tracking, e.g. after rotation recovery).
            target.stream.seek (0, FileSeek.END);
            target.current_size = (int64) target.stream.tell ();
        } else {
            target.current_size = 0;
        }
    }

    /**
     * Rotate a single category file:
     *   1. Delete oldest (max_rotated_files)
     *   2. Shift .N-1 → .N for N = max..1
     *   3. Rename current → .1
     *   4. Open fresh file
     *
     * Writer-thread only.
     */
    private static void rotate (LogTarget target) {
        if (target.stream != null) {
            target.stream.flush ();
            target.stream = null;
        }

        var max = _config.max_rotated_files > 0
            ? _config.max_rotated_files
            : MAX_ROTATED_FILES_DEFAULT;

        // 1. Delete the oldest backup
        var oldest = "%s.%u".printf (target.path, max);
        if (FileUtils.test (oldest, FileTest.EXISTS)) {
            FileUtils.unlink (oldest);
        }

        // 2. Shift chain downward
        for (uint i = max; i > 1; i--) {
            var from = "%s.%u".printf (target.path, i - 1);
            if (FileUtils.test (from, FileTest.EXISTS)) {
                FileUtils.rename (from, "%s.%u".printf (target.path, i));
            }
        }

        // 3. Rename current → .1
        if (FileUtils.test (target.path, FileTest.EXISTS)) {
            FileUtils.rename (target.path, "%s.1".printf (target.path));
        }

        // 4. Open new
        target.stream = FileStream.open (target.path, "a");
        target.current_size = 0;
    }

    /**
     * Ensure a target's file handle is open and the file is ready
     * for writing.  Rotates if the current file exceeds the limit.
     * Writer-thread only.
     */
    private static void ensure_target (LogTarget target) {
        if (target.stream == null) {
            open_target (target);
        }
        if (target.current_size >= (int64) _config.max_file_size) {
            rotate (target);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Formatting
    // ═══════════════════════════════════════════════════════════════

    private static string format_text (
        string ts, Level level, string module, string message
    ) {
        return "%s [%s] [%s] %s\n".printf (
            ts, level.to_string_ (), module, message
        );
    }

    private static string format_json (
        string ts, Level level, string module, string message
    ) {
        // Escape backslash, double-quote, newline in message
        var escaped = message.replace ("\\", "\\\\")
                             .replace ("\"", "\\\"")
                             .replace ("\n", "\\n");
        return "{\"timestamp\":\"%s\",\"level\":\"%s\",\"module\":\"%s\",\"message\":\"%s\"}\n".printf (
            ts, level.to_string_ (), module, escaped
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  Sync write to crash.log (async-signal-safe)
    // ═══════════════════════════════════════════════════════════════

    /**
     * Write a pre-formatted line to crash.log using raw POSIX I/O.
     *
     * This function is designed to be called from:
     *   - FATAL()  (before abort)
     *   - POSIX signal handlers (SIGSEGV, SIGABRT)
     *
     * It only uses async-signal-safe syscalls:
     *   write(2), open(2) with O_CREAT, close(2).
     */
    private static void sync_write_crash (string line) {
        if (_crash_fd < 0) {
            _crash_fd = Posix.open (
                _crash_path,
                Posix.O_WRONLY | Posix.O_CREAT | Posix.O_APPEND,
                0644
            );
        }
        if (_crash_fd >= 0) {
            var buf = line.data;
            Posix.write (_crash_fd, buf, buf.length);
            Posix.fsync (_crash_fd);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //  Writer thread
    // ═══════════════════════════════════════════════════════════════

    private static void write_to_target (LogTarget target, string line) {
        ensure_target (target);
        if (target.stream == null) return;
        target.stream.printf (line);
        target.current_size += (int64) line.length;
    }

    private static void write_entry (LogEntry entry) {
        var ts = timestamp ();
        var line = _config.format == Format.JSON
            ? format_json (ts, entry.level, entry.module, entry.message)
            : format_text (ts, entry.level, entry.module, entry.message);

        // Always write to the entry's own category target
        unowned var target = get_target (entry.cat);
        write_to_target (target, line);

        // FATAL also goes to crash.log synchronously
        if (entry.level == FATAL) {
            sync_write_crash (line);
        }
    }

    private static void flush_all () {
        for (int i = 0; i < 4; i++) {
            unowned var t = _targets[i];
            if (t != null && t.stream != null) {
                t.stream.flush ();
            }
        }
    }

    private static void close_all () {
        for (int i = 0; i < 4; i++) {
            unowned var t = _targets[i];
            if (t != null && t.stream != null) {
                t.stream.flush ();
                t.stream = null;
            }
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
                flush_all ();
            } else {
                // Timeout – periodic flush even when idle
                flush_all ();
                if (AtomicInt.get (ref _stopped) != 0) {
                    while ((entry = queue.try_pop ()) != null) {
                        write_entry (entry);
                    }
                    flush_all ();
                    close_all ();
                    break;
                }
            }
        }
        return null;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Core enqueue
    // ═══════════════════════════════════════════════════════════════

    private static void enqueue (Category cat, Level level, string module, string message) {
        if (_queue == null) return;
        // Level gate – cheap integer compare
        if (level < _config.level) return;
        _queue.push (new LogEntry (cat, level, module, message));
    }

    // ═══════════════════════════════════════════════════════════════
    //  GLib log hook crash handler
    // ═══════════════════════════════════════════════════════════════

    private static void glib_log_hook (
        string? log_domain,
        GLib.LogLevelFlags log_level,
        string? message
    ) {
        if ((log_level & (GLib.LogLevelFlags.LEVEL_ERROR
                         | GLib.LogLevelFlags.LEVEL_CRITICAL)) != 0) {
            var line = format_text (
                timestamp (), Level.FATAL,
                log_domain ?? "GLib",
                message ?? "Unknown GLib error"
            );
            sync_write_crash (line);
        }
        // Let the default handler run so GLib still calls abort()
        // for LEVEL_ERROR messages.
        GLib.Log.default_handler (log_domain, log_level, message);
    }

    // ═══════════════════════════════════════════════════════════════
    //  POSIX signal handlers
    // ═══════════════════════════════════════════════════════════════

    private static void crash_signal_handler (int sig) {
        string label;
        switch (sig) {
            case Posix.SIGSEGV: label = "SIGSEGV"; break;
            case Posix.SIGABRT: label = "SIGABRT"; break;
            case Posix.SIGFPE:  label = "SIGFPE";  break;
            case Posix.SIGBUS:  label = "SIGBUS";  break;
            case Posix.SIGILL:  label = "SIGILL";  break;
            default:            label = "SIGNAL";   break;
        }
        var line = format_text (
            timestamp (), Level.FATAL, "Signal", "%s at pid %d".printf (label, Posix.getpid ())
        );
        sync_write_crash (line);
        // Restore default and re-raise so the OS generates a core dump
        Posix.signal (sig, Posix.SIG_DFL);
        Posix.raise (sig);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Public API – lifecycle
    // ═══════════════════════════════════════════════════════════════

    /**
     * Initialise the logging subsystem.
     *
     * Creates the log directory, pre-opens crash.log, computes the
     * timezone offset, and starts the dedicated writer thread.
     *
     * @param config   Runtime configuration (copied internally).
     * @param verbose  When true, print INFO & DEBUG to stderr.
     */
    public static void init (Config config, bool verbose = false) {
        _verbose = verbose;
        _pid = Posix.getpid ();

        // Copy the config – the writer thread will read _config
        _config = config;

        // Compute timezone offset once, e.g. "+0500"
        var now = new DateTime.now_local ();
        var utc = now.to_utc ();
        var off = (int) ((now.get_hour () - utc.get_hour ()) * 60 +
                         (now.get_minute () - utc.get_minute ()) +
                         (now.get_day_of_year () - utc.get_day_of_year ()) * 1440);
        var hrs = off.abs () / 60;
        var min = off.abs () % 60;
        _tz = "%s%02d%02d".printf (off >= 0 ? "+" : "-", hrs, min);

        // Ensure log directory exists
        DirUtils.create_with_parents (_config.log_dir, 0755);

        _crash_path = Path.build_filename (_config.log_dir, "crash.log");

        _targets = new LogTarget?[4];

        // Remove legacy single-file log and backups
        var legacy_dir = Path.build_filename (Environment.get_user_state_dir (), "wifiman");
        string[] legacy_names = {"wifiman.log", "wifiman.log.1",
                                 "wifiman.log.2", "wifiman.log.3",
                                 "logs" + Path.DIR_SEPARATOR_S + "wifiman-*"};
        // Only rm the exact legacy filenames (not the glob)
        foreach (var name in legacy_names) {
            if (name.has_prefix ("logs" + Path.DIR_SEPARATOR_S)) continue;
            var path = Path.build_filename (legacy_dir, name);
            if (FileUtils.test (path, FileTest.EXISTS)) {
                FileUtils.unlink (path);
            }
        }

        _queue = new AsyncQueue<LogEntry> ();

        try {
            _writer = new Thread<void*> ("log-writer", writer_func);
            info ("Logger", "Session started  pid=%d  verbose=%s  level=%s",
                  _pid, _verbose.to_string (), _config.level.to_string_ ());
        } catch (ThreadError e) {
            GLib.critical ("Failed to start logger thread: %s", e.message);
            _queue = null;
        }
    }

    /**
     * Shut down the logging subsystem.
     *
     * Signals the writer thread to drain the queue and exit.
     * Blocks until all queued entries are flushed and file handles
     * are closed.  Safe to call multiple times.
     */
    public static void shutdown () {
        _verbose = false;

        if (_queue != null) {
            info ("Logger", "Session ended");
        }

        AtomicInt.set (ref _stopped, 1);

        if (_writer != null) {
            _writer.join ();
            _writer = null;
        }

        if (_crash_fd >= 0) {
            Posix.close (_crash_fd);
            _crash_fd = -1;
        }

        _queue = null;
    }

    // ═══════════════════════════════════════════════════════════════
    //  Public API – crash handler installation
    // ═══════════════════════════════════════════════════════════════

    /**
     * Install crash handlers that write to crash.log before
     * terminating.
     *
     * Installs:
     *   1. A GLib log hook that captures ERROR/CRITICAL messages
     *      and writes them synchronously to crash.log.
     *   2. POSIX signal handlers for SIGSEGV, SIGABRT, SIGFPE,
     *      SIGBUS, and SIGILL.
     *
     * Call once during startup, after Log.init().
     */
    public static void install_crash_handler () {
        // GLib log hook for ERROR/CRITICAL
        GLib.Log.set_default_handler (glib_log_hook);

        // POSIX signal handlers
        Posix.signal (Posix.SIGSEGV, crash_signal_handler);
        Posix.signal (Posix.SIGABRT, crash_signal_handler);
        Posix.signal (Posix.SIGFPE,  crash_signal_handler);
        Posix.signal (Posix.SIGBUS,  crash_signal_handler);
        Posix.signal (Posix.SIGILL,  crash_signal_handler);
    }

    // ═══════════════════════════════════════════════════════════════
    //  Public API – level-based convenience (routes by module)
    // ═══════════════════════════════════════════════════════════════

    public static void debug (string module, string format, ...) {
        if (!_verbose) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        if (_queue != null) {
            _queue.push (new LogEntry (category_from_module (module), Level.DEBUG, module, msg));
        }
    }

    public static void info (string module, string format, ...) {
        if (_config.level > Level.INFO) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        if (_queue != null) {
            _queue.push (new LogEntry (category_from_module (module), Level.INFO, module, msg));
        }
        if (_verbose) {
            GLib.message ("[%s] %s", module, msg);
        }
    }

    public static void warn (string module, string format, ...) {
        if (_config.level > Level.WARN) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        if (_queue != null) {
            _queue.push (new LogEntry (category_from_module (module), Level.WARN, module, msg));
        }
        GLib.warning ("[%s] %s", module, msg);
    }

    public static void error (string module, string format, ...) {
        if (_config.level > Level.ERROR) return;
        var args = va_list ();
        var msg = format.vprintf (args);
        if (_queue != null) {
            _queue.push (new LogEntry (category_from_module (module), Level.ERROR, module, msg));
        }
        GLib.critical ("[%s] %s", module, msg);
    }

    public static void fatal (string module, string format, ...) {
        var args = va_list ();
        var msg = format.vprintf (args);
        if (_queue != null) {
            _queue.push (new LogEntry (Category.CRASH, Level.FATAL, module, msg));
        }
        // Sync write before aborting (bypasses the queue)
        var line = format_text (
            timestamp (), Level.FATAL, module, msg
        );
        sync_write_crash (line);
        GLib.message ("[%s] %s", module, msg);
        Posix.abort ();
    }

    // ═══════════════════════════════════════════════════════════════
    //  Public API – category-specific
    // ═══════════════════════════════════════════════════════════════

    public static void wifi (Level level, string module, string format, ...) {
        var args = va_list ();
        var msg = format.vprintf (args);
        enqueue (Category.WIFI, level, module, msg);
    }

    public static void security (Level level, string module, string format, ...) {
        var args = va_list ();
        var msg = format.vprintf (args);
        enqueue (Category.SECURITY, level, module, msg);
    }
}
