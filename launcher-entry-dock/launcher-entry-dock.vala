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

    public class EntryState {
        public string app_id;          // desktop id without .desktop
        public int64 count;
        public bool count_visible;
        public double progress;        // 0..1
        public bool progress_visible;
        public bool urgent;
        public string? label;           // non-standard, optional pretty name
        public int64 updated_at;
    }

    public class Extension : Object, Singularity.DockItemExtension {
        private HashMap<string, EntryState> _by_app = new HashMap<string, EntryState>();
        private DBusConnection? _conn;
        private uint _sub_id = 0;

        public Extension() {
            try {
                _conn = Bus.get_sync(BusType.SESSION);
            } catch (Error e) {
                warning("launcher-entry-dock: bus get failed: %s", e.message);
                return;
            }
            // Subscribe to LauncherEntry.Update from anywhere. Object path
            // varies across emitters (Nautilus uses /com/canonical/Unity/LauncherEntry;
            // others use their own path), so we pass null for path.
            _sub_id = _conn.signal_subscribe(
                null,                                       // sender
                "com.canonical.Unity.LauncherEntry",        // interface
                "Update",                                    // signal name
                null,                                       // object path
                null,                                       // arg0
                DBusSignalFlags.NONE,
                on_update);
        }

        public void disconnect_dbus() {
            if (_conn != null && _sub_id != 0) {
                _conn.signal_unsubscribe(_sub_id);
                _sub_id = 0;
            }
        }

        private void on_update(DBusConnection conn, string? sender,
                                string object_path, string interface_name,
                                string signal_name, Variant parameters) {
            // parameters: (s, a{sv})
            if (!parameters.is_of_type(new VariantType("(sa{sv})"))) return;
            string app_uri = parameters.get_child_value(0).get_string();
            Variant props = parameters.get_child_value(1);

            string app_id = app_id_from_uri(app_uri);
            if (app_id == null || app_id.length == 0) return;

            var state = _by_app.has_key(app_id)
                ? _by_app[app_id]
                : new EntryState();
            state.app_id = app_id;

            // Per spec, properties are sparse - only the keys the sender
            // wants to change are present. We MERGE into existing state.
            var c = props.lookup_value("count", null);
            if (c != null) {
                if (c.is_of_type(VariantType.VARIANT)) c = c.get_variant();
                if (c.is_of_type(VariantType.INT64)) state.count = c.get_int64();
                else if (c.is_of_type(VariantType.INT32)) state.count = c.get_int32();
            }
            var cv = props.lookup_value("count-visible", null);
            if (cv != null) {
                if (cv.is_of_type(VariantType.VARIANT)) cv = cv.get_variant();
                if (cv.is_of_type(VariantType.BOOLEAN)) state.count_visible = cv.get_boolean();
            }
            var p = props.lookup_value("progress", null);
            if (p != null) {
                if (p.is_of_type(VariantType.VARIANT)) p = p.get_variant();
                if (p.is_of_type(VariantType.DOUBLE)) state.progress = p.get_double();
            }
            var pv = props.lookup_value("progress-visible", null);
            if (pv != null) {
                if (pv.is_of_type(VariantType.VARIANT)) pv = pv.get_variant();
                if (pv.is_of_type(VariantType.BOOLEAN)) state.progress_visible = pv.get_boolean();
            }
            var u = props.lookup_value("urgent", null);
            if (u != null) {
                if (u.is_of_type(VariantType.VARIANT)) u = u.get_variant();
                if (u.is_of_type(VariantType.BOOLEAN)) state.urgent = u.get_boolean();
            }
            // Non-standard extension: a human-readable name for the current
            // activity. Surfaced as a label on the dock row when present.
            var lbl = props.lookup_value("label", null);
            if (lbl != null) {
                if (lbl.is_of_type(VariantType.VARIANT)) lbl = lbl.get_variant();
                if (lbl.is_of_type(VariantType.STRING)) state.label = lbl.get_string();
            } else if (state.count == 0) {
                // Sender cleared count → also drop a stale label.
                state.label = null;
            }
            state.updated_at = GLib.get_monotonic_time();

            if (!_by_app.has_key(app_id)) _by_app[app_id] = state;

            // If everything is now invisible AND no urgent flag, drop the
            // entry entirely so the dock item goes back to its normal look.
            if (!state.count_visible && !state.progress_visible && !state.urgent) {
                _by_app.unset(app_id);
            }

            this.changed("");
        }

        private static string? app_id_from_uri(string uri) {
            // "application://name.desktop" → "name"
            if (uri == null || uri.length == 0) return null;
            string s = uri;
            if (s.has_prefix("application://"))
                s = s.substring("application://".length);
            if (s.has_suffix(".desktop"))
                s = s.substring(0, s.length - ".desktop".length);
            return s.down();
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
