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

    [DBus (name = "org.freedesktop.DBus")]
    public interface FreedesktopDBus : Object {
        public abstract string[] ListNames() throws IOError;
    }

    [DBus (name = "org.mpris.MediaPlayer2.Player")]
    public interface MprisPlayer : Object {
        public abstract string playback_status { owned get; }
        public abstract void next() throws IOError;
        public abstract void previous() throws IOError;
        public abstract void play_pause() throws IOError;
    }

    public class Extension : Object, Singularity.DockItemExtension {
        // Cached state, refreshed every poll tick.
        public class Entry {
            public string mpris_name;
            public string player_id;   // lower-case substring after the prefix
            public string identity;    // lower-case
            public string status;
            public string art_url;
            public Gdk.Texture? cover;
        }

        private HashMap<string, Entry> _by_app = new HashMap<string, Entry>();
        private uint _poll_id = 0;

        public Extension() {
            poll();
            _poll_id = GLib.Timeout.add(2000, () => { poll(); return GLib.Source.CONTINUE; });
        }

        ~Extension() {
            if (_poll_id != 0) GLib.Source.remove(_poll_id);
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
            MprisPlayer? player = null;
            try {
                player = Bus.get_proxy_sync<MprisPlayer>(BusType.SESSION, e.mpris_name, "/org/mpris/MediaPlayer2");
            } catch (Error err) {
                return null;
            }
            var box = new Box(Orientation.HORIZONTAL, 2);
            box.valign = Align.CENTER;
            box.add_css_class("dock-mpris-controls");

            var prev = new Button.from_icon_name("media-skip-backward-symbolic");
            prev.has_frame = false;
            prev.add_css_class("dock-suffix-button");
            prev.clicked.connect(() => { try { player.previous(); } catch {} });
            box.append(prev);

            string play_icon = e.status == "Playing"
                ? "media-playback-pause-symbolic"
                : "media-playback-start-symbolic";
            var pp = new Button.from_icon_name(play_icon);
            pp.has_frame = false;
            pp.add_css_class("dock-suffix-button");
            pp.clicked.connect(() => { try { player.play_pause(); } catch {} });
            box.append(pp);

            var next = new Button.from_icon_name("media-skip-forward-symbolic");
            next.has_frame = false;
            next.add_css_class("dock-suffix-button");
            next.clicked.connect(() => { try { player.next(); } catch {} });
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

        private void poll() {
            var new_map = new HashMap<string, Entry>();
            try {
                var dbus = Bus.get_proxy_sync<FreedesktopDBus>(BusType.SESSION, "org.freedesktop.DBus", "/org/freedesktop/DBus");
                string[] names = dbus.ListNames();
                foreach (string name in names) {
                    if (!name.has_prefix("org.mpris.MediaPlayer2.")) continue;
                    try {
                        var entry = new Entry();
                        entry.mpris_name = name;
                        entry.player_id = name.substring("org.mpris.MediaPlayer2.".length).down();

                        var bus = Bus.get_sync(BusType.SESSION);
                        try {
                            var v = bus.call_sync(name, "/org/mpris/MediaPlayer2",
                                "org.freedesktop.DBus.Properties", "Get",
                                new Variant("(ss)", "org.mpris.MediaPlayer2", "Identity"),
                                null, GLib.DBusCallFlags.NONE, 300);
                            entry.identity = v.get_child_value(0).get_variant().get_string().down();
                        } catch { entry.identity = ""; }

                        try {
                            var st = bus.call_sync(name, "/org/mpris/MediaPlayer2",
                                "org.freedesktop.DBus.Properties", "Get",
                                new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "PlaybackStatus"),
                                null, GLib.DBusCallFlags.NONE, 300);
                            entry.status = st.get_child_value(0).get_variant().get_string();
                        } catch { entry.status = "Stopped"; }

                        try {
                            var meta = bus.call_sync(name, "/org/mpris/MediaPlayer2",
                                "org.freedesktop.DBus.Properties", "Get",
                                new Variant("(ss)", "org.mpris.MediaPlayer2.Player", "Metadata"),
                                null, GLib.DBusCallFlags.NONE, 300);
                            var v = meta.get_child_value(0).get_variant();
                            if (v.is_of_type(VariantType.DICTIONARY)) {
                                var art_val = v.lookup_value("mpris:artUrl", VariantType.STRING);
                                if (art_val != null) entry.art_url = art_val.get_string();
                            }
                        } catch {}

                        // Drop Stopped entries unconditionally. Chrome keeps
                        // its MPRIS bus name alive after the media tab is
                        // closed (PlaybackStatus="Stopped", stale mpris:artUrl
                        // still present) - without this the dock item would
                        // hang around with no playable content behind it.
                        if (entry.status == "Stopped") continue;

                        // Reuse existing texture when URL is unchanged
                        Entry? prev = _by_app[entry.player_id];
                        if (prev != null && prev.art_url == entry.art_url && prev.cover != null) {
                            entry.cover = prev.cover;
                        } else if (entry.art_url != null) {
                            entry.cover = load_cover(entry.art_url, 64);
                        }
                        new_map[entry.player_id] = entry;
                    } catch {}
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
        }

        private static Gdk.Texture? load_cover(string art_url, int size) {
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
                    var stream = session.send(msg, null);
                    if (msg.status_code == 200) {
                        var pb = new Gdk.Pixbuf.from_stream_at_scale(stream, size, size, true);
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
