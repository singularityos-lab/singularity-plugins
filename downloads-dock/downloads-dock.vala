using Gtk;
using Singularity;
using Peas;
using GLib;
using Gee;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(DownloadsDockPlugin));
}

namespace DownloadsDock {

    public class DownloadInfo {
        public string path;
        public string basename;
        public string kind;        // "crdownload" or "part"
        public int64 size;
        public int64 last_size;
        public int64 last_size_at; // monotonic μs
    }

    public class Extension : Object, Singularity.DockItemExtension {
        private GLib.File downloads_dir;
        private GLib.FileMonitor? monitor;
        private HashMap<string, DownloadInfo> _active = new HashMap<string, DownloadInfo>();
        private uint _poll_id = 0;

        public Extension() {
            string? dl_path = Environment.get_user_special_dir(GLib.UserDirectory.DOWNLOAD);
            if (dl_path == null || dl_path.length == 0) {
                dl_path = Environment.get_home_dir() + "/Downloads";
            }
            downloads_dir = GLib.File.new_for_path(dl_path);
            try {
                monitor = downloads_dir.monitor_directory(GLib.FileMonitorFlags.NONE, null);
                monitor.changed.connect((file, other, event_type) => {
                    rescan();
                });
            } catch (Error e) {
                warning("downloads-dock: monitor failed: %s", e.message);
            }
            rescan();
            // Poll to update sizes (file monitor only fires on create/delete/rename,
            // not on continuous writes during a download).
            _poll_id = GLib.Timeout.add_seconds(1, () => {
                update_sizes();
                return GLib.Source.CONTINUE;
            });
        }

        ~Extension() {
            if (_poll_id != 0) GLib.Source.remove(_poll_id);
        }

        private void rescan() {
            try {
                var enumerator = downloads_dir.enumerate_children(
                    "standard::name,standard::size,standard::type",
                    GLib.FileQueryInfoFlags.NONE, null);
                var seen = new HashSet<string>();
                FileInfo? info;
                while ((info = enumerator.next_file(null)) != null) {
                    string name = info.get_name();
                    string kind = "";
                    if (name.has_suffix(".crdownload")) kind = "crdownload";
                    else if (name.has_suffix(".part"))  kind = "part";
                    else continue;
                    string full = downloads_dir.get_path() + "/" + name;
                    seen.add(full);
                    if (!_active.has_key(full)) {
                        var d = new DownloadInfo();
                        d.path = full;
                        d.basename = strip_suffix(name, kind);
                        d.kind = kind;
                        d.size = (int64) info.get_size();
                        d.last_size = d.size;
                        d.last_size_at = GLib.get_monotonic_time();
                        _active[full] = d;
                    } else {
                        _active[full].size = (int64) info.get_size();
                    }
                }
                // Remove vanished
                var stale = new ArrayList<string>();
                foreach (var k in _active.keys) if (!seen.contains(k)) stale.add(k);
                foreach (var k in stale) _active.unset(k);
            } catch (Error e) {
                // Probably the dir doesn't exist or is unreadable - leave _active as-is.
            }
            this.changed("");
        }

        private void update_sizes() {
            if (_active.size == 0) return;
            bool any_changed = false;
            foreach (var d in _active.values) {
                try {
                    var f = GLib.File.new_for_path(d.path);
                    var info = f.query_info("standard::size", GLib.FileQueryInfoFlags.NONE, null);
                    var new_size = (int64) info.get_size();
                    if (new_size != d.size) {
                        d.last_size = d.size;
                        d.last_size_at = GLib.get_monotonic_time();
                        d.size = new_size;
                        any_changed = true;
                    }
                } catch {
                    // File gone - handled on next rescan
                }
            }
            if (any_changed) this.changed("");
        }

        private static string strip_suffix(string name, string kind) {
            if (kind == "crdownload" && name.has_suffix(".crdownload"))
                return name.substring(0, name.length - ".crdownload".length);
            if (kind == "part" && name.has_suffix(".part"))
                return name.substring(0, name.length - ".part".length);
            return name;
        }

        private static string truncate(string s, int max) {
            if (s.length <= max) return s;
            return s.substring(0, max - 1) + "…";
        }

        private static string human_size(int64 bytes) {
            double v = (double) bytes;
            string[] units = {"B", "KB", "MB", "GB", "TB"};
            int u = 0;
            while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
            return u == 0 ? "%d %s".printf((int)v, units[u])
                          : "%.1f %s".printf(v, units[u]);
        }

        private string kind_for_app(string app_id) {
            string id = app_id.down().replace(".desktop", "");
            if (id.contains("chrome") || id.contains("chromium") ||
                id.contains("brave")  || id.contains("edge")     ||
                id.contains("vivaldi") || id.contains("opera")   ||
                id.contains("singularity-browser")) return "crdownload";
            if (id.contains("firefox") || id.contains("librewolf") ||
                id.contains("waterfox")) return "part";
            return "";
        }

        // ── DockItemExtension ────────────────────────────────────────────────
        public bool matches(string app_id) {
            if (_active.size == 0) return false;
            string kind = kind_for_app(app_id);
            if (kind == "") return false;
            foreach (var d in _active.values) if (d.kind == kind) return true;
            return false;
        }

        public Gdk.Paintable? get_icon_override(string app_id) { return null; }

        public Gtk.Widget? create_suffix_widget(string app_id) {
            string kind = kind_for_app(app_id);
            if (kind == "") return null;

            var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
            box.valign = Align.CENTER;

            int count = 0;
            foreach (var d in _active.values) {
                if (d.kind != kind) continue;
                count++;
                if (count > 3) break;  // cap to keep dock from getting silly

                var btn = new Gtk.Button();
                btn.has_frame = false;
                btn.add_css_class("dock-suffix-bubble");

                var inner = new Gtk.Box(Orientation.HORIZONTAL, 4);
                inner.valign = Align.CENTER;

                // folder-download-symbolic ships with Adwaita;
                // emblem-downloads only exists in some icon themes.
                var icon = new Image.from_icon_name("folder-download-symbolic");
                icon.pixel_size = 16;
                inner.append(icon);

                var lbl = new Label(human_size(d.size));
                lbl.add_css_class("dock-suffix-label");
                inner.append(lbl);

                btn.set_child(inner);
                // Filename still surfaced via tooltip - quick visual stays clean.
                btn.tooltip_text = "%s · %s".printf(d.basename, human_size(d.size));
                string captured_path = d.path.dup();
                btn.clicked.connect(() => {
                    try {
                        AppInfo.launch_default_for_uri("file://" +
                            downloads_dir.get_path(), null);
                    } catch (Error e) {
                        warning("downloads-dock: open dir failed: %s", e.message);
                    }
                });
                box.append(btn);
            }

            // If we capped, show "+N" badge for the rest
            int remaining = 0;
            foreach (var d in _active.values) if (d.kind == kind) remaining++;
            if (remaining > 3) {
                var more = new Gtk.Label("+%d".printf(remaining - 3));
                more.add_css_class("dock-suffix-badge");
                box.append(more);
            }
            return box;
        }
    }
}

public class DownloadsDockPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private DownloadsDock.Extension? extension;

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        extension = new DownloadsDock.Extension();
        context.add_dock_item_extension(extension);
    }

    public void deactivate() {
        if (extension != null) {
            context.remove_dock_item_extension(extension);
            extension = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return null;
    }
}
