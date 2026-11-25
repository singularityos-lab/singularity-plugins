using Gtk;
using Singularity;
using Peas;
using GLib;
using Gee;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(MprisDockPlugin));
}

namespace MprisDock {

    public class Extension : Object, Singularity.DockItemExtension {
        // Cached state, refreshed when players appear, vanish or change.
        public class Entry {
            public string mpris_name;
            public string player_id;   // lower-case substring after the prefix
            public string identity;    // lower-case
            public string status;
            public string art_url;
            public Gdk.Texture? cover;
        }

        private HashMap<string, Entry> _by_app = new HashMap<string, Entry>();
        private DBusConnection? _conn = null;
        private uint _props_sub_id = 0;
        private uint _names_sub_id = 0;
        private bool _poll_running = false;
        private bool _poll_again = false;

        public Extension() {
            setup.begin();
        }

        private async void setup() {
            try {
                _conn = yield Bus.get(BusType.SESSION);
                _props_sub_id = _conn.signal_subscribe(
                    null, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                    "/org/mpris/MediaPlayer2", null, DBusSignalFlags.NONE,
                    (conn, sender, path, iface, sig, args) => {
                        request_poll();
                    });
                _names_sub_id = _conn.signal_subscribe(
                    "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                    "/org/freedesktop/DBus", "org.mpris.MediaPlayer2",
                    DBusSignalFlags.MATCH_ARG0_NAMESPACE,
                    (conn, sender, path, iface, sig, args) => {
                        request_poll();
                    });
                request_poll();
            } catch (Error e) {}
        }

        ~Extension() {
            if (_conn != null && _props_sub_id != 0) _conn.signal_unsubscribe(_props_sub_id);
            if (_conn != null && _names_sub_id != 0) _conn.signal_unsubscribe(_names_sub_id);
        }

        // ── DockItemExtension ────────────────────────────────────────────────
        public bool matches(string app_id) {
            return entry_for(app_id) != null;
        }

        public Gdk.Paintable? get_icon_override(string app_id) {
            var e = entry_for(app_id);
            return e != null ? e.cover : null;
        }

        public Gtk.Widget? create_suffix_widget(string app_id) {
            var e = entry_for(app_id);
            if (e == null) return null;
            var box = new Box(Orientation.HORIZONTAL, 2);
            box.valign = Align.CENTER;
            box.add_css_class("dock-mpris-controls");

            var prev = new Button.from_icon_name("media-skip-backward-symbolic");
            prev.has_frame = false;
            prev.add_css_class("dock-suffix-button");
            prev.clicked.connect(() => player_action(e.mpris_name, "Previous"));
            box.append(prev);

            string play_icon = e.status == "Playing"
                ? "media-playback-pause-symbolic"
                : "media-playback-start-symbolic";
            var pp = new Button.from_icon_name(play_icon);
            pp.has_frame = false;
            pp.add_css_class("dock-suffix-button");
            pp.clicked.connect(() => player_action(e.mpris_name, "PlayPause"));
            box.append(pp);

            var next = new Button.from_icon_name("media-skip-forward-symbolic");
            next.has_frame = false;
            next.add_css_class("dock-suffix-button");
            next.clicked.connect(() => player_action(e.mpris_name, "Next"));
            box.append(next);

            return box;
        }

        // ── Polling ──────────────────────────────────────────────────────────
        private Entry? entry_for(string app_id) {
            string al = app_id.down().replace(".desktop", "");
            foreach (var e in _by_app.values) {
                if (al.contains(e.player_id) || e.player_id.contains(al) ||
                    (e.identity != "" && (e.identity.contains(al) || al.contains(e.identity)))) {
                    return e;
                }
            }
            return null;
        }

        private void player_action(string name, string method) {
            if (_conn == null) return;
            _conn.call.begin(name, "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player", method, null, null,
                DBusCallFlags.NONE, 1000, null, null);
        }

        private void request_poll() {
            if (_poll_running) {
                _poll_again = true;
                return;
            }
            poll.begin();
        }

