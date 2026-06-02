using Gtk;
using GLib;
using Singularity;
using Peas;
using GtkLayerShell;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(ExampleDockPlugin));
}

namespace ExampleDock {

    /**
     * Demonstrates ShellSurfaceProvider in SURFACE_OWNERSHIP mode: when this
     * plugin is enabled the shell suppresses its built-in dock and yields the
     * bottom layer entirely to us. We create our own layer-shell surface, a
     * minimal launcher pill, to prove the swap works end to end.
     *
     * NB: this intentionally only uses libsingularity + GLib (no shell
     * internals like AppSystem) - that's the "a swapped component is only as
     * useful as the public API it can reach" caveat in action.
     */
    public class Provider : Object, ShellSurfaceProvider {
        public ShellRole role { get { return ShellRole.DOCK; } }
        public ShellSurfaceMode mode { get { return ShellSurfaceMode.SURFACE_OWNERSHIP; } }
        // Beat the built-in (which doesn't register a provider at all, so any
        // positive priority wins the role).
        public int priority { get { return 100; } }

        private Gee.HashMap<Gdk.Monitor, Gtk.Window> _windows =
            new Gee.HashMap<Gdk.Monitor, Gtk.Window>();

        public void surface_activate(Gdk.Monitor monitor) {
            if (_windows.has_key(monitor)) return;
            var win = new Gtk.Window();
            win.add_css_class("example-dock");

            GtkLayerShell.init_for_window(win);
            GtkLayerShell.set_monitor(win, monitor);
            GtkLayerShell.set_layer(win, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_anchor(win, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_margin(win, GtkLayerShell.Edge.BOTTOM, 12);
            GtkLayerShell.set_exclusive_zone(win, 0);

            var pill = new Gtk.Box(Orientation.HORIZONTAL, 8);
            pill.add_css_class("example-dock-pill");
            pill.halign = Align.CENTER;
            pill.margin_start = 14; pill.margin_end = 14;
            pill.margin_top = 8;   pill.margin_bottom = 8;

            // A handful of common apps; launch via their .desktop id.
            string[] ids = {
                "dev.sinty.files.desktop", "dev.sinty.browser.desktop",
                "dev.sinty.music.desktop", "dev.sinty.edit.desktop",
                "dev.sinty.calculator.desktop"
            };
            foreach (var id in ids) {
                var info = new GLib.DesktopAppInfo(id);
                if (info == null) continue;
                var btn = new Gtk.Button();
                btn.add_css_class("example-dock-item");
                btn.has_frame = false;
                var img = new Gtk.Image();
                img.pixel_size = 44;
                img.gicon = info.get_icon();
                btn.set_child(img);
                btn.tooltip_text = info.get_display_name();
                var captured = info;
                btn.clicked.connect(() => {
                    try { captured.launch(null, null); } catch (Error e) {}
                });
                pill.append(btn);
            }

            win.set_child(pill);
            win.present();
            _windows[monitor] = win;
        }

        public void surface_deactivate(Gdk.Monitor monitor) {
            if (_windows.has_key(monitor)) {
                _windows[monitor].destroy();
                _windows.unset(monitor);
            }
        }
    }
}

public class ExampleDockPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private ExampleDock.Provider? provider;
    private Gtk.CssProvider? css;

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        load_css();
        provider = new ExampleDock.Provider();
        // Registering triggers the shell's live re-arbitration, which
        // suppresses the built-in dock and calls our surface_activate(). We
        // must NOT self-activate here or we'd briefly show two docks.
        context.add_shell_surface_provider(provider);
    }

    public void deactivate() {
        if (provider != null) {
            var display = Gdk.Display.get_default();
            if (display != null) {
                for (uint i = 0; i < display.get_monitors().get_n_items(); i++) {
                    var mon = display.get_monitors().get_item(i) as Gdk.Monitor;
                    if (mon != null) provider.surface_deactivate(mon);
                }
            }
            context.remove_shell_surface_provider(provider);
            provider = null;
        }
        if (css != null) {
            var display = Gdk.Display.get_default();
            if (display != null)
                Gtk.StyleContext.remove_provider_for_display(display, css);
            css = null;
        }
    }

    private void load_css() {
        css = new Gtk.CssProvider();
        css.load_from_data((uint8[]) """
        .example-dock-pill {
            background: alpha(@window_bg_color, 0.75);
            border-radius: 22px;
            border: 1px solid alpha(@window_fg_color, 0.12);
            box-shadow: 0 6px 24px alpha(black, 0.35);
        }
        .example-dock-item { border-radius: 14px; padding: 6px; }
        .example-dock-item:hover { background: alpha(@window_fg_color, 0.12); }
        """.data);
        var display = Gdk.Display.get_default();
        if (display != null)
            Gtk.StyleContext.add_provider_for_display(
                display, css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
    }

    public Gtk.Widget? get_settings_widget() { return null; }
}
