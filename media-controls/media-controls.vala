using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(MediaControlsPlugin));
}

public class MediaControlsPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Box container;
    private Image cover_img;
    private Label track_label;
    private Button prev_btn;
    private Button play_btn;
    private Button next_btn;
    private DBusConnection? bus_conn = null;
    private uint name_watcher_id = 0;
    private uint props_changed_id = 0;
    private string? active_player = null;
    private bool is_playing = false;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        container = new Box(Orientation.HORIZONTAL, 4);
        container.add_css_class("media-controls");
        container.valign = Align.CENTER;

        prev_btn = new Button.from_icon_name("media-skip-backward-symbolic");
        prev_btn.add_css_class("flat");
        prev_btn.add_css_class("panel-button");
        prev_btn.tooltip_text = "Previous";
        prev_btn.clicked.connect(() => player_action("Previous"));
        container.append(prev_btn);

        play_btn = new Button.from_icon_name("media-playback-start-symbolic");
        play_btn.add_css_class("flat");
        play_btn.add_css_class("panel-button");
        play_btn.tooltip_text = "Play/Pause";
        play_btn.clicked.connect(() => player_action("PlayPause"));
        container.append(play_btn);

        next_btn = new Button.from_icon_name("media-skip-forward-symbolic");
        next_btn.add_css_class("flat");
        next_btn.add_css_class("panel-button");
        next_btn.tooltip_text = "Next";
        next_btn.clicked.connect(() => player_action("Next"));
        container.append(next_btn);

        cover_img = new Image();
        cover_img.pixel_size = 20;
        cover_img.add_css_class("media-cover");
        container.append(cover_img);

        track_label = new Label("");
        track_label.add_css_class("caption");
        track_label.ellipsize = Pango.EllipsizeMode.END;
        track_label.max_width_chars = 30;
        track_label.halign = Align.START;
        container.append(track_label);

        container.visible = false;
        context.add_panel_widget(container, Align.END);

        connect_dbus.begin();
    }

    public void deactivate() {
        if (bus_conn != null) {
            if (props_changed_id != 0) {
                bus_conn.signal_unsubscribe(props_changed_id);
                props_changed_id = 0;
            }
        }
        if (name_watcher_id != 0) {
            Bus.unwatch_name(name_watcher_id);
            name_watcher_id = 0;
        }
        if (container != null) {
            context.remove_panel_widget(container);
            container = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;
        var lbl = new Label("Shows MPRIS2 media player controls in the panel.");
        lbl.wrap = true;
        lbl.halign = Align.START;
        box.append(lbl);
        if (active_player != null) {
            var pl = new Label("Active: " + active_player);
            pl.halign = Align.START;
            box.append(pl);
        }
        return box;
    }

    private async void connect_dbus() {
        try {
            bus_conn = yield Bus.get(BusType.SESSION);

            name_watcher_id = Bus.watch_name_on_connection(
                bus_conn,
                "org.mpris.MediaPlayer2",
                BusNameWatcherFlags.NONE,
                on_player_appeared,
                on_player_vanished
            );

            var result = yield bus_conn.call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "ListNames",
                null,
                new VariantType("(as)"),
                DBusCallFlags.NONE,
                -1,
                null
            );
            VariantIter iter;
            result.get("(as)", out iter);
            string? name_str;
            while (iter.next("s", out name_str)) {
                if (name_str != null && name_str.has_prefix("org.mpris.MediaPlayer2.")) {
                    on_player_appeared(bus_conn, name_str, "");
                }
            }
        } catch (Error e) {
            warning("MediaControls: D-Bus error: %s", e.message);
        }
    }

    private void on_player_appeared(DBusConnection conn, string name, string owner) {
        if (!name.has_prefix("org.mpris.MediaPlayer2.")) return;
        if (active_player != null) {
            bool old_playing = is_playing;
            if (old_playing) return;
        }
        switch_player(name);
    }

    private void on_player_vanished(DBusConnection conn, string name) {
        if (active_player == name) {
            active_player = null;
            if (props_changed_id != 0 && bus_conn != null) {
                bus_conn.signal_unsubscribe(props_changed_id);
                props_changed_id = 0;
            }
            find_next_player.begin();
        }
    }

    private async void find_next_player() {
        if (bus_conn == null) return;
        try {
            var result = yield bus_conn.call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "ListNames",
                null,
                new VariantType("(as)"),
                DBusCallFlags.NONE,
                -1,
                null
            );
            VariantIter iter;
            result.get("(as)", out iter);
            string? name_str;
            while (iter.next("s", out name_str)) {
                if (name_str != null && name_str.has_prefix("org.mpris.MediaPlayer2.")) {
                    switch_player(name_str);
                    return;
                }
            }
        } catch (Error e) { }
        if (container != null) container.visible = false;
    }

    private void switch_player(string name) {
        if (active_player != null && props_changed_id != 0 && bus_conn != null) {
            bus_conn.signal_unsubscribe(props_changed_id);
            props_changed_id = 0;
        }
        active_player = name;
        subscribe_properties();
        fetch_metadata.begin();
    }

    private void subscribe_properties() {
        if (bus_conn == null || active_player == null) return;
        props_changed_id = bus_conn.signal_subscribe(
            active_player,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            "/org/mpris/MediaPlayer2",
            null,
            DBusSignalFlags.NONE,
            on_props_changed
        );
    }

    private void on_props_changed(DBusConnection conn, string? sender, string path,
                                   string iface, string signal_name, Variant params) {
        VariantIter iter;
        params.get("(sa{sv}as)", null, out iter, null);
        string key;
        Variant val;
        bool has_playback = false;
        while (iter.next("{sv}", out key, out val)) {
            if (key == "PlaybackStatus") {
                has_playback = true;
                var status = val.get_string();
                if (status == "Playing" && sender != null && sender.has_prefix("org.mpris.MediaPlayer2.")) {
                    if (active_player != sender) {
                        switch_player(sender);
                        return;
                    }
                }
            }
        }
        fetch_metadata.begin();
    }

    private async void fetch_metadata() {
        if (bus_conn == null || active_player == null) return;
        try {
            var result = yield bus_conn.call(
                active_player,
                "/org/mpris/MediaPlayer2",
                "org.freedesktop.DBus.Properties",
                "GetAll",
                new Variant("(s)", "org.mpris.MediaPlayer2.Player"),
                new VariantType("(a{sv})"),
                DBusCallFlags.NONE,
                -1,
                null
            );
            VariantIter props_iter;
            result.get("(a{sv})", out props_iter);
            string prop_name;
            Variant prop_val;
            string title = "";
            string artist = "";
            string art_url = "";
            string status = "Stopped";

            while (props_iter.next("{sv}", out prop_name, out prop_val)) {
                if (prop_name == "Metadata") {
                    VariantIter meta_iter = prop_val.iterator();
                    string key;
                    Variant val;
                    while (meta_iter.next("{sv}", out key, out val)) {
                        if (key == "xesam:title") title = val.get_string();
                        else if (key == "xesam:artist") {
                            if (val.get_type_string() == "as") {
                                VariantIter ai = val.iterator();
                                string? a;
                                if (ai.next("s", out a) && a != null) artist = a;
                            }
                        } else if (key == "mpris:artUrl") {
                            art_url = val.get_string();
                        }
                    }
                } else if (prop_name == "PlaybackStatus") {
                    status = prop_val.get_string();
                }
            }

            is_playing = (status == "Playing");
            if (play_btn != null) {
                play_btn.icon_name = is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            }

            if (title != "" && container != null) {
                string display = artist != "" ? "%s - %s".printf(artist, title) : title;
                track_label.label = display;

                if (art_url != "") {
                    load_cover.begin(art_url);
                } else {
                    cover_img.icon_name = "audio-x-generic-symbolic";
                    cover_img.pixel_size = 20;
                }

                container.visible = true;
            } else if (container != null) {
                container.visible = false;
            }
        } catch (Error e) {
            if (container != null) container.visible = false;
        }
    }

    private async void load_cover(string url) {
        try {
            if (url.has_prefix("file://")) {
                var path = url.substring(7);
                var pb = new Gdk.Pixbuf.from_file_at_size(path, 40, 40);
                cover_img.set_from_pixbuf(pb);
            } else if (url.has_prefix("http://") || url.has_prefix("https://")) {
                var session = new Soup.Session();
                session.timeout = 5;
                var msg = new Soup.Message("GET", url);
                var bytes = yield session.send_and_read_async(msg, Priority.DEFAULT, null);
                if (bytes != null) {
                    var pb = new Gdk.Pixbuf.from_stream_at_scale(
                        new GLib.MemoryInputStream.from_bytes(bytes), 40, 40, true, null);
                    cover_img.set_from_pixbuf(pb);
                }
            } else {
                cover_img.icon_name = "audio-x-generic-symbolic";
                cover_img.pixel_size = 20;
            }
        } catch (Error e) {
            cover_img.icon_name = "audio-x-generic-symbolic";
            cover_img.pixel_size = 20;
        }
    }

    private void player_action(string method) {
        if (bus_conn == null || active_player == null) return;
        bus_conn.call.begin(
            active_player,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            method,
            null,
            null,
            DBusCallFlags.NONE,
            -1,
            null,
            null
        );
    }
}