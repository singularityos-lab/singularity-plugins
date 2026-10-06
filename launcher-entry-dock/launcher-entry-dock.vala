using Gtk;
using Singularity;
using Peas;
using GLib;
using Gee;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(LauncherEntryDockPlugin));
}

/**
 * Listens to the Unity LauncherEntry DBus API and exposes any app that
 * advertises progress / count to our dock.
 *
 * Spec (community-standardized, used by GNOME, KDE, Pantheon, Unity, …):
 *   Bus name: anyone - sender of the signal
 *   Object path:   /com/canonical/Unity/LauncherEntry  (or anywhere)
 *   Interface:     com.canonical.Unity.LauncherEntry
 *   Signal:        Update (sa{sv})
 *     - s   "application://<desktop-id>.desktop"
 *     - a{sv}  optional keys: count (x), count-visible (b),
 *              progress (d, 0..1), progress-visible (b), urgent (b)
 *
 * Apps that emit this out-of-the-box include Nautilus, Thunderbird, Steam,
 * Mailspring, libdbusmenu-based apps, Telegram (unread badge), etc.
 */
namespace LauncherEntryDock {

    public class Extension : Object, Singularity.DockItemExtension {
        private EntryStore _store = new EntryStore();
        private HashMap<string, EntryState> _by_app;
        private DBusConnection? _conn;
        private uint _sub_id = 0;
        private uint _owner_sub_id = 0;
        private uint _save_id = 0;

        public Extension() {
            _by_app = _store.entries;
            try {
                _conn = Bus.get_sync(BusType.SESSION);
            } catch (Error e) {
                warning("launcher-entry-dock: bus get failed: %s", e.message);
                return;
            }
            _sub_id = _conn.signal_subscribe(
                null,
                "com.canonical.Unity.LauncherEntry",
                "Update",
                null,
                null,
                DBusSignalFlags.NONE,
                on_update);
            _owner_sub_id = _conn.signal_subscribe(
                "org.freedesktop.DBus",
                "org.freedesktop.DBus",
                "NameOwnerChanged",
                "/org/freedesktop/DBus",
                null,
                DBusSignalFlags.NONE,
                on_name_owner_changed);
            load_cache();
        }

        public void disconnect_dbus() {
            if (_conn != null && _sub_id != 0) {
                _conn.signal_unsubscribe(_sub_id);
                _sub_id = 0;
            }
            if (_conn != null && _owner_sub_id != 0) {
                _conn.signal_unsubscribe(_owner_sub_id);
                _owner_sub_id = 0;
            }
            if (_save_id != 0) {
                Source.remove(_save_id);
                _save_id = 0;
                save_cache();
            }
        }

        private static string cache_path() {
            return Path.build_filename(Environment.get_user_cache_dir(), "singularity", "launcher-entries.ini");
        }

        private void load_cache() {
            string data;
            try {
                if (!FileUtils.get_contents(cache_path(), out data)) return;
            } catch (Error e) {
                return;
            }
            _store.load_data(data);
            foreach (var state in _by_app.values) {
                if (state.app_owned && state.sender != null) check_sender_alive.begin(state.sender);
            }
            if (_by_app.size > 0) this.changed("");
        }

        private async void check_sender_alive(string sender) {
            if (_conn == null) return;
            try {
                var reply = yield _conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "NameHasOwner", new Variant("(s)", sender),
                    new VariantType("(b)"), DBusCallFlags.NONE, 2000, null);
                if (reply.get_child_value(0).get_boolean()) return;
            } catch (Error e) {
            }
            if (_store.sender_vanished(sender)) {
                schedule_save();
                this.changed("");
            }
        }

        private void schedule_save() {
            if (_save_id != 0) return;
            _save_id = Timeout.add_seconds(1, () => {
                _save_id = 0;
                save_cache();
                return Source.REMOVE;
            });
        }

