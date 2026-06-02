using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(CaffeinePlugin));
}

public class CaffeinePlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Button panel_btn;
    private bool active = false;
    private uint inhibit_cookie = 0;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        panel_btn = new Button();
        panel_btn.add_css_class("flat");
        panel_btn.add_css_class("panel-button");
        panel_btn.icon_name = "applications-games-symbolic";
        panel_btn.tooltip_text = "Caffeine: Keep screen awake";
        panel_btn.clicked.connect(toggle);

        context.add_panel_widget(panel_btn, Align.END);
    }

    public void deactivate() {
        if (active) disable_caffeine();
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
        var lbl = new Label("Prevents the screen from sleeping when enabled.");
        lbl.wrap = true;
        lbl.halign = Align.START;
        box.append(lbl);
        return box;
    }

    private void toggle() {
        if (active) {
            disable_caffeine();
        } else {
            enable_caffeine();
        }
    }

    private void enable_caffeine() {
        // Use org.gnome.SessionManager Inhibit with flag 8 (inhibit idle/suspend)
        inhibit_via_dbus.begin();
    }

    private async void inhibit_via_dbus() {
        try {
            var conn = yield Bus.get(BusType.SESSION);
            var result = yield conn.call(
                "org.gnome.SessionManager",
                "/org/gnome/SessionManager",
                "org.gnome.SessionManager",
                "Inhibit",
                new Variant("(susu)",
                    "dev.sinty.desktop",
                    (uint32) 0,
                    "Caffeine mode active",
                    (uint32) 8),  // flag 8 = inhibit idle
                new VariantType("(u)"),
                DBusCallFlags.NONE,
                -1,
                null
            );
            result.get("(u)", out inhibit_cookie);
            active = true;
            update_button();
        } catch (Error e) {
            warning("Caffeine: Failed to inhibit idle: %s", e.message);
            // Fall back: just update state visually
            active = true;
            update_button();
        }
    }

    private void disable_caffeine() {
        if (inhibit_cookie != 0) {
            uninhibit_via_dbus.begin();
        } else {
            active = false;
            update_button();
        }
    }

    private async void uninhibit_via_dbus() {
        try {
            var conn = yield Bus.get(BusType.SESSION);
            yield conn.call(
                "org.gnome.SessionManager",
                "/org/gnome/SessionManager",
                "org.gnome.SessionManager",
                "Uninhibit",
                new Variant("(u)", inhibit_cookie),
                null,
                DBusCallFlags.NONE,
                -1,
                null
            );
        } catch (Error e) {
            warning("Caffeine: Failed to uninhibit: %s", e.message);
        }
        inhibit_cookie = 0;
        active = false;
        update_button();
    }

    private void update_button() {
        if (panel_btn == null) return;
        panel_btn.icon_name = active ? "emblem-ok-symbolic" : "applications-games-symbolic";
        if (active) {
            panel_btn.add_css_class("caffeine-active");
            panel_btn.tooltip_text = "Caffeine: Screen awake (click to disable)";
        } else {
            panel_btn.remove_css_class("caffeine-active");
            panel_btn.tooltip_text = "Caffeine: Keep screen awake";
        }
    }
}
