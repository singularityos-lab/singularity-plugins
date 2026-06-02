using Gtk;
using GLib;

namespace Singularity.Plugins.TrayIcons {

    // A single tray icon backed by a raw GLib.DBusProxy.
    // ALL property access uses get_cached_property() - never blocks.
    public class TrayItem : Object {
        public string bus_name { get; private set; }
        public string object_path { get; private set; }
        public Button widget { get; private set; }

        private GLib.DBusProxy? proxy = null;
        private Image icon_widget;
        private DBusMenuClient? menu_client = null;

        public TrayItem(string bus_name, string object_path) {
            this.bus_name = bus_name;
            this.object_path = object_path;

            widget = new Button();
            widget.add_css_class("flat");
            widget.add_css_class("tray-icon");
            icon_widget = new Image();
            icon_widget.pixel_size = 16;
            icon_widget.icon_name = "image-loading-symbolic";
            widget.set_child(icon_widget);

            widget.clicked.connect(on_activate);
            var right_click = new GestureClick();
            right_click.button = 3;
            right_click.pressed.connect(on_right_click);
            widget.add_controller(right_click);

            init_proxy.begin();
        }

        private async void init_proxy() {
            try {
                proxy = yield new GLib.DBusProxy.for_bus(
                    BusType.SESSION,
                    DBusProxyFlags.GET_INVALIDATED_PROPERTIES,
                    null,
                    bus_name,
                    object_path,
                    "org.kde.StatusNotifierItem",
                    null
                );

                // React to property changes (icon updates, title changes, etc.)
                proxy.g_properties_changed.connect(on_properties_changed);

                // React to explicit update signals from the item
                proxy.g_signal.connect(on_dbus_signal);

                update_icon();
                update_tooltip();
                init_menu_client();
            } catch (Error e) {
                warning("TrayItem: proxy failed for %s %s: %s",
                        bus_name, object_path, e.message);
                icon_widget.icon_name = "image-missing-symbolic";
            }
        }

        private void on_properties_changed(Variant changed, string[] invalidated) {
            bool need_icon = false;
            bool need_tooltip = false;

            var iter = new VariantIter(changed);
            string key;
            Variant val;
            while (iter.next("{sv}", out key, out val)) {
                if (key == "IconName" || key == "IconPixmap" ||
                    key == "AttentionIconName" || key == "OverlayIconName")
                    need_icon = true;
                if (key == "Title" || key == "ToolTip")
                    need_tooltip = true;
            }
            foreach (var inv in invalidated) {
                if (inv == "IconName" || inv == "IconPixmap") need_icon = true;
                if (inv == "Title" || inv == "ToolTip") need_tooltip = true;
            }

            if (need_icon) update_icon();
            if (need_tooltip) update_tooltip();
        }

        private void on_dbus_signal(string? sender, string signal_name, Variant parameters) {
            switch (signal_name) {
                case "NewIcon":
                case "NewAttentionIcon":
                case "NewOverlayIcon":
                    update_icon();
                    break;
                case "NewTitle":
                case "NewToolTip":
                    update_tooltip();
                    break;
            }
        }

        // ── Icon (all reads from cache, never blocks) ──────────────────────

        private void update_icon() {
            if (proxy == null) return;

            // 1. Try named icon
            string? name = get_string_prop("IconName");
            if (name != null && name.length > 0) {
                icon_widget.paintable = null;
                icon_widget.icon_name = name;
                return;
            }

            // 2. Try pixmap from cache
            var pixmap_v = proxy.get_cached_property("IconPixmap");
            if (pixmap_v != null && try_set_pixmap(pixmap_v))
                return;

            // 3. Fallback
            icon_widget.paintable = null;
            icon_widget.icon_name = "image-missing-symbolic";
        }

