using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(WeatherPlugin));
}

public class WeatherPlugin : Object, Singularity.Plugin {
    private const int STALE_SECONDS = 1800;
    private PluginContext context;
    private Button? panel_btn = null;
    private Image weather_icon;
    private Label weather_label;
    private FileMonitor? monitor = null;
    private uint refresh_timer_id = 0;
    private int64 last_request = 0;
    private string place_id = "";
    private string summary = "";

    private static string snapshot_path() {
        return Path.build_filename(Environment.get_user_cache_dir(), "singularity-weather", "snapshot.json");
    }

    public void activate(PluginContext ctx) {
        this.context = ctx;

        panel_btn = new Button();
        panel_btn.add_css_class("flat");
        panel_btn.add_css_class("panel-button");
        panel_btn.visible = false;
        panel_btn.clicked.connect(open_weather);

        var btn_box = new Box(Orientation.HORIZONTAL, 4);
        btn_box.valign = Align.CENTER;
        weather_icon = new Image.from_icon_name("weather-few-clouds-symbolic");
        weather_icon.pixel_size = 14;
        btn_box.append(weather_icon);
        weather_label = new Label("");
        weather_label.add_css_class("caption");
        btn_box.append(weather_label);
        panel_btn.set_child(btn_box);

        context.add_clock_suffix_widget(panel_btn);

        try {
            DirUtils.create_with_parents(Path.get_dirname(snapshot_path()), 0700);
            monitor = File.new_for_path(snapshot_path()).monitor_file(FileMonitorFlags.NONE, null);
            monitor.changed.connect((f, other, event) => {
                if (event == FileMonitorEvent.CHANGES_DONE_HINT || event == FileMonitorEvent.CREATED || event == FileMonitorEvent.DELETED) {
                    update_display();
                }
            });
        } catch (Error e) {
            warning("weather: %s", e.message);
        }
        update_display();
        refresh_timer_id = Timeout.add_seconds(600, () => {
            update_display();
            return Source.CONTINUE;
        });
    }

    public void deactivate() {
        if (refresh_timer_id != 0) {
            Source.remove(refresh_timer_id);
            refresh_timer_id = 0;
        }
        if (monitor != null) {
            monitor.cancel();
            monitor = null;
        }
        if (panel_btn != null) {
            context.remove_clock_suffix_widget(panel_btn);
            panel_btn = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;
        var lbl = new Label(_("Shows the temperature of the place selected in Weather, with its units. Click it to open Weather there."));
        lbl.wrap = true;
        lbl.xalign = 0;
        box.append(lbl);
        if (summary != "") {
            var weather_lbl = new Label(summary);
            weather_lbl.xalign = 0;
            weather_lbl.add_css_class("dim-label");
            box.append(weather_lbl);
        }
        return box;
    }

    private void open_weather() {
        if (place_id != "") call_app("show-place", new Variant.string(place_id));
        else call_app("add-place", null);
    }

    private void call_app(string action, Variant? parameter) {
        var parameters = new VariantBuilder(new VariantType("av"));
        if (parameter != null) parameters.add("v", parameter);
        var platform = new VariantBuilder(new VariantType("a{sv}"));
        Bus.get.begin(BusType.SESSION, null, (o, r) => {
            try {
                var bus = Bus.get.end(r);
                bus.call.begin("dev.sinty.weather", "/dev/sinty/weather", "org.freedesktop.Application", "ActivateAction",
                    new Variant("(s@av@a{sv})", action, parameters.end(), platform.end()),
                    null, DBusCallFlags.NONE, 30000, null, (obj, res) => {
                        try {
                            bus.call.end(res);
                        } catch (Error e) {
                            warning("weather: %s", e.message);
                        }
                    });
            } catch (Error e) {
                warning("weather: %s", e.message);
            }
        });
    }

    private Json.Object? read_selected(out bool stale) {
        stale = true;
        Json.Object root;
        try {
            string text;
            FileUtils.get_contents(snapshot_path(), out text);
            var parser = new Json.Parser();
            parser.load_from_data(text);
            var node = parser.get_root();
            if (node == null || node.get_node_type() != Json.NodeType.OBJECT) return null;
            root = node.get_object();
        } catch (Error e) {
            return null;
        }
        if (!root.has_member("places")) return null;
        var places = root.get_array_member("places");
        if (places.get_length() == 0) {
            stale = false;
            return null;
        }
        string selected = root.get_string_member_with_default("selected", "");
        Json.Object? found = null;
        foreach (var n in places.get_elements()) {
            var obj = n.get_object();
            if (found == null || obj.get_string_member_with_default("id", "") == selected) found = obj;
            if (obj.get_string_member_with_default("id", "") == selected) break;
        }
        int64 fetched = found.get_int_member_with_default("fetched_at", 0);
        stale = get_real_time() / 1000000 - fetched > STALE_SECONDS;
        return found;
    }

    private void update_display() {
        if (panel_btn == null) return;
        bool stale;
        var place = read_selected(out stale);
        if (stale) {
            int64 now = get_real_time() / 1000000;
            if (now - last_request > 900) {
                last_request = now;
                call_app("refresh-snapshot", null);
            }
        }
        if (place == null || !place.has_member("temperature")) {
            panel_btn.visible = false;
            place_id = place != null ? place.get_string_member_with_default("id", "") : "";
            summary = "";
            return;
        }
        place_id = place.get_string_member_with_default("id", "");
        string temperature = place.get_string_member_with_default("temperature", "");
        string condition = place.get_string_member_with_default("condition", "");
        string name = place.get_string_member_with_default("name", "");
        weather_label.label = temperature;
        weather_icon.icon_name = place.get_string_member_with_default("icon", "weather-few-clouds") + "-symbolic";
        summary = "%s: %s %s".printf(name, temperature, condition);
        if (place.has_member("high")) {
            summary = _("%s, high %s, low %s").printf(summary, place.get_string_member("high"), place.get_string_member("low"));
        }
        panel_btn.tooltip_text = summary;
        panel_btn.visible = true;
    }
}
