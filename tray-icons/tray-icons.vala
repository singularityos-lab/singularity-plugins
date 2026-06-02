using Gtk;
using GLib;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(
        typeof(Singularity.Plugin),
        typeof(Singularity.Plugins.TrayIcons.TrayIconsPlugin)
    );
}

namespace Singularity.Plugins.TrayIcons {

    public class TrayIconsPlugin : Object, Singularity.Plugin {
        private PluginContext? context = null;
        private Box? container = null;
        private Watcher? watcher = null;
        private uint watcher_bus_id = 0;
        private uint watcher_obj_id = 0;
        private DBusConnection? connection = null;
        private uint filter_id = 0;
        private ulong reg_handler = 0;
        private ulong unreg_handler = 0;

        // Active items keyed by "busname\nobjpath"
        private HashTable<string, TrayItem> items =
            new HashTable<string, TrayItem>(str_hash, str_equal);

        public void activate(PluginContext ctx) {
            context = ctx;
            container = new Box(Orientation.HORIZONTAL, 2);
            container.add_css_class("tray-icons");
            container.valign = Align.CENTER;

            setup_dbus.begin();

            context.add_panel_widget(container, Align.END);
        }

        public void deactivate() {
            // Tear down D-Bus registrations
            if (connection != null) {
                if (watcher_obj_id != 0) {
                    connection.unregister_object(watcher_obj_id);
                    watcher_obj_id = 0;
                }
                if (filter_id != 0) {
                    connection.remove_filter(filter_id);
                    filter_id = 0;
                }
            }
            if (watcher_bus_id != 0) {
                Bus.unown_name(watcher_bus_id);
                watcher_bus_id = 0;
            }

            // Disconnect watcher signals
            if (watcher != null) {
                if (reg_handler != 0) watcher.disconnect(reg_handler);
                if (unreg_handler != 0) watcher.disconnect(unreg_handler);
                reg_handler = 0;
                unreg_handler = 0;
                watcher = null;
            }

            // Remove items
            items.remove_all();

            // Remove panel widget
            if (container != null && context != null)
                context.remove_panel_widget(container);
            container = null;
            connection = null;
            context = null;
        }

        public Gtk.Widget? get_settings_widget() {
            return new Label("Shows system tray (StatusNotifierItem) icons.");
        }

        // ── D-Bus setup ────────────────────────────────────────────────────

        private async void setup_dbus() {
            try {
                connection = yield Bus.get(BusType.SESSION, null);
            } catch (Error e) {
                warning("TrayIcons: cannot get session bus: %s", e.message);
                return;
            }

            watcher = new Watcher();

            // Install a message filter to inject the D-Bus sender into
            // RegisterStatusNotifierItem calls (Vala D-Bus server doesn't
            // expose the sender to the method implementation).
            filter_id = connection.add_filter(on_dbus_filter);

            // Export watcher object
            try {
                watcher_obj_id = connection.register_object<StatusNotifierWatcher>(
                    "/StatusNotifierWatcher", watcher);
            } catch (Error e) {
                warning("TrayIcons: register_object failed: %s", e.message);
                return;
            }

            // Own the watcher bus name
            watcher_bus_id = Bus.own_name_on_connection(connection,
                "org.kde.StatusNotifierWatcher",
                BusNameOwnerFlags.NONE,
                () => {
                    // Name acquired - register ourselves as host
                    try {
                        watcher.register_status_notifier_host(
                            connection.unique_name);
                    } catch (Error e) {
                        warning("TrayIcons: host registration: %s", e.message);
                    }
                },
                () => {
                    warning("TrayIcons: lost StatusNotifierWatcher name");
                }
            );

            // React to item registration/unregistration
            reg_handler = watcher.status_notifier_item_registered.connect(
                on_item_registered);
            unreg_handler = watcher.status_notifier_item_unregistered.connect(
                on_item_unregistered);
        }

        // ── Message filter ─────────────────────────────────────────────────
        // Rewrites the "service" arg of RegisterStatusNotifierItem to include
        // the D-Bus sender, so our watcher can track the correct bus name.

        private GLib.DBusMessage? on_dbus_filter(DBusConnection conn,
                owned DBusMessage msg, bool incoming) {
            if (!incoming) return msg;
            if (msg.get_message_type() != DBusMessageType.METHOD_CALL) return msg;
            if (msg.get_member() != "RegisterStatusNotifierItem") return msg;
            if (msg.get_interface() != "org.kde.StatusNotifierWatcher") return msg;

            string? sender = msg.get_sender();
            if (sender == null) return msg;

            var body = msg.get_body();
            if (body == null) return msg;

            string service;
            body.get("(s)", out service);

            // If service is just a path like "/StatusNotifierItem",
            // prepend the sender bus name so we know WHO registered it.
            string new_service;
            if (service.has_prefix("/")) {
                new_service = sender + "\n" + service;
            } else {
                new_service = service + "\n/StatusNotifierItem";
            }

            try {
                var new_msg = msg.copy();
                new_msg.set_body(new Variant("(s)", new_service));
                return new_msg;
            } catch (Error e) {
                warning("TrayIcons: msg copy failed: %s", e.message);
                return msg;
            }
        }

        // ── Item lifecycle ─────────────────────────────────────────────────

        private void on_item_registered(string key) {
            if (items.contains(key)) return;
            if (container == null) return;

            var parts = key.split("\n", 2);
            if (parts.length < 2) return;

            var item = new TrayItem(parts[0], parts[1]);
            items.insert(key, item);
            container.append(item.widget);
        }

        private void on_item_unregistered(string key) {
            var item = items.lookup(key);
            if (item == null) return;
            if (container != null)
                container.remove(item.widget);
            items.remove(key);
        }
    }
}