        private bool try_set_pixmap(Variant pixmap_v) {
            // Type: a(iiay) - array of (width, height, ARGB data)
            if (!pixmap_v.get_type().is_array()) return false;

            var n = pixmap_v.n_children();
            if (n == 0) return false;

            // Pick the best size (closest to 22px, prefer >= 22)
            int best_idx = 0;
            int best_w = 0;
            for (int i = 0; i < (int)n; i++) {
                var entry = pixmap_v.get_child_value(i);
                if (entry.n_children() < 3) continue;
                int w = entry.get_child_value(0).get_int32();
                if (best_w == 0 || (w >= 22 && w < best_w) || (best_w < 22 && w > best_w)) {
                    best_w = w;
                    best_idx = i;
                }
            }

            var entry = pixmap_v.get_child_value(best_idx);
            if (entry.n_children() < 3) return false;

            int w = entry.get_child_value(0).get_int32();
            int h = entry.get_child_value(1).get_int32();
            var data_v = entry.get_child_value(2);

            if (w <= 0 || h <= 0) return false;

            // Data is big-endian ARGB32; convert to native BGRA for Cairo/GDK
            // For variant type `ay`, get_data() points directly at the raw bytes.
            size_t data_size = data_v.get_size();
            if ((int)data_size < w * h * 4) return false;
            unowned uint8* raw = (uint8*) data_v.get_data();

            uint8[] bgra = new uint8[w * h * 4];
            for (int i = 0; i < w * h; i++) {
                uint8 a = raw[i * 4 + 0];
                uint8 r = raw[i * 4 + 1];
                uint8 g = raw[i * 4 + 2];
                uint8 b = raw[i * 4 + 3];
                bgra[i * 4 + 0] = b;
                bgra[i * 4 + 1] = g;
                bgra[i * 4 + 2] = r;
                bgra[i * 4 + 3] = a;
            }

            var bytes = new GLib.Bytes(bgra);
            var texture = new Gdk.MemoryTexture(w, h,
                Gdk.MemoryFormat.B8G8R8A8, bytes, w * 4);
            icon_widget.icon_name = null;
            icon_widget.paintable = texture;
            return true;
        }

        // ── Tooltip ────────────────────────────────────────────────────────

        private void update_tooltip() {
            if (proxy == null) return;

            string? tip = null;

            // ToolTip: type varies (string or KDE struct (sa(iiay)ss))
            var v = proxy.get_cached_property("ToolTip");
            if (v != null) {
                if (v.is_of_type(VariantType.STRING))
                    tip = v.get_string();
                else if (v.get_type().is_tuple()) {
                    // Walk children, pick last non-empty string
                    for (int i = (int)v.n_children() - 1; i >= 0; i--) {
                        var child = v.get_child_value(i);
                        if (child.is_of_type(VariantType.STRING)) {
                            string s = child.get_string();
                            if (s.length > 0) { tip = s; break; }
                        }
                    }
                }
            }

            if (tip == null || tip.length == 0)
                tip = get_string_prop("Title");

            widget.tooltip_text = tip ?? "";
        }

        // ── Actions (async, non-blocking) ──────────────────────────────────

        private void init_menu_client() {
            if (proxy == null) return;
            var menu_v = proxy.get_cached_property("Menu");
            if (menu_v == null) return;
            if (!menu_v.is_of_type(VariantType.OBJECT_PATH)) return;
            string menu_path = menu_v.get_string();
            if (menu_path.length > 0 && menu_path != "/NO_DBUSMENU") {
                menu_client = new DBusMenuClient(bus_name, menu_path);
            }
        }

        private void on_activate() {
            if (proxy == null) return;
            int x = 0, y = 0;
            get_screen_coords(out x, out y);
            proxy.call.begin("Activate",
                new Variant("(ii)", x, y),
                DBusCallFlags.NONE, 1000, null,
                (obj, res) => {
                    try { proxy.call.end(res); }
                    catch (Error e) { /* many items don't implement Activate */ }
                }
            );
        }

        private void on_right_click(int n_press, double ex, double ey) {
            if (proxy == null) return;

            // Prefer native menu via dbusmenu protocol
            if (menu_client != null && menu_client.is_ready()) {
                menu_client.popup_at(widget);
                return;
            }

            // Fallback: ask the app to show its own menu
            int x = 0, y = 0;
            get_screen_coords(out x, out y);
            proxy.call.begin("ContextMenu",
                new Variant("(ii)", x, y),
                DBusCallFlags.NONE, 1000, null,
                (obj, res) => {
                    try { proxy.call.end(res); }
                    catch (Error e) { /* many items don't implement ContextMenu */ }
                }
            );
        }

        // ── Helpers ────────────────────────────────────────────────────────

        private string? get_string_prop(string name) {
            var v = proxy.get_cached_property(name);
            if (v == null) return null;
            if (v.is_of_type(VariantType.STRING))
                return v.get_string();
            return null;
        }

        private void get_screen_coords(out int x, out int y) {
            x = 0; y = 0;
            var native = widget.get_native();
            if (native == null) return;
            double nx, ny, sx, sy;
            widget.translate_coordinates(native as Gtk.Widget, 0, 0, out nx, out ny);
            native.get_surface_transform(out sx, out sy);
            x = (int)(nx + sx);
            y = (int)(ny + sy);
        }
    }
}
