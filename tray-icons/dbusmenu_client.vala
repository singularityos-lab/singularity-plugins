using Gtk;
using GLib;

namespace Singularity.Plugins.TrayIcons {

    // Client for the com.canonical.dbusmenu protocol.
    // Fetches menu layouts from apps and builds native Singularity.Widgets.ContextMenu widgets.
    // All D-Bus calls are async - never blocks the main loop.
    public class DBusMenuClient : Object {
        private string bus_name;
        private string menu_path;
        private GLib.DBusProxy? menu_proxy = null;
        private bool ready = false;

        public DBusMenuClient(string bus_name, string menu_path) {
            this.bus_name = bus_name;
            this.menu_path = menu_path;
            init_proxy.begin();
        }

        private async void init_proxy() {
            try {
                menu_proxy = yield new GLib.DBusProxy.for_bus(
                    BusType.SESSION,
                    DBusProxyFlags.NONE,
                    null,
                    bus_name,
                    menu_path,
                    "com.canonical.dbusmenu",
                    null
                );
                ready = true;
            } catch (Error e) {
                warning("DBusMenuClient: proxy init failed: %s", e.message);
            }
        }

        public bool is_ready() { return ready && menu_proxy != null; }

        // Fetches the layout and shows a ContextMenu at the given widget.

        public void popup_at(Widget anchor) {
            if (!ready || menu_proxy == null) return;
            fetch_and_show.begin(anchor);
        }

        private async void fetch_and_show(Widget anchor) {
            try {
                // GetLayout(parentId, recursionDepth, propertyNames)
                var builder = new VariantBuilder(new VariantType("as"));
                var result = yield menu_proxy.call(
                    "GetLayout",
                    new Variant("(ii@as)", 0, -1, builder.end()),
                    DBusCallFlags.NONE, 2000, null
                );

                // result: (u(ia{sv}av))
                if (!result.get_type().is_tuple() || result.n_children() < 2)
                    return;
                var layout_v = result.get_child_value(1);
                if (!layout_v.get_type().is_tuple() || layout_v.n_children() < 3)
                    return;
                var menu = new Singularity.Widgets.ContextMenu(anchor);
                menu.position = PositionType.TOP;
                populate_menu(layout_v, menu);
                menu.popup();
            } catch (Error e) {
                warning("DBusMenuClient: GetLayout failed: %s", e.message);
            }
        }

        private void populate_menu(Variant node, Singularity.Widgets.ContextMenu menu) {
            if (node.n_children() < 3) return;

            var children_v = node.get_child_value(2); // av
            bool last_was_separator = true; // suppress leading separators

            for (size_t i = 0; i < children_v.n_children(); i++) {
                var child_wrapped = children_v.get_child_value(i);
                if (!child_wrapped.is_of_type(VariantType.VARIANT)) continue;
                var child = child_wrapped.get_variant();
                if (!child.get_type().is_tuple() || child.n_children() < 3) continue;

                var id_v = child.get_child_value(0);
                if (!id_v.is_of_type(VariantType.INT32)) continue;
                int id = id_v.get_int32();
                var props = child.get_child_value(1);

                string? label = get_prop_string(props, "label");
                string? item_type = get_prop_string(props, "type");
                string? icon_name = get_prop_string(props, "icon-name");
                bool visible = get_prop_bool(props, "visible", true);
                bool enabled = get_prop_bool(props, "enabled", true);

                if (!visible) continue;

                if (item_type == "separator") {
                    if (!last_was_separator) {
                        menu.add_separator();
                        last_was_separator = true;
                    }
                    continue;
                }

                if (label == null || label.length == 0) continue;

                // Strip mnemonics
                label = label.replace("_", "");

                if (!enabled) continue;

                int captured_id = id;
                menu.add_item(label, icon_name, () => {
                    activate_item(captured_id);
                });
                last_was_separator = false;
            }
        }

        // Sends "Event" to activate a menu item by ID (async, non-blocking).

        public void activate_item(int id) {
            if (menu_proxy == null) return;
            uint32 timestamp = (uint32)(GLib.get_real_time() / 1000);
            menu_proxy.call.begin(
                "Event",
                new Variant("(isvu)", id, "clicked",
                    new Variant.int32(0), timestamp),
                DBusCallFlags.NONE, 1000, null,
                (obj, res) => {
                    try { menu_proxy.call.end(res); }
                    catch (Error e) { /* ignore */ }
                }
            );
        }

        private string? get_prop_string(Variant props, string key) {
            var iter = new VariantIter(props);
            string k; Variant v;
            while (iter.next("{sv}", out k, out v)) {
                if (k == key && v.is_of_type(VariantType.STRING))
                    return v.get_string();
            }
            return null;
        }

        private bool get_prop_bool(Variant props, string key, bool default_val) {
            var iter = new VariantIter(props);
            string k; Variant v;
            while (iter.next("{sv}", out k, out v)) {
                if (k == key) {
                    if (v.is_of_type(VariantType.BOOLEAN)) return v.get_boolean();
                    if (v.is_of_type(VariantType.INT32)) return v.get_int32() != 0;
                }
            }
            return default_val;
        }
    }
}
