using Gtk;
using Singularity;
using Peas;
using Cairo;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(StatusMonitorPlugin));
}

public class StatusMonitorPlugin : Object, Singularity.Plugin {
    private StatusWidget widget;
    private PluginContext context;

    public void activate(PluginContext context) {
        this.context = context;
        widget = new StatusWidget();
        context.add_sidebar_widget(widget);
    }

    public void deactivate() {
        if (widget != null) {
            widget.stop_timer();
            context.remove_sidebar_widget(widget);
            widget = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return null;
    }
}

class StatusWidget : Box {
    private DrawingArea cpu_chart;
    private DrawingArea ram_chart;
    private double[] cpu_history;
    private double[] ram_history;
    private int history_size = 60;
    private Label cpu_label;
    private Label ram_label;
    private ulong last_total = 0;
    private ulong last_idle = 0;
    private uint _timer_id = 0;

    public StatusWidget() {
        Object(orientation: Orientation.HORIZONTAL, spacing: 12);
        margin_bottom = 12;

        cpu_history = new double[history_size];
        ram_history = new double[history_size];

        var cpu_box = create_chart_box("CPU", out cpu_chart, out cpu_label);
        var ram_box = create_chart_box("Memory", out ram_chart, out ram_label);

        append(cpu_box);
        append(ram_box);

        _timer_id = Timeout.add(1000, update_stats);
        update_stats();
    }

    public void stop_timer() {
        if (_timer_id != 0) {
            Source.remove(_timer_id);
            _timer_id = 0;
        }
    }

    private Box create_chart_box(string title, out DrawingArea chart, out Label label) {
        var box = new Box(Orientation.VERTICAL, 4);
        box.hexpand = true;
        box.add_css_class("card");

        var header = new Box(Orientation.HORIZONTAL, 4);
        header.margin_top = 8;
        header.margin_start = 12;
        header.margin_end = 12;

        var title_lbl = new Label(title);
        title_lbl.add_css_class("caption-heading");
        title_lbl.hexpand = true;
        title_lbl.halign = Align.START;
        title_lbl.opacity = 0.7;

        label = new Label("0%");
        label.add_css_class("title-3");

        header.append(title_lbl);
        header.append(label);
        box.append(header);

        chart = new DrawingArea();
        chart.set_size_request(-1, 50);
        chart.margin_bottom = 8;
        chart.set_draw_func(draw_chart);
        box.append(chart);

        return box;
    }

    private bool update_stats() {
        double cpu = 0;
        double ram = 0;

        // CPU
        try {
            string content;
            FileUtils.get_contents("/proc/stat", out content);
            var lines = content.split("\n");
            if (lines.length > 0) {
                var parts = lines[0].split(" ");
                ulong[] values = {};
                foreach (var p in parts) if (p != "" && p != "cpu") values += ulong.parse(p);

                if (values.length >= 4) {
                    ulong total = 0;
                    foreach (var v in values) total += v;
                    ulong idle = values[3];

                    ulong diff_total = total - last_total;
                    ulong diff_idle = idle - last_idle;

                    if (diff_total > 0) cpu = (double)(diff_total - diff_idle) / diff_total;

                    last_total = total;
                    last_idle = idle;
                }
            }
        } catch (Error e) {}

        // RAM
        try {
            string content;
            FileUtils.get_contents("/proc/meminfo", out content);
            ulong total_kb = 0;
            ulong available_kb = 0;
            foreach (var line in content.split("\n")) {
                if (line.has_prefix("MemTotal:")) total_kb = parse_kb(line);
                else if (line.has_prefix("MemAvailable:")) available_kb = parse_kb(line);
            }
            if (total_kb > 0) ram = (double)(total_kb - available_kb) / total_kb;
        } catch (Error e) {}

        // Update History
        for (int i = 0; i < history_size - 1; i++) {
            cpu_history[i] = cpu_history[i+1];
            ram_history[i] = ram_history[i+1];
        }
        cpu_history[history_size - 1] = cpu;
        ram_history[history_size - 1] = ram;

        cpu_label.label = "%d%%".printf((int)(cpu * 100));
        ram_label.label = "%d%%".printf((int)(ram * 100));

        cpu_chart.queue_draw();
        ram_chart.queue_draw();

        return true;
    }

    private ulong parse_kb(string line) {
        var parts = line.split_set(" :");
        foreach (var s in parts) if (s != "" && s[0].isdigit()) return ulong.parse(s);
        return 0;
    }

    private void draw_chart(DrawingArea area, Context cr, int w, int h) {
        double[] data = (area == cpu_chart) ? cpu_history : ram_history;
        Gdk.RGBA color = {};
        if (area == cpu_chart) color.parse("#3584e4");
        else color.parse("#9b59b6");

        double step = (double)w / (double)(history_size - 1);

        cr.move_to(0, h);
        for (int i = 0; i < history_size; i++) {
            double val = data[i];
            if (val > 1.0) val = 1.0;
            double y = h - (val * h);
            cr.line_to(i * step, y);
        }
        cr.line_to(w, h);
        cr.close_path();

        color.alpha = 0.2f;
        Gdk.cairo_set_source_rgba(cr, color);
        cr.fill();

        cr.move_to(0, h);
        bool first = true;
        for (int i = 0; i < history_size; i++) {
            double val = data[i];
            if (val > 1.0) val = 1.0;
            double y = h - (val * h);
            if (first) { cr.move_to(i * step, y); first = false; }
            else cr.line_to(i * step, y);
        }

        color.alpha = 1.0f;
        Gdk.cairo_set_source_rgba(cr, color);
        cr.set_line_width(2);
        cr.stroke();
    }
}
