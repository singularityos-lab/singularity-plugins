using Gtk;
using Singularity;
using Singularity.Widgets;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(SensorsPlugin));
}

public class SensorsPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private SensorsIndicator? indicator;

    public void activate(PluginContext ctx) {
        this.context = ctx;
        indicator = new SensorsIndicator(
            Singularity.Core.safe_settings(Singularity.Runtime.desktop_settings_schema));
        context.add_panel_widget(indicator, Align.END);
    }

    public void deactivate() {
        if (indicator != null) {
            context.remove_panel_widget(indicator);
            indicator = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return null;
    }
}

/**
 * SensorsIndicator — one compact chip in the panel, detail in a popover.
 *
 * Deliberately ONE panel item rather than a row of them: a machine can
 * expose a lot of sensors (a CIX Sky1 board reports five thermal zones; an
 * x86 desktop with a Super-I/O chip can report a dozen), and putting each
 * on the bar would push the clock off the screen.
 *
 * All sysfs reading lives in Singularity.SensorMonitor
 * (libsingularity-system). This widget only renders what that backend
 * publishes, per CONTRIBUTING: headless system backends do not live in the
 * shell.
 */
class SensorsIndicator : Gtk.Box {
    // Sensor counts vary by two orders of magnitude across platforms, so
    // the detail list is capped rather than unbounded.
    private const int MAX_ROWS_PER_GROUP = 6;
    // Column count is derived from BOTH logical Gdk.Monitor geometry and
    // the monitor's scale factor (see configure_detail_layout()), so a
    // scaled HiDPI panel can use more columns than a same-logical-width
    // native display; capped at 3 so the popover never dominates a huge
    // display.
    private const int MAX_DETAIL_COLUMNS = 3;
    private const int DETAIL_COLUMN_WIDTH = 340;
    private const int DETAIL_COLUMN_SPACING = 18;
    private const int DETAIL_SCREEN_MARGIN = 96;

    private MenuButton button;
    private Label summary_label;
    private Box detail_box;
    private Box detail_toggle_box;
    private Box detail_columns_box;
    private Box[] detail_columns;
    private Box detail_target;
    private ScrolledWindow detail_scroller;
    private int detail_column_count = 1;
    private int[] detail_column_rows;
    private static Gtk.CssProvider? compact_rows_provider = null;
    private SensorMonitor monitor;
    private bool show_frequency = true;
    private bool show_utilization = true;
    // Controls TWO things, both driven by the single toggle in the
    // popover (see add_sensors_toggle()/rebuild_details()):
    //   1. Whether the per-kind sections (CPU/GPU/NPU/Memory/... from
    //      add_group()) render their heading label, or flatten into one
    //      unheaded list.
    //   2. Whether Clocks groups cpufreq policies that share an EXACT
    //      max_khz into one row, or lists every policy raw.
    // Defaults to grouped. Persisted so the choice survives a popover
    // close/reopen. On Clocks specifically, Sky1's five policies happen
    // to have five DIFFERENT ceilings, so grouped and ungrouped render
    // almost identically there; the toggle matters on hardware where
    // policies genuinely share a ceiling (a homogeneous desktop CPU, or
    // same-tier cores on a hybrid part) and collapsing is worth seeing
    // happen, or worth turning off to inspect per-policy.
    private bool sensors_grouped = true;
    private UtilizationMonitor util;
    // Set when on_updated() hides the chip because no sensors are
    // readable, so the unmap handler can tell a self-inflicted unmap
    // (must keep polling, or recovery is never observed) from a real one.
    private bool hidden_for_unavailable = false;
    // Kept as a field (the constructor previously only took it as a local
    // parameter) so the Clocks group/ungroup toggle can write the
    // preference back when clicked, not just read it once at construct.
    private GLib.Settings? settings;

