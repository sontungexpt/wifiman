public class SignalIcon : Gtk.DrawingArea {
    public int strength { get; set; default = 0; }

    construct {
        width_request = 24;
        height_request = 24;
        set_draw_func (draw_signal);
        notify["strength"].connect (() => queue_draw ());
    }

    private void draw_signal (Gtk.DrawingArea area, Cairo.Context cr, int width, int height) {
        var color = get_style_context ().get_color ();
        int filled = strength >= 80 ? 4 : strength >= 60 ? 3 : strength >= 40 ? 2 : strength >= 20 ? 1 : 0;

        double cx = width / 2.0;
        double cy = height - 4.0;
        double[] radii = { 4.0, 8.0, 12.0, 16.0 };
        double start_angle = 5.0 * Math.PI / 4.0;
        double end_angle = 7.0 * Math.PI / 4.0;

        cr.set_line_cap (Cairo.LineCap.ROUND);

        for (int i = 0; i < 4; i++) {
            double lw = 2.0 + 0.5 * i;
            cr.set_line_width (lw);

            if (i < filled) {
                cr.set_source_rgba (color.red, color.green, color.blue, color.alpha);
            } else {
                cr.set_source_rgba (color.red, color.green, color.blue, color.alpha * 0.2);
            }

            cr.new_path ();
            cr.arc (cx, cy, radii[i], start_angle, end_angle);
            cr.stroke ();
        }
    }
}
