// D-Bus interface for the StatusNotifierWatcher that WE implement (server-side).
// We do NOT define a StatusNotifierItem interface - items are accessed via
// raw GLib.DBusProxy to avoid synchronous property getters.

namespace Singularity.Plugins.TrayIcons {

    [DBus (name = "org.kde.StatusNotifierWatcher")]
    public interface StatusNotifierWatcher : Object {
        public abstract void register_status_notifier_item(string service) throws IOError;
        public abstract void register_status_notifier_host(string service) throws IOError;
        public abstract string[] registered_status_notifier_items { owned get; }
        public abstract bool is_status_notifier_host_registered { get; }
        public abstract int protocol_version { get; }

        [DBus (name = "StatusNotifierItemRegistered")]
        public signal void status_notifier_item_registered(string service);
        [DBus (name = "StatusNotifierItemUnregistered")]
        public signal void status_notifier_item_unregistered(string service);
        [DBus (name = "StatusNotifierHostRegistered")]
        public signal void status_notifier_host_registered();
        [DBus (name = "StatusNotifierHostUnregistered")]
        public signal void status_notifier_host_unregistered();
    }
}
