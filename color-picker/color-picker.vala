using Gtk;
using Singularity;
using Peas;
using GLib;
using Gdk;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(ColorPickerPlugin));
}

public class ColorPickerPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Button panel_btn;
    private string _last_color = "";

    public void activate(PluginContext ctx) {
        this.context = ctx;

        panel_btn = new Button();
        panel_btn.add_css_class("flat");
        panel_btn.add_css_class("panel-button");
        panel_btn.icon_name = "color-select-symbolic";
        panel_btn.tooltip_text = "Pick a color from the screen";
        panel_btn.clicked.connect(start_pick);

        context.add_panel_widget(panel_btn, Align.END);
    }

    public void deactivate() {
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

        var lbl = new Label("Picks a color from the screen and copies its hex code to the clipboard.");
        lbl.wrap = true;
        lbl.halign = Align.START;
        box.append(lbl);

        if (_last_color != "") {
            var color_lbl = new Label("Last color: " + _last_color);
            color_lbl.halign = Align.START;
            box.append(color_lbl);
        }
        return box;
    }

    private void start_pick() {
        // Use grim + slurp pipeline to pick a color from any pixel on screen
        pick_color_async.begin();
    }

    private async void pick_color_async() {
        try {
            // Use slurp for region selection then grim to capture + ImageMagick to get color
            // Fallback: use a simple pixel-picking approach via subprocess
            string[] pick_cmd = {
                "/bin/sh", "-c",
                "grim -g \"$(slurp -p)\" -t ppm - 2>/dev/null | convert ppm:- -resize 1x1 txt:- 2>/dev/null | grep -oP '#[0-9A-Fa-f]{6}' | head -1"
            };

            string stdout_buf = "";
            string stderr_buf = "";
            int exit_status = 0;

            try {
                Process.spawn_sync(null, pick_cmd, null,
                    SpawnFlags.SEARCH_PATH, null,
                    out stdout_buf, out stderr_buf, out exit_status);
            } catch (SpawnError e) {
                // grim/slurp not available - try alternative
                context.notify("Color Picker", "Requires grim, slurp, and ImageMagick to be installed.");
                return;
            }

            string color = stdout_buf.strip();
            if (color.length >= 7 && color[0] == '#') {
                color = color.substring(0, 7).up();
                _last_color = color;
                var display = Gdk.Display.get_default();
                if (display != null) {
                    display.get_clipboard().set_text(color);
                }
                context.notify("Color Picked", "%s copied to clipboard".printf(color));
            } else {
                context.notify("Color Picker", "Could not pick a color (cancelled or error).");
            }
        } catch (Error e) {
            warning("Color picker error: %s", e.message);
        }
    }
}