        private async Variant? fetch_property(string name, string iface,
                                              string property) {
            var conn = _conn;
            if (conn == null) return null;
            try {
                var result = yield conn.call(name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", iface, property),
                    new VariantType("(v)"), DBusCallFlags.NONE, 500, null);
                return result.get_child_value(0).get_variant();
            } catch (Error e) {
                return null;
            }
        }

        private async void poll() {
            var conn = _conn;
            if (conn == null) return;
            _poll_running = true;
            var new_map = new HashMap<string, Entry>();
            try {
                var result = yield conn.call(
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "ListNames", null,
                    new VariantType("(as)"), DBusCallFlags.NONE, 1000, null);
                VariantIter iter;
                result.get("(as)", out iter);
                string? name;
                while (iter.next("s", out name)) {
                    if (name == null) continue;
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    var entry = new Entry();
                    entry.mpris_name = name;
                    entry.player_id = name.substring("org.mpris.MediaPlayer2.".length).down();
                    entry.identity = "";
                    entry.status = "Stopped";
                    entry.art_url = "";
                    var identity = yield fetch_property(name,
                        "org.mpris.MediaPlayer2", "Identity");
                    if (identity != null
                            && identity.is_of_type(VariantType.STRING))
                        entry.identity = identity.get_string().down();
                    var status = yield fetch_property(name,
                        "org.mpris.MediaPlayer2.Player", "PlaybackStatus");
                    if (status != null && status.is_of_type(VariantType.STRING))
                        entry.status = status.get_string();
                    var metadata = yield fetch_property(name,
                        "org.mpris.MediaPlayer2.Player", "Metadata");
                    if (metadata != null) {
                        var art = metadata.lookup_value("mpris:artUrl", null);
                        if (art != null && art.is_of_type(VariantType.STRING))
                            entry.art_url = art.get_string();
                    }
                    if (entry.status == "Stopped") continue;

                    Entry? prev = _by_app[entry.player_id];
                    if (prev != null && prev.art_url == entry.art_url && prev.cover != null) {
                        entry.cover = prev.cover;
                    } else if (entry.art_url != "") {
                        entry.cover = yield load_cover(entry.art_url, 64);
                    }
                    new_map[entry.player_id] = entry;
                }
            } catch {}

            // Detect changes (count / status / art) to fire `changed`
            bool different = new_map.size != _by_app.size;
            if (!different) {
                foreach (var k in new_map.keys) {
                    var a = new_map[k]; var b = _by_app[k];
                    if (b == null || a.status != b.status || a.art_url != b.art_url) {
                        different = true; break;
                    }
                }
            }
            _by_app = new_map;
            if (different) this.changed("");
            _poll_running = false;
            if (_poll_again) {
                _poll_again = false;
                request_poll();
            }
        }

        private static async Gdk.Texture? load_cover(string art_url, int size) {
            try {
                if (art_url.has_prefix("file://")) {
                    string path = GLib.Uri.unescape_string(art_url.substring(7));
                    if (!GLib.FileUtils.test(path, GLib.FileTest.EXISTS)) return null;
                    var pb = new Gdk.Pixbuf.from_file_at_scale(path, size, size, true);
                    return Gdk.Texture.for_pixbuf(pb);
                } else if (art_url.has_prefix("http://") || art_url.has_prefix("https://")) {
                    var session = new Soup.Session();
                    session.timeout = 2;
                    var msg = new Soup.Message("GET", art_url);
                    var stream = yield session.send_async(msg,
                        Priority.DEFAULT, null);
                    if (msg.status_code == 200) {
                        var pb = yield new Gdk.Pixbuf.from_stream_at_scale_async(
                            stream, size, size, true, null);
                        return Gdk.Texture.for_pixbuf(pb);
                    }
                }
            } catch {}
            return null;
        }
    }
}

public class MprisDockPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private MprisDock.Extension? extension;

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        extension = new MprisDock.Extension();
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
