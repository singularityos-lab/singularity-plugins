using GLib;
using Gee;

namespace Singularity.Plugins.TrayIcons {

    // Server-side implementation of the StatusNotifierWatcher.
    // Apps register their tray items here; we track them and emit signals.
    public class Watcher : Object, StatusNotifierWatcher {
        private HashSet<string> hosts = new HashSet<string>();
        private HashMap<string, string> items = new HashMap<string, string>();

        public string[] registered_status_notifier_items {
            owned get {
                string[] res = {};
                foreach (var key in items.keys) res += key;
                return res;
            }
        }

        public bool is_status_notifier_host_registered {
            get { return hosts.size > 0; }
        }

        public int protocol_version { get { return 0; } }

        // Called by apps to register. The raw D-Bus sender is resolved
        // by the plugin via a connection filter before this is invoked.

        public void register_status_notifier_item(string service) throws IOError {
            string bus_name = service;
            string obj_path = "/StatusNotifierItem";

            if ("\n" in service) {
                var parts = service.split("\n", 2);
                bus_name = parts[0];
                obj_path = parts[1];
            } else if (service.has_prefix("/")) {
                // Path-only without sender - cannot handle, skip.
                return;
            }

            string key = bus_name + "\n" + obj_path;
            if (items.has_key(key)) return;

            items[key] = bus_name;
            status_notifier_item_registered(key);

            Bus.watch_name(BusType.SESSION, bus_name, BusNameWatcherFlags.NONE,
                null,
                () => {
                    if (items.has_key(key)) {
                        items.unset(key);
                        status_notifier_item_unregistered(key);
                    }
                }
            );
        }

        public void register_status_notifier_host(string service) throws IOError {
            if (hosts.contains(service)) return;
            hosts.add(service);
            status_notifier_host_registered();

            Bus.watch_name(BusType.SESSION, service, BusNameWatcherFlags.NONE,
                null, () => { hosts.remove(service); }
            );
        }
    }
}