    public SensorsIndicator(GLib.Settings? settings) {
        Object(orientation: Orientation.HORIZONTAL, spacing: 0);
        valign = Align.CENTER;
        add_css_class("sensors-indicator");
        this.settings = settings;

        summary_label = new Label("");
        summary_label.add_css_class("sensors-summary");
        // Pango markup, not plain text: the compact chip colours each
        // metric's dot + value independently (temperature by thermal
        // severity, memory by capacity, CPU/frequency neutral) so a
        // glance shows WHICH figure needs attention, not just that one
        // does.
        summary_label.use_markup = true;

        button = new MenuButton();
        button.add_css_class("flat");
        button.tooltip_text = _("Temperatures and CPU clock");
        button.child = summary_label;
        append(button);

        // Real Adw rows, with the original compact panel density rather
        // than preferences-page group chrome and separators.
        if (compact_rows_provider == null) {
            compact_rows_provider = new Gtk.CssProvider();
            compact_rows_provider.load_from_string(
                "row.sensors-compact-row { min-height: 0; padding: 0; " +
                "background: transparent; border: 0; box-shadow: none; }");
            Gtk.StyleContext.add_provider_for_display(get_display(),
                compact_rows_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        detail_box = new Box(Orientation.VERTICAL, 4);
        detail_box.margin_top = 10;
        detail_box.margin_bottom = 10;
        detail_box.margin_start = 12;
        detail_box.margin_end = 12;

        // The control spans the popover.  Variable-height sensor sections
        // then flow into independent vertical columns; unlike a FlowBox
        // row, a tall CPU section does not leave a matching blank hole
        // beneath a short GPU section in the opposite column.
        detail_toggle_box = new Box(Orientation.VERTICAL, 4);
        detail_columns_box = new Box(Orientation.HORIZONTAL,
                                     DETAIL_COLUMN_SPACING);
        detail_columns_box.homogeneous = true;
        detail_columns = new Box[MAX_DETAIL_COLUMNS];
        detail_column_rows = new int[MAX_DETAIL_COLUMNS];
        for (int i = 0; i < MAX_DETAIL_COLUMNS; i++) {
            detail_columns[i] = new Box(Orientation.VERTICAL, 8);
            detail_columns[i].hexpand = true;
            detail_columns[i].visible = i == 0;
            detail_columns_box.append(detail_columns[i]);
        }
        detail_box.append(detail_toggle_box);
        detail_box.append(detail_columns_box);
        detail_target = detail_columns[0];

        Popover popover = new Popover();
        // Natural size is the ordinary presentation.  Automatic vertical
        // scrolling remains only as a safety net for unusually many rows
        // on a short display; configure_detail_layout() derives the cap
        // from the monitor every time the popover opens.
        detail_scroller = new ScrolledWindow();
        detail_scroller.child = detail_box;
        detail_scroller.propagate_natural_height = true;
        detail_scroller.propagate_natural_width = true;
        detail_scroller.hscrollbar_policy = PolicyType.NEVER;
        detail_scroller.vscrollbar_policy = PolicyType.AUTOMATIC;
        popover.child = detail_scroller;
        button.popover = popover;

        // Populate the moment the popover opens, not on the next tick.
        //
        // rebuild_details() runs only from on_updated(), and only when the
        // popover is ALREADY visible -- so the first open showed an empty
        // box and stayed empty until the timer next fired. With the
        // default two-second interval that reads as "the sensors take a
        // few tries to appear", which is exactly how it was reported from
        // the machine. Refreshing here also means the figures shown are
        // the ones at the instant of opening rather than up to a full
        // interval stale.
        //
        // refresh() publishes synchronously for the sysfs sources and then
        // emits updated(), so the existing on_updated() path does the
        // rebuild; there is no second code path to keep in step. The
        // NVIDIA query stays asynchronous and lands on a later tick as
        // before.
        popover.notify["visible"].connect(() => {
            if (popover.visible) {
                configure_detail_layout();
                monitor.refresh();
            }
        });

        monitor = new_sensor_monitor();
        util = new UtilizationMonitor();

        // Every settings read is guarded: this widget and the schema can
        // ship from different packages, and an unguarded read of a missing
        // key is a fatal abort that would take the panel -- and the
        // greeter, which builds the same Panel -- down with it.
        SettingsSchema? schema = settings != null ? settings.settings_schema : null;
        int interval = 2;
        if (schema != null && schema.has_key("sensors-interval-seconds")) {
            interval = settings.get_int("sensors-interval-seconds");
        }
        if (schema != null && schema.has_key("sensors-show-frequency")) {
            show_frequency = settings.get_boolean("sensors-show-frequency");
        }
        if (schema != null && schema.has_key("sensors-show-utilization")) {
            show_utilization = settings.get_boolean("sensors-show-utilization");
        }
        if (schema != null && schema.has_key("sensors-grouped")) {
            sensors_grouped = settings.get_boolean("sensors-grouped");
        }
        // Only override when the user has actually configured a zone name.
        // The schema's portable default for these keys is an empty string,
        // and monitor.gpu_hint/cpu_hint already carry the platform-specific
        // TZGT/TZ hints new_sensor_monitor() set up before this ran (the
        // only way to identify CPU/GPU on the shipping Sky1 ACPI topology).
        // Assigning unconditionally on "has_key" clobbered those hints with
        // an empty string on every load with default settings.
        if (schema != null && schema.has_key("sensors-gpu-zone")) {
            string gpu_zone = settings.get_string("sensors-gpu-zone");
            if (gpu_zone != "") monitor.gpu_hint = gpu_zone;
        }
        if (schema != null && schema.has_key("sensors-cpu-zone")) {
            string cpu_zone = settings.get_string("sensors-cpu-zone");
            if (cpu_zone != "") monitor.cpu_hint = cpu_zone;
        }

        monitor.updated.connect(on_updated);
        util.interval_seconds = interval;
        util.updated.connect(on_updated);
        // A never-started monitor has no readings, so on_updated() below
        // would see monitor.available == false and set visible = false --
        // and GTK never maps an invisible widget, so the map handler that
        // would otherwise start polling never fires. One synchronous
        // refresh (already used the same way when the popover opens)
        // establishes real availability before that first visibility
        // decision, so a fresh shell doesn't self-hide permanently.
        monitor.refresh();
        // Prime utilisation for the SAME reason, and BEFORE the first
        // visibility decision below.
        //
        // utilization_available() probes memory_fraction, which is -1.0
        // until something has polled. Leaving that to the map handler
        // rebuilds the exact deadlock the paragraph above describes, one
        // step further out: on a machine with no readable hwmon but a
        // perfectly good /proc -- a VM with no thermal zones, or any of
        // the many boards without an hwmon driver -- monitor.available is
        // false and utilization_available() is false only because nothing
        // has looked yet. on_updated() hides the widget, GTK never maps
        // it, util.start() never runs, and the indicator stays hidden for
        // the life of the session with CPU and memory figures it could
        // have shown all along.
        if (show_utilization) util.poll();
        on_updated();

        // Poll only while actually on screen. An unmapped or hidden panel
        // (e.g. a secondary output's panel that isn't currently shown)
        // has no visible reading, so a running timer there is pure sysfs
        // churn and, on boards with an async NVIDIA query, wasted work on
        // every tick -- exactly the idle cost this feature's interval
        // setting exists to bound. start()/stop() are idempotent no-ops
        // when already in the requested state (SensorMonitor.start/stop),
        // so map/unmap can call them freely without tracking state here.
        map.connect(() => {
            monitor.start(interval);
            if (show_utilization) util.start();
        });
        unmap.connect(() => {
            if (hidden_for_unavailable) return;
            monitor.stop();
            util.stop();
        });
        if (get_mapped()) {
            monitor.start(interval);
            if (show_utilization) util.start();
        }
    }

    public override void dispose() {
        monitor.updated.disconnect(on_updated);
        monitor.stop();
        util.updated.disconnect(on_updated);
        util.stop();
        base.dispose();
    }

    private static string format_celsius(int millidegrees) {
        return "%d°".printf((millidegrees + 500) / 1000);
    }

    private static string format_clock(int khz) {
        return khz >= 1000000
            ? "%.1f GHz".printf(khz / 1000000.0)
            : "%d MHz".printf(khz / 1000);
    }

    /** Find the monitor that owns the panel surface. */
    private Gdk.Monitor? panel_monitor() {
        var window = get_root() as Gtk.Window;
        if (window != null) {
            var surface = window.get_surface();
            if (surface != null) {
                var display = surface.get_display();
                var at_surface = display.get_monitor_at_surface(surface);
                if (at_surface != null) return at_surface;
            }
        }

        // The widget can briefly have no root during construction.  The
        // first display monitor is the same fallback used elsewhere in
        // the shell for pre-map sizing.
        var display = Gdk.Display.get_default();
        if (display != null && display.get_monitors().get_n_items() > 0) {
            return display.get_monitors().get_item(0) as Gdk.Monitor;
        }
        return null;
    }

    /** Re-evaluate width and overflow bounds on every popover opening. */
    private void configure_detail_layout() {
        int screen_width = 1024;
        int screen_height = 768;
        var target_monitor = panel_monitor();
        if (target_monitor != null) {
            var geometry = target_monitor.get_geometry();
            screen_width = geometry.width;
            screen_height = geometry.height;
        }

        // Base density on effective physical resolution rather than one
        // logical-pixel breakpoint. A scaled HiDPI panel can therefore use
        // more columns than a native low-resolution display with the same
        // logical width, and a huge logical desktop on a non-scaled panel
        // is capped by the logical calculation instead of over-widening.
        int scale_factor = 1;
        if (target_monitor != null) scale_factor = target_monitor.get_scale_factor();
        int effective_width = screen_width * int.max(1, scale_factor);
        int available_width = int.max(DETAIL_COLUMN_WIDTH, effective_width - DETAIL_SCREEN_MARGIN);
        int density_slot = DETAIL_COLUMN_WIDTH * 2 + DETAIL_COLUMN_SPACING;
        int physical_column_count = int.min(MAX_DETAIL_COLUMNS,
            int.max(1, (available_width + DETAIL_COLUMN_SPACING) / density_slot));
        int logical_width = int.max(DETAIL_COLUMN_WIDTH, screen_width - DETAIL_SCREEN_MARGIN);
        int logical_column_count = int.max(1,
            (logical_width + DETAIL_COLUMN_SPACING) / (DETAIL_COLUMN_WIDTH + DETAIL_COLUMN_SPACING));
        detail_column_count = int.min(physical_column_count, logical_column_count);
        detail_column_count = int.min(detail_column_count, MAX_DETAIL_COLUMNS);

        for (int i = 0; i < MAX_DETAIL_COLUMNS; i++) {
            detail_columns[i].visible = i < detail_column_count;
        }
        detail_columns_box.spacing = detail_column_count > 1
            ? DETAIL_COLUMN_SPACING : 0;

        int content_width = DETAIL_COLUMN_WIDTH * detail_column_count
            + DETAIL_COLUMN_SPACING * (detail_column_count - 1);
        detail_scroller.min_content_width = content_width;
        detail_scroller.max_content_width = content_width;
        detail_scroller.max_content_height = int.max(320,
            screen_height - DETAIL_SCREEN_MARGIN);
    }

    /**
     * True when utilisation has something real to show.
     *
     * Memory is the probe because it is the one figure that is available
     * on the FIRST sample -- CPU and disk are rates and read -1.0 until a
     * second one lands, so testing those would report "unavailable" for
     * one interval on every start.
     */
    private bool utilization_available() {
        return show_utilization && util.memory_fraction >= 0.0;
    }

    /**
     * Resolve a NAMED theme colour (e.g. "success_color") to a hex
     * string for Pango markup.
     *
     * Markup spans take a literal colour, not a CSS variable, so the
     * value has to be looked up at render time rather than written once
     * -- this is what keeps it honest across a light/dark theme switch
     * instead of baking in a colour that only happened to be right when
     * the code was written. Falls back to the theme's plain text colour
     * if the named token is ever missing, so a lookup failure degrades
     * to unstyled text rather than invalid markup.
     */
    private string theme_color_hex(string color_name) {
        // lookup_color lives on StyleContext, not on Widget directly
        // (deprecated since GTK 4.10, but still the working path -- no
        // non-deprecated replacement exists for resolving a NAMED CSS
        // colour at runtime, only get_color() for the resolved `color`
        // property itself).
        var style = summary_label.get_style_context();
        Gdk.RGBA rgba;
        if (!style.lookup_color(color_name, out rgba)) {
            if (!style.lookup_color("text_color", out rgba)) {
                return "#ffffff";
            }
        }
        return "#%02x%02x%02x".printf(
            (uint) Math.round(rgba.red * 255),
            (uint) Math.round(rgba.green * 255),
            (uint) Math.round(rgba.blue * 255));
    }

    /** One coloured "dot value" segment for the compact chip. */
    private string markup_segment(string color_hex, string text) {
        return "<span color='%s'>\u25cf %s</span>".printf(color_hex, Markup.escape_text(text));
    }

    private static int percent_of(double fraction) {
        int p = (int) Math.round(fraction * 100.0);
        if (p < 0) return 0;
        return p > 100 ? 100 : p;
    }

    /**
     * Binary units, because that is what a filesystem reports.
     *
     * GIO's filesystem::size is the block count times the block size, so
     * dividing by 1000 would disagree with df on the same mount and make
     * the panel look wrong rather than merely differently-rounded.
     */
    private static string format_bytes(uint64 bytes) {
        const double K = 1024.0;
        double v = (double) bytes;
        if (v < K) return "%.0f B".printf(v);
        v /= K;
        if (v < K) return "%.0f KiB".printf(v);
        v /= K;
        if (v < K) return "%.0f MiB".printf(v);
        v /= K;
        if (v < K) return "%.1f GiB".printf(v);
        return "%.1f TiB".printf(v / K);
    }

    /**
     * Colour a FILLED resource, but never a BUSY one.
     *
     * The same reasoning the Clocks section documents: a core pinned at
     * 100% is doing its job and painting it red trains the user to ignore
     * the colour. A disk at 100% is a machine about to stop working. So
     * capacity and memory get severity and CPU/disk-busy do not. The
     * thresholds match ResourceMonitor's alert points so the panel turns
     * amber at the same moment the notification fires, rather than at
     * some second, unrelated number.
     */
    private static Severity capacity_severity(double fraction) {
        if (fraction >= 0.95) return Severity.CRITICAL;
        if (fraction >= 0.85) return Severity.HOT;
        return Severity.NORMAL;
    }

    private void on_updated() {
        // Temperatures being unreadable no longer hides the whole chip.
        // /proc/stat and /proc/meminfo exist on every Linux machine,
        // including the many with no hwmon at all and VMs that expose no
        // thermal zones; on those the old test hid a control that had
        // perfectly good CPU and memory figures to show.
        if (!monitor.available && !utilization_available()) {
            // Nothing readable on this hardware: hide rather than show zeros.
            //
            // Availability must not switch off the mechanism that detects
            // availability. Hiding unmaps the widget, which fires the
            // unmap handler below and would stop the poll timer -- after
            // which nothing can ever observe the sensors coming back, so
            // a momentary gap (hwmon driver reloading, a GPU power-gated,
            // a sensor hot-unplugged) would remove the chip until the
            // shell restarted. The flag tells the unmap handler this
            // particular unmap is self-inflicted and polling must survive
            // it; a real unmap (panel genuinely off screen) still stops.
            hidden_for_unavailable = true;
            visible = false;
            return;
        }
        hidden_for_unavailable = false;
        visible = true;

        // Prefer a sensor positively identified as the CPU. The backend
        // reports -1 when it found none, and falls back to the hottest
        // unidentified sensor -- it never guesses that an unknown chip is
        // the processor.
        int primary = monitor.cpu_millidegrees >= 0
            ? monitor.cpu_millidegrees
            : monitor.system_millidegrees;

        // Colour the chip on the bar, not only the rows inside the
        // popover. A temperature that needs attention is worth noticing
        // WITHOUT opening anything -- a popover nobody opens conveys
        // nothing. The severity shown is the one belonging to the sensor
        // whose number is displayed, so the colour and the figure always
        // describe the same sensor.
        SensorKind primary_kind = monitor.cpu_millidegrees >= 0
            ? SensorKind.CPU
            : SensorKind.SYSTEM;

        // Last resort: the hottest reading of ANY kind.
        //
        // available == true only means SOMETHING is readable, not that a
        // CPU or SYSTEM reading exists. A machine whose sensors all
        // classify as GPU/STORAGE/NETWORK leaves both selections above at
        // -1, and with cpufreq also unavailable the chip renders as an
        // empty label -- a blank control sitting next to a popover full
        // of perfectly good temperatures. Showing the hottest reading is
        // both non-empty and the one worth surfacing; taking its kind too
        // keeps the colour describing the number, which is the invariant
        // the severity block below depends on.
        if (primary < 0) {
            foreach (SensorReading reading in monitor.readings()) {
                if (reading.millidegrees > primary) {
                    primary = reading.millidegrees;
                    primary_kind = reading.kind;
                }
            }
        }

        Severity primary_severity = Severity.NORMAL;
        foreach (SensorReading reading in monitor.readings()) {
            if (reading.kind == primary_kind
                && reading.millidegrees == primary) {
                primary_severity = reading.severity;
                break;
            }
        }
        // Drop the whole-label severity class the old plain-text chip
        // used: each metric below now carries its OWN colour via
        // markup, which is strictly more informative (which figure is
        // hot, not just that something is) and would otherwise fight
        // the per-segment colours for the eye.
        summary_label.remove_css_class("warning");
        summary_label.remove_css_class("error");

        StringBuilder markup = new StringBuilder();
        if (primary >= 0) {
            markup.append(markup_segment(theme_color_hex(severity_color_name(primary_severity)),
                                          format_celsius(primary)));
        }
        if (show_frequency && monitor.cpu_khz > 0) {
            if (markup.len > 0) markup.append("  ");
            // Clock speed is informational, never an alarm colour --
            // same reasoning as CPU below: running near the maximum is
            // the CPU doing its job, not a problem to flag red.
            markup.append(markup_segment(theme_color_hex("accent_color"), format_clock(monitor.cpu_khz)));
        }
        // Utilisation in the compact chip, not only in the popover.
        //
        // Every fraction is checked against < 0 before it is formatted.
        // The monitor reports -1.0 for "not known yet" (a rate needs two
        // samples) and for "no swap configured", and multiplying that by
        // 100 renders a confident "-100%" -- observed on cixmini, which
        // has no swap.
        if (show_utilization) {
            if (util.cpu_fraction >= 0.0) {
                if (markup.len > 0) markup.append("  ");
                // CPU busy is never severity-coloured: a core at 100% is
                // doing its job, and painting that red would train the
                // user to ignore the colour that does mean something --
                // the same reasoning the popover's Clocks section and
                // capacity_severity() already document.
                markup.append(markup_segment(theme_color_hex("accent_color"),
                                              _("CPU %d%%").printf(percent_of(util.cpu_fraction))));
            }
            if (util.memory_fraction >= 0.0) {
                if (markup.len > 0) markup.append("  ");
                Severity mem_severity = capacity_severity(util.memory_fraction);
                markup.append(markup_segment(theme_color_hex(severity_color_name(mem_severity)),
                                              _("MEM %d%%").printf(percent_of(util.memory_fraction))));
            }
        }
        summary_label.label = markup.str;

        Popover? popover = button.popover;
        if (popover != null && popover.visible) {
            rebuild_details();
        }
    }

    // Singularity.Widgets.PreferencesRow is the native row container.
    // Custom compact content preserves the name/heat/value layout and
    // label width cap.
    private void append_compact_row(Gtk.Widget content) {
        var row = new PreferencesRow();
        row.activatable = false;
        row.selectable = false;
        row.add_css_class("sensors-compact-row");
        row.set_child(content);
        detail_target.append(row);
    }

    private static void clear_box(Box box) {
        Gtk.Widget? child = box.get_first_child();
        while (child != null) {
            box.remove(child);
            child = box.get_first_child();
        }
    }

    private Box begin_detail_section() {
        var section = new Box(Orientation.VERTICAL, 4);
        // Bordered frame so stacked resource-pool sections in the same
        // column read as distinct cards, not one continuous list.
        section.add_css_class("sensors-resource-section");
        detail_target = section;
        return section;
    }

    /** Keep every heading with its rows and balance whole sections. */
    private void finish_detail_section(Box section) {
        if (section.get_first_child() == null) return;

        int rows = 0;
        for (Gtk.Widget? child = section.get_first_child(); child != null;
             child = child.get_next_sibling()) {
            rows++;
        }

        int target_column = 0;
        for (int i = 1; i < detail_column_count; i++) {
            if (detail_column_rows[i] < detail_column_rows[target_column]) {
                target_column = i;
            }
        }
        detail_columns[target_column].append(section);
        detail_column_rows[target_column] += rows;
        detail_target = detail_columns[0];
    }

    private void add_heading(string title) {
        Label heading = new Label(title);
        heading.add_css_class("heading");
        heading.halign = Align.START;
        heading.margin_top = 4;
        append_compact_row(heading);
    }

    /**
     * Popover-wide Grouped/Ungrouped toggle. Rendered first, before any
     * sensor section, so its scope (every group below, not just one
     * subsection) is visible from where it sits.
     *
     * The label doubles as the current state, not just an action verb
     * ("Grouped" / "Ungrouped"), so glancing at it tells you which mode
     * you are already in -- an action-only "Group"/"Ungroup" button
     * would require remembering what you last clicked.
     */
    private void add_sensors_toggle() {
        Box row = new Box(Orientation.HORIZONTAL, 6);
        row.margin_top = 4;

        Label heading = new Label(_("Sensors"));
        heading.add_css_class("heading");
        heading.halign = Align.START;
        heading.hexpand = true;
        row.append(heading);

        Button toggle = new Button();
        toggle.has_frame = false;
        toggle.add_css_class("flat");
        toggle.add_css_class("dim-label");
        toggle.label = sensors_grouped ? _("Grouped") : _("Ungrouped");
        toggle.clicked.connect(() => {
            sensors_grouped = !sensors_grouped;
            SettingsSchema? schema = settings != null ? settings.settings_schema : null;
            if (schema != null && schema.has_key("sensors-grouped")) {
                settings.set_boolean("sensors-grouped", sensors_grouped);
            }
            rebuild_details();
        });
        row.append(toggle);

        append_compact_row(row);
    }

    /**
     * CSS class for a severity, or null to leave the label unstyled.
     *
     * These are GTK stock classes, not a palette of our own. A hand-picked
     * amber and red would collide with whatever accent the user's theme
     * uses and would need maintaining for light and dark separately;
     * "warning" and "error" are already defined by every GTK theme and
     * already legible on its background.
     *
     * NORMAL keeps the dim treatment the rows have always had, and WARM
     * deliberately gets NOTHING -- undimming to the ordinary foreground is
     * the first step of the ramp. Colour is spent only where it means
     * something: dim, plain, amber, red.
     */
    /**
     * Severity -> a named theme colour, for markup (not a CSS class).
     *
     * NORMAL reads as success (a calm "this is fine" green) rather than
     * plain text, matching the standard status-dashboard convention the
     * graphical chip is going for. WARM stays neutral -- the original
     * design's severity_css() below also treats WARM as not yet worth
     * flagging, and this mirrors that rather than inventing a new
     * threshold.
     */
    private string severity_color_name(Severity severity) {
        switch (severity) {
            case Severity.CRITICAL: return "error_color";
            case Severity.HOT:      return "warning_color";
            case Severity.WARM:     return "text_color";
            default:                return "success_color";
        }
    }

    private static string? severity_css(Severity severity) {
        switch (severity) {
            case Severity.CRITICAL: return "error";
            case Severity.HOT:      return "warning";
            case Severity.WARM:     return null;
            default:                return "dim-label";
        }
    }

    /**
     * The heat bar, drawn rather than themed.
     *
     * This started as a Gtk.LevelBar and that was wrong. GTK gives a
     * LevelBar its own offset classes (level-low / level-high / level-full)
     * and the theme styles them with BATTERY semantics, where low means
     * trouble and is painted red. The result on real hardware was every
     * sensor showing a short red bar regardless of temperature -- a 46 C
     * CPU rendered exactly as alarming as a hot drive, which is worse than
     * no bar at all. Overriding it meant fighting theme rules on a widget
     * whose whole purpose is to be themed.
     *
     * A DrawingArea owns its pixels. No theme rule can reach it, the ramp
     * means the same thing on every machine, and the colours are the ones
     * chosen here rather than whatever "low" happens to mean to a theme.
     */
    private const double[] HEAT_STOPS = { 0.40, 0.55, 0.70, 0.85 };

    private static void heat_rgb(double f, out double r, out double g, out double b) {
        // cool blue -> green -> amber -> orange -> red
        if (f < HEAT_STOPS[0])      { r = 0.29; g = 0.56; b = 0.85; }
        else if (f < HEAT_STOPS[1]) { r = 0.20; g = 0.63; b = 0.44; }
        else if (f < HEAT_STOPS[2]) { r = 0.83; g = 0.63; b = 0.09; }
        else if (f < HEAT_STOPS[3]) { r = 0.88; g = 0.42; b = 0.12; }
        else                        { r = 0.84; g = 0.24; b = 0.24; }
    }

    private Gtk.DrawingArea make_heat_bar(double heat) {
        var area = new Gtk.DrawingArea();
        area.content_width = 72;
        area.content_height = 6;
        area.valign = Align.CENTER;
        double f = heat.clamp(0.0, 1.0);
        area.set_draw_func((a, cr, w, h) => {
            double radius = h / 2.0;
            // Trough: a faint neutral track, so an almost-empty bar still
            // reads as a bar and not as a rendering glitch.
            cr.set_source_rgba(0.5, 0.5, 0.5, 0.25);
            rounded_rect(cr, 0, 0, w, h, radius);
            cr.fill();
            if (f <= 0.0) {
                return;
            }
            double fill_w = double.max(h, w * f);
            double r, g, b;
            heat_rgb(f, out r, out g, out b);
            cr.set_source_rgb(r, g, b);
            rounded_rect(cr, 0, 0, fill_w, h, radius);
            cr.fill();
        });
        return area;
    }

    private static void rounded_rect(Cairo.Context cr, double x, double y,
                                     double w, double h, double r) {
        cr.new_sub_path();
        cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
        cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
        cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
        cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
        cr.close_path();
    }

    private void add_row(string name, string value,
                         Severity severity = Severity.NORMAL,
                         double heat = -1.0) {
        Box row = new Box(Orientation.HORIZONTAL, 12);
        Label name_label = new Label(name);
        name_label.halign = Align.START;
        name_label.hexpand = true;
        // Long sensor names must not push the reading off the popover.
        name_label.ellipsize = Pango.EllipsizeMode.END;
        name_label.max_width_chars = 22;
        name_label.tooltip_text = name;
        row.append(name_label);

        // The bar carries the MAGNITUDE, the label colour carries the
        // ALARM. They are different questions: on a healthy machine every
        // sensor is NORMAL and the labels say nothing, while the bars
        // still show which part of the board is warmest. Measured on O6N:
        // 20 readings, 19 of them NORMAL, and the NVMe at 0.74 is the only
        // one that stands out -- but only because of the bar.
        if (heat >= 0.0) {
            row.append(make_heat_bar(heat));
        }

        Label value_label = new Label(value);
        value_label.halign = Align.END;
        string? css = severity_css(severity);
        if (css != null) {
            value_label.add_css_class(css);
        }
        row.append(value_label);
        append_compact_row(row);
    }

    /**
     * Live utilisation: processor, memory, storage.
     *
     * Gated on the SAME preference as the compact chip. A setting honoured
     * in one render path and ignored in the other is how sensors-show-
     * frequency shipped a half-working toggle.
     */
    private void add_utilization_details() {
        if (!show_utilization) {
            return;
        }

        // ---- processor ----
        UtilizationReading[] cores = util.per_cpu();
        if (util.cpu_fraction >= 0.0 || cores.length > 0) {
            add_heading(_("Processor"));
            if (util.cpu_fraction >= 0.0) {
                add_row(_("Total"), "%d%%".printf(percent_of(util.cpu_fraction)),
                        Severity.NORMAL, util.cpu_fraction);
            }
            // Same cap-and-count convention as add_group(). Sky1 has 12
            // cores and server parts have far more; the popover scrolls,
            // but an unbounded list still buries the temperatures under
            // it.
            int shown = 0;
            int hidden = 0;
            double hidden_sum = 0.0;
            foreach (UtilizationReading core in cores) {
                if (core.fraction < 0.0) {
                    continue;   // first sample: no rate yet
                }
                if (shown < MAX_ROWS_PER_GROUP) {
                    add_row(core.label, "%d%%".printf(percent_of(core.fraction)),
                            Severity.NORMAL, core.fraction);
                    shown++;
                } else {
                    hidden++;
                    hidden_sum += core.fraction;
                }
            }
            // The overflow row shows the AVERAGE of what got cut, not
            // just a count with no data in it -- a machine with 64 cores
            // still tells you roughly how busy the other 58 are, instead
            // of discarding that information entirely.
            if (hidden > 0) {
                add_row(_("%d more").printf(hidden),
                        "%d%%".printf(percent_of(hidden_sum / hidden)));
            }
        }

        // ---- memory ----
        if (util.memory_fraction >= 0.0) {
            add_heading(_("Memory"));
            add_row(_("RAM"),
                    _("%s / %s").printf(format_bytes(util.memory_used_bytes),
                                        format_bytes(util.memory_total_bytes)),
                    capacity_severity(util.memory_fraction),
                    util.memory_fraction);
            // Omitted entirely when there is no swap. A "Swap 0%" row on a
            // swapless machine says the swap is empty, not that there is
            // none, which is a different and misleading claim.
            if (util.swap_fraction >= 0.0) {
                add_row(_("Swap"), "%d%%".printf(percent_of(util.swap_fraction)),
                        capacity_severity(util.swap_fraction),
                        util.swap_fraction);
            }
        }

        // ---- storage ----
        CapacityReading[] volumes = util.filesystems();
        UtilizationReading[] spindles = util.disks();
        if (volumes.length > 0 || spindles.length > 0) {
            add_heading(_("Storage"));

            int shown = 0;
            // Capacity and activity get SEPARATE overflow counters, not
            // one shared one: they are different quantities (a fill
            // level vs a busy rate) and averaging them together, or
            // averaging capacity % across differently-sized volumes,
            // would blend numbers that don't mean the same thing. Only
            // the activity overflow gets an average -- it is a rate,
            // the same class of number CPU busy already is.
            int hidden_volumes = 0;
            foreach (CapacityReading vol in volumes) {
                if (vol.fraction < 0.0) {
                    continue;
                }
                if (shown < MAX_ROWS_PER_GROUP) {
                    add_row(vol.label,
                            _("%s / %s").printf(format_bytes(vol.used_bytes),
                                                format_bytes(vol.total_bytes)),
                            capacity_severity(vol.fraction), vol.fraction);
                    shown++;
                } else {
                    hidden_volumes++;
                }
            }
            if (hidden_volumes > 0) {
                add_row(_("%d more").printf(hidden_volumes), "");
            }

            // Busy percentage is a RATE, not a fill level, so it is listed
            // after capacity and left uncoloured -- a disk at 100% busy is
            // working, a disk at 100% full is broken, and they must not
            // look alike.
            int hidden_disks = 0;
            double hidden_disk_sum = 0.0;
            foreach (UtilizationReading disk in spindles) {
                if (disk.fraction < 0.0) {
                    continue;
                }
                if (shown < MAX_ROWS_PER_GROUP) {
                    add_row(_("%s activity").printf(disk.label),
                            "%d%%".printf(percent_of(disk.fraction)),
                            Severity.NORMAL, disk.fraction);
                    shown++;
                } else {
                    hidden_disks++;
                    hidden_disk_sum += disk.fraction;
                }
            }
            if (hidden_disks > 0) {
                add_row(_("%d more").printf(hidden_disks),
                        "%d%%".printf(percent_of(hidden_disk_sum / hidden_disks)));
            }
        }
    }

    private void add_group(SensorKind kind, string title) {
        SensorReading[] matching = {};
        foreach (SensorReading reading in monitor.readings()) {
            if (reading.kind == kind) {
                matching += reading;
            }
        }
        if (matching.length == 0) {
            return;
        }

        if (sensors_grouped) {
            // Collapse the whole family into ONE row: the average
            // temperature across every reading of this kind, labelled by
            // the kind itself rather than any individual sensor. No
            // heading -- the row's own label ("CPU", "GPU", ...) already
            // says what it is. Deliberately uncoloured and bar-less, same
            // reasoning as the overflow rows in the ungrouped branch:
            // severity is classified per-sensor against that sensor's own
            // limit, and averaging across sensors -- let alone an entire
            // family of them -- has no single threshold to colour or
            // scale a bar against.
            int64 sum = 0;
            foreach (SensorReading reading in matching) {
                sum += reading.millidegrees;
            }
            add_row(title, format_celsius((int) (sum / matching.length)));
            return;
        }

        add_heading(title);
        // Cap the rows. Sensor count varies enormously by platform: an ARM
        // dev board reports 5, a Qualcomm SC8280XP reports 55. Listing all
        // of them turns the popover into a wall of near-identical numbers,
        // so show the first few and state how many were left out.
        int shown = 0;
        int hidden = 0;
        int64 hidden_millidegrees_sum = 0;
        foreach (SensorReading reading in matching) {
            if (shown < MAX_ROWS_PER_GROUP) {
                add_row(reading.label, format_celsius(reading.millidegrees),
                        reading.severity, reading.heat_fraction);
                shown++;
            } else {
                hidden++;
                hidden_millidegrees_sum += reading.millidegrees;
            }
        }
        // The overflow row shows the AVERAGE temperature of what got
        // cut, not just a count with no data in it -- same reasoning as
        // the per-core and per-disk overflow rows below. Deliberately
        // uncoloured: severity is classified per-sensor against that
        // sensor's own limit, and averaging across sensors that may have
        // different limits has no single threshold to colour against.
        if (hidden > 0) {
            add_row(_("%d more").printf(hidden),
                    format_celsius((int) (hidden_millidegrees_sum / hidden)));
        }
    }

    /**
     * CPU temperature AND clock, in one section instead of two. They used
     * to be separate ("CPU" from add_group(), "Clocks" lower down in
     * rebuild_details()) which put two headings on the same physical
     * silicon with nothing connecting them.
     *
     * They stay two DIFFERENT KINDS OF ROW within that one section,
     * though, rather than one merged "50C / 2.6GHz" row per cluster:
     * CIX Sky1 names four thermal zones (CPU_B0/B1, CPU_M0/M1) that do
     * NOT partition onto the same five cpufreq clusters cluster_id
     * reports (verified on O6N: cluster_id 1/2/3/4/5 map exactly to
     * cpufreq policy0/2/6/8/10, one cluster per policy -- but there is
     * no sysfs link from a named thermal zone to the core numbers it
     * actually measures). Attaching a temperature to a specific clock
     * cluster would be a guess dressed up as a measurement. So: one
     * aggregate temperature for the whole CPU, and clock broken out by
     * cluster underneath it.
     */
    private void add_cpu_section() {
        SensorReading[] cpu_temps = {};
        foreach (SensorReading reading in monitor.readings()) {
            if (reading.kind == SensorKind.CPU) {
                cpu_temps += reading;
            }
        }
        // Honour sensors-show-frequency here too. It previously gated
        // only the compact summary, so turning frequency "off" still
        // rendered the entire Clocks section the moment the popover was
        // opened -- the preference silently did half of what it says.
        ClockReading[] clocks = show_frequency ? monitor.clocks() : new ClockReading[0];
        if (cpu_temps.length == 0 && clocks.length == 0) {
            return;
        }

        if (sensors_grouped) {
            if (cpu_temps.length > 0) {
                int64 sum = 0;
                foreach (SensorReading reading in cpu_temps) {
                    sum += reading.millidegrees;
                }
                add_row(_("CPU"), format_celsius((int) (sum / cpu_temps.length)));
            }
            // Group by max_khz -- the actual performance-tier signal.
            // clocks() is one entry per cpufreq POLICY, and a policy is
            // a clock domain: cores sharing one on a heterogeneous SoC
            // (Sky1's five policies) are exactly the cores in the same
            // tier, so an equal max_khz reliably identifies "same tier"
            // without needing core-type names the backend doesn't have.
            // On a homogeneous desktop CPU where every core reports the
            // same max, this collapses a hundred identical rows into
            // one. On Sky1 specifically every policy happens to have a
            // DIFFERENT ceiling, so grouped and ungrouped render almost
            // identically there -- the toggle exists so that is
            // verifiable rather than assumed, and so it still collapses
            // rows on hardware where policies genuinely share a ceiling.
            //
            // Plain parallel arrays + linear scan rather than a Gee map:
            // tier count is always small (Sky1 has 5 policies at most),
            // so the O(n*tiers) scan costs nothing, and it avoids any
            // uncertainty about Gee's generic-boxing behaviour for a
            // primitive int key.
            int[] tier_max = {};
            int64[] tier_khz_sum = {};
            int[] tier_count = {};
            foreach (ClockReading c in clocks) {
                int idx = -1;
                for (int i = 0; i < tier_max.length; i++) {
                    if (tier_max[i] == c.max_khz) { idx = i; break; }
                }
                if (idx < 0) {
                    tier_max += c.max_khz;
                    tier_khz_sum += (int64) c.khz;
                    tier_count += 1;
                } else {
                    tier_khz_sum[idx] += c.khz;
                    tier_count[idx] += 1;
                }
            }
            // Fastest tier first: the one most people check first, and
            // matches how the sensor groups above already read
            // hottest-first.
            for (int i = 0; i < tier_max.length; i++) {
                for (int j = i + 1; j < tier_max.length; j++) {
                    if (tier_max[j] > tier_max[i]) {
                        int tmp_max = tier_max[i]; tier_max[i] = tier_max[j]; tier_max[j] = tmp_max;
                        int64 tmp_sum = tier_khz_sum[i]; tier_khz_sum[i] = tier_khz_sum[j]; tier_khz_sum[j] = tmp_sum;
                        int tmp_cnt = tier_count[i]; tier_count[i] = tier_count[j]; tier_count[j] = tmp_cnt;
                    }
                }
            }
            for (int i = 0; i < tier_max.length; i++) {
                int avg_khz = (int) (tier_khz_sum[i] / tier_count[i]);
                string label = tier_count[i] > 1
                    ? _("%d cores").printf(tier_count[i])
                    : _("1 core");
                string value = tier_max[i] > 0
                    ? "%s / %s".printf(format_clock(avg_khz), format_clock(tier_max[i]))
                    : format_clock(avg_khz);
                add_row(label, value);
            }
            return;
        }

        add_heading(_("CPU"));
        int shown = 0;
        int hidden = 0;
        int64 hidden_millidegrees_sum = 0;
        foreach (SensorReading reading in cpu_temps) {
            if (shown < MAX_ROWS_PER_GROUP) {
                add_row(reading.label, format_celsius(reading.millidegrees),
                        reading.severity, reading.heat_fraction);
                shown++;
            } else {
                hidden++;
                hidden_millidegrees_sum += reading.millidegrees;
            }
        }
        if (hidden > 0) {
            add_row(_("%d more").printf(hidden),
                    format_celsius((int) (hidden_millidegrees_sum / hidden)));
        }
        // Raw, one row per cpufreq policy, in whatever order clocks()
        // returned them -- no grouping, no averaging. The label is the
        // policy's own sysfs directory name (e.g. "policy0"), the same
        // identifier a person would see if they went and looked at
        // /sys/devices/system/cpu/cpufreq/ themselves.
        foreach (ClockReading c in clocks) {
            string value = c.max_khz > 0
                ? "%s / %s".printf(format_clock(c.khz), format_clock(c.max_khz))
                : format_clock(c.khz);
            add_row(c.label, value);
        }
    }

    /** Built only while the popover is open. */
    private void rebuild_details() {
        clear_box(detail_toggle_box);
        for (int i = 0; i < MAX_DETAIL_COLUMNS; i++) {
            clear_box(detail_columns[i]);
            detail_column_rows[i] = 0;
        }

        // One control for the whole popover, at the top so its scope is
        // obvious before any section renders: it decides whether every
        // group below (CPU/GPU/NPU/... and Clocks) shows its heading.
        detail_target = detail_toggle_box;
        add_sensors_toggle();

        // Every kind the backend can name, hottest-silicon first and the
        // board last. add_group() skips a kind with no sensors, so a PC
        // that reports only CPU and GPU still shows exactly two headings.
        //
        // This list previously stopped at SYSTEM, which meant the wider
        // kinds were classified and then silently dropped -- on Sky1 that
        // hid eleven of nineteen readings, including the NVMe that was the
        // only one worth looking at.
        Box section = begin_detail_section();
        add_cpu_section();
        finish_detail_section(section);

        section = begin_detail_section();
        add_group(SensorKind.GPU,     _("GPU"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.NPU,     _("NPU"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.VPU,     _("VPU"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.MEMORY,  _("Memory"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.STORAGE, _("Storage"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.NETWORK, _("Network"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.BOARD,   _("Board"));
        finish_detail_section(section);
        section = begin_detail_section();
        add_group(SensorKind.SYSTEM,  _("System"));
        finish_detail_section(section);

        section = begin_detail_section();
        add_utilization_details();
        finish_detail_section(section);
    }

    /**
     * Sensors, with the CIX Sky1 naming hints applied.
     *
     * MEASURED 2026-08-16 on two Sky1 machines that present COMPLETELY
     * DIFFERENT sensor topologies, decided by one kernel command line flag:
     *
     *   cixmini, 7.0.12-cix-sky1-next, no acpi_scmi_en flag
     *       -> one hwmon chip "scmi_sensors" carrying 22 LABELLED sensors
     *          (CPU_B0, CPU_M1, GPU_AVE, NPU, VPU, DDR_top, PCB_AMB, ...)
     *
     *   O6N,     7.2.0-rc7-sky1-ncz,    acpi_scmi_en=off
     *       -> no scmi_sensors at all; five bare ACPI thermal zones named
     *          TZB0 TZB1 TZM0 TZM1 TZGT, with NO labels and no tempN_crit
     *
     * We disable SCMI on 7.2 deliberately, so the shipping configuration is
     * the second one. There the allow-lists in SensorMonitor cannot help --
     * the identity is in a four-character ACPI name and nowhere else -- and
     * the panel reported cpu=-1 gpu=-1 on the board this product targets.
     *
     * TZB = big cluster, TZM = mid cluster, TZGT = graphics. gpu_hint is
     * tested before cpu_hint by SensorMonitor.classify(), so the more
     * specific TZGT claims the GPU before the broader TZ claims the rest.
     * Verified on O6N: cpu=49000 gpu=46000, with nvme and both r8169 NICs
     * still correctly SYSTEM. Both hints are inert on the scmi_sensors
     * topology, where no chip or label contains "TZ", so one configuration
     * serves both kernels.
     */
    private static SensorMonitor new_sensor_monitor() {
        var monitor = new SensorMonitor();
        if (is_cix_sky1()) {
            monitor.gpu_hint = "TZGT";
            monitor.cpu_hint = "TZ";
        }
        return monitor;
    }

    /**
     * True on CIX Sky1 boards (Radxa Orion O6/O6N, cixmini).
     *
     * Detects the SoC by its own ACPI hardware IDs rather than by board
     * branding. MEASURED on an O6N running the shipping ACPI kernel:
     * there is no devicetree at all, and every DMI vendor/product string
     * says "Radxa ... Orion O6N" -- not "CIX" and not "Sky1" -- so a
     * vendor-string match reports FALSE on the exact hardware these
     * hints exist for, silently restoring the cpu=-1/gpu=-1 bug they
     * were added to fix. The CIXH* HIDs are the SoC's, not the board
     * vendor's: 163 of them enumerate on that same machine. Devicetree
     * is still checked so a DT-booted Sky1 is covered too.
     */
    private static bool is_cix_sky1() {
        try {
            Dir acpi = Dir.open("/sys/bus/acpi/devices", 0);
            string? name;
            while ((name = acpi.read_name()) != null) {
                if (name.has_prefix("CIXH")) {
                    return true;
                }
            }
        } catch (FileError e) {
            // No ACPI bus (a DT-only kernel); fall through.
        }

        string[] dt_probes = {
            "/proc/device-tree/compatible",
            "/sys/firmware/devicetree/base/compatible",
        };
        foreach (string path in dt_probes) {
            // "compatible" is a NUL-SEPARATED list, conventionally most
            // specific first: "radxa,<board>\0cix,sky1". Reading it into a
            // Vala string and matching that stops at the first NUL, so
            // only the board entry is ever examined and the "cix,sky1"
            // that identifies the SoC is missed -- on precisely the
            // DT-booted configuration this fallback exists to catch.
            // load_contents() returns the real byte array, so every entry
            // is inspected.
            uint8[] raw;
            try {
                if (!File.new_for_path(path).load_contents(null, out raw, null)) {
                    continue;
                }
            } catch (Error e) {
                continue;
            }
            var joined = new StringBuilder();
            foreach (uint8 b in raw) {
                joined.append_c(b == 0 ? ' ' : (char) b);
            }
            string lowered = joined.str.down();
            if (lowered.contains("cix") || lowered.contains("sky1")) {
                return true;
            }
        }
        return false;
    }
}
