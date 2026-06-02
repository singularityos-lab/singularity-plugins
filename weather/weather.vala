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
    private PluginContext context;
    private Button panel_btn;
    private Label weather_label;
    private uint refresh_timer_id = 0;

    // Cache: refresh every 30 minutes
    private int64 last_fetch_time = 0;
    private string cached_weather = "";
    private const int CACHE_SECONDS = 1800;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        panel_btn = new Button();
        panel_btn.add_css_class("flat");
        panel_btn.add_css_class("panel-button");
        panel_btn.tooltip_text = "Weather (click to refresh)";
        panel_btn.clicked.connect(() => {
            last_fetch_time = 0; // Force refresh
            fetch_weather.begin();
        });

        var btn_box = new Box(Orientation.HORIZONTAL, 4);
        btn_box.valign = Align.CENTER;
        var icon = new Image.from_icon_name("weather-clear-symbolic");
        icon.pixel_size = 14;
        btn_box.append(icon);
        weather_label = new Label("...");
        weather_label.add_css_class("caption");
        btn_box.append(weather_label);
        panel_btn.set_child(btn_box);

        context.add_clock_suffix_widget(panel_btn);

        fetch_weather.begin();
        // Refresh every 30 minutes
        refresh_timer_id = Timeout.add_seconds(CACHE_SECONDS, () => {
            fetch_weather.begin();
            return true;
        });
    }

    public void deactivate() {
        if (refresh_timer_id != 0) {
            Source.remove(refresh_timer_id);
            refresh_timer_id = 0;
        }
        if (panel_btn != null) {
            context.remove_panel_widget(panel_btn);
            panel_btn = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;
        var lbl = new Label("Fetches weather from wttr.in. Caches for 30 minutes. Click the panel button to refresh.");
        lbl.wrap = true;
        lbl.halign = Align.START;
        box.append(lbl);
        if (cached_weather != "") {
            var weather_lbl = new Label("Current: " + cached_weather);
            weather_lbl.halign = Align.START;
            box.append(weather_lbl);
        }
        return box;
    }

    private async void fetch_weather() {
        int64 now = GLib.get_monotonic_time() / 1000000;
        if (cached_weather != "" && (now - last_fetch_time) < CACHE_SECONDS) {
            update_display(cached_weather);
            return;
        }

        // Use GLib.File to fetch from wttr.in (no API key needed)
        // Format: condition + temperature
        try {
            var file = GLib.File.new_for_uri("https://wttr.in/?format=%C+%t");
            var stream = yield file.read_async(Priority.LOW, null);
            var data_stream = new DataInputStream(stream);
            string? line = yield data_stream.read_line_async(Priority.LOW, null);
            if (line != null) {
                string weather = line.strip();
                // Sanitize: remove degree sign weirdness, keep ASCII+degree
                weather = weather.replace("+", "").replace("°F", "°F").replace("°C", "°C");
                // Trim to reasonable length
                if (weather.char_count() > 30) {
                    weather = weather.substring(0, weather.index_of_nth_char(30)) + "…";
                }
                cached_weather = weather;
                last_fetch_time = now;
                update_display(weather);
            }
        } catch (Error e) {
            // Network not available or wttr.in down - show cached or hide
            if (cached_weather == "") {
                if (weather_label != null) weather_label.label = "N/A";
            }
        }
    }

    private void update_display(string weather) {
        if (weather_label == null) return;
        // Map condition keywords to icon names
        string icon_name = condition_to_icon(weather);
        // Update the icon in the button
        var box = panel_btn.get_child() as Box;
        if (box != null) {
            var child = box.get_first_child();
            if (child is Image) {
                ((Image) child).icon_name = icon_name;
            }
        }
        // Show just temperature part if present
        string display = weather;
        // Extract temperature (last word that contains °)
        var parts = weather.split(" ");
        foreach (var p in parts) {
            if ("°" in p) { display = p; break; }
        }
        weather_label.label = display;
        panel_btn.tooltip_text = "Weather: " + weather + " (click to refresh)";
    }

    private string condition_to_icon(string condition) {
        string lower = condition.down();
        if ("clear" in lower || "sunny" in lower) return "weather-clear-symbolic";
        if ("cloud" in lower || "overcast" in lower) return "weather-overcast-symbolic";
        if ("partly" in lower) return "weather-few-clouds-symbolic";
        if ("rain" in lower || "drizzle" in lower) return "weather-showers-symbolic";
        if ("snow" in lower || "sleet" in lower) return "weather-snow-symbolic";
        if ("storm" in lower || "thunder" in lower) return "weather-storm-symbolic";
        if ("fog" in lower || "mist" in lower) return "weather-fog-symbolic";
        if ("wind" in lower) return "weather-windy-symbolic";
        return "weather-clear-symbolic";
    }
}