        private void save_cache() {
            string path = cache_path();
            try {
                if (_by_app.size == 0) {
                    FileUtils.remove(path);
                    return;
                }
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, _store.to_data());
            } catch (Error e) {
                warning("launcher-entry-dock: cannot save %s: %s", path, e.message);
            }
        }

        private void on_name_owner_changed(DBusConnection conn, string? sender,
                                           string object_path, string interface_name,
                                           string signal_name, Variant parameters) {
            string name, old_owner, new_owner;
            parameters.get("(sss)", out name, out old_owner, out new_owner);
            if (!name.has_prefix(":") || new_owner != "") return;
            if (_store.sender_vanished(name)) {
                schedule_save();
                this.changed("");
            }
        }

        private async void resolve_ownership(EntryState state, string sender) {
            if (_conn == null || state.desktop_id == null) return;
            string? owner = null;
            try {
                var reply = yield _conn.call("org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "GetNameOwner", new Variant("(s)", state.desktop_id),
                    new VariantType("(s)"), DBusCallFlags.NONE, 2000, null);
                owner = reply.get_child_value(0).get_string();
            } catch (Error e) {
            }
            if (state.sender != sender) return;
            bool owned = owner != null && owner == sender;
            if (owned != state.app_owned) {
                state.app_owned = owned;
                schedule_save();
            }
        }

        private void on_update(DBusConnection conn, string? sender,
                                string object_path, string interface_name,
                                string signal_name, Variant parameters) {
            if (!parameters.is_of_type(new VariantType("(sa{sv})"))) return;
            string app_uri = parameters.get_child_value(0).get_string();
            if (EntryState.app_id_from_uri(app_uri) == null) return;
            var state = _store.update(app_uri, sender, parameters.get_child_value(1));
            if (sender != null && _by_app.has_key(state.app_id)) resolve_ownership.begin(state, sender);
            schedule_save();
            this.changed("");
        }

        private static string normalize(string id) {
            string s = id.down();
            if (s.has_suffix(".desktop")) s = s.substring(0, s.length - ".desktop".length);
            return s;
        }

        private string? lookup_key(string app_id) {
            string a = normalize(app_id);
            if (_by_app.has_key(a)) return a;
            return null;
        }

        // ── DockItemExtension ────────────────────────────────────────────────
        public bool matches(string app_id) {
            return lookup_key(app_id) != null;
        }

        public Gdk.Paintable? get_icon_override(string app_id) { return null; }

        /**
         * Small count badge anchored on the icon itself (bottom-centre via
         * dock CSS). Preferred to the suffix-area badge for unread counts:
         * always visible without hover, and doesn't push the pill wider.
         */
        public override Gtk.Widget? create_icon_overlay(string app_id) {
            string? key = lookup_key(app_id);
            if (key == null) return null;
            var state = _by_app[key];
            if (!state.count_visible || state.count <= 0) {
                if (state.urgent) {
                    var dot = new Gtk.Label("!");
                    dot.add_css_class("launcher-entry-icon-badge");
                    dot.add_css_class("launcher-entry-urgent");
                    return dot;
                }
                return null;
            }
            string txt = state.count > 99 ? "99+" : "%lld".printf(state.count);
            var lbl = new Gtk.Label(txt);
            lbl.add_css_class("launcher-entry-icon-badge");
            if (state.urgent) lbl.add_css_class("launcher-entry-urgent");
            lbl.tooltip_text = state.urgent
                ? "%lld item(s) need attention".printf(state.count)
                : "%lld pending".printf(state.count);
            return lbl;
        }

        public Gtk.Widget? create_suffix_widget(string app_id) {
            string? key = lookup_key(app_id);
            if (key == null) return null;
            var state = _by_app[key];

            // Rich row when the sender provided a label (e.g. our files app):
            // [name, ellipsized] [progress ring with %].
            // Falls back to the compact "ring + badge" pair when no label.
            if (state.label != null && state.label.length > 0 && state.progress_visible) {
                var row = new Gtk.Box(Orientation.HORIZONTAL, 8);
                row.add_css_class("dock-suffix-progress-row");
                row.valign = Align.CENTER;

                var lbl = new Gtk.Label(state.label);
                lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
                lbl.max_width_chars = 22;
                lbl.halign = Align.START;
                lbl.hexpand = true;
                lbl.add_css_class("dock-suffix-progress-row-label");
                row.append(lbl);

                var cp = new Singularity.Widgets.CircularProgress(22);
                cp.fraction = state.progress.clamp(0, 1);
                cp.label = "%d".printf((int)(state.progress * 100));
                cp.color = state.urgent ? "#e01b24" : "#3584e4";
                row.append(cp);

                // If a count is also visible, hint it via tooltip - we
                // intentionally don't show two number badges in the same row.
                row.tooltip_text = state.count_visible && state.count > 0
                    ? "%s · %s item(s)".printf(state.label,
                        state.count > 99 ? "99+" : "%lld".printf(state.count))
                    : state.label;
                return row;
            }

            var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
            box.valign = Align.CENTER;

            // Progress ring with percentage label. The count badge / urgent
            // dot are now rendered as an icon overlay (see create_icon_overlay)
            // - small, anchored on the icon bottom-centre, always visible
            // without hovering. The suffix area is reserved for richer info
            // like progress.
            if (state.progress_visible) {
                var cp = new Singularity.Widgets.CircularProgress(30);
                cp.fraction = state.progress.clamp(0, 1);
                cp.label = "%d".printf((int)(state.progress * 100));
                cp.color = state.urgent ? "#e01b24" : "#3584e4";
                cp.tooltip_text = "%d%% complete".printf((int)(state.progress * 100));
                box.append(cp);
            }

            if (box.get_first_child() == null) return null;
            return box;
        }
    }
}

public class LauncherEntryDockPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private LauncherEntryDock.Extension? extension;
    private Gtk.CssProvider? css_provider = null;

    // Plugin-owned styles. Lives here (not in libsingularity's style.css) so
    // the plugin is self-contained - drop the .so into a search path and it
    // brings its visuals with it.
    private const string CSS = """
.launcher-entry-icon-badge {
    min-width: 16px;
    min-height: 14px;
    padding: 0 4px;
    border-radius: 9999px;
    font-size: 10px;
    font-weight: 700;
    color: white;
    background-color: @accent_bg_color;
    box-shadow: 0 0 0 2px @window_bg_color, 0 1px 3px alpha(black, 0.4);
    margin-bottom: -2px;
}
.launcher-entry-icon-badge.launcher-entry-urgent {
    background-color: #e01b24;
}
""";

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        // Load our own CSS at APPLICATION priority so it sits above
        // libsingularity's theme but below user overrides.
        css_provider = new Gtk.CssProvider();
        css_provider.load_from_data(CSS.data);
        var display = Gdk.Display.get_default();
        if (display != null)
            Gtk.StyleContext.add_provider_for_display(
                display, css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        extension = new LauncherEntryDock.Extension();
        context.add_dock_item_extension(extension);
    }

    public void deactivate() {
        if (extension != null) {
            extension.disconnect_dbus();
            context.remove_dock_item_extension(extension);
            extension = null;
        }
        if (css_provider != null) {
            var display = Gdk.Display.get_default();
            if (display != null)
                Gtk.StyleContext.remove_provider_for_display(display, css_provider);
            css_provider = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return null;
    }
}
