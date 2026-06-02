using Gtk;
using Singularity;
using Peas;
using GLib;
using Gee;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(MessagingDockPlugin));
}

/**
 * MessagingDock - generic dock-extension for any messaging app.
 *
 * Catches every desktop notification and, when the sender's `.desktop` file
 * has Categories=InstantMessaging or Categories=Chat, groups the recent
 * chats under that app's id. The dock item for that app then shows a row
 * of round avatars (one per unique sender) with an unread-count badge.
 * Click a bubble → raises the app, dismisses that chat from the dock.
 *
 * Works out of the box for Telegram, Element, Signal, Slack, Discord (where
 * they classify themselves correctly), Beeper, FluffyChat, etc.
 */
namespace MessagingDock {

    public class Chat {
        public string sender;
        public string last_message;
        public string? avatar_path; // path or file:// URI from notification image hint
        public int unread = 1;
        public int64 received_at; // monotonic μs
        // Notification ids accumulated for this chat. When the user clicks
        // the bubble we close them so the popup + notification-center entry
        // also disappear.
        public Gee.ArrayList<uint> notif_ids = new Gee.ArrayList<uint>();

        public Chat(string sender, string body, string? avatar_path) {
            this.sender = sender;
            this.last_message = body;
            this.avatar_path = avatar_path;
            this.received_at = GLib.get_monotonic_time();
        }
    }

    public class Extension : Object, Singularity.DockItemExtension {
        // Keep at most N most-recent senders per app, newest-first.
        private const int MAX_CHATS_PER_APP = 5;
        // Auto-expire entries after 1 hour (assumed read elsewhere).
        private const int64 EXPIRE_US = 60L * 60 * 1000000;

        // Cache of "is this app a messaging app?" → resolved DesktopAppInfo
        private HashMap<string, GLib.AppInfo?> _app_lookup = new HashMap<string, GLib.AppInfo?>();
        // app_id (normalized: lowercase, no .desktop) → chat list (oldest first)
        private HashMap<string, LinkedList<Chat>> _by_app = new HashMap<string, LinkedList<Chat>>();
        private ulong _notif_handler = 0;
        private weak Singularity.PluginContext? _ctx = null;

        private ulong _closed_handler = 0;

        public Extension(Singularity.PluginContext ctx) {
            this._ctx = ctx;
            _notif_handler = ctx.notification_received.connect(on_notification);
            _closed_handler = ctx.notification_closed.connect(on_notification_closed);
        }

        public void disconnect_signals() {
            if (_ctx != null) {
                if (_notif_handler != 0)  { _ctx.disconnect(_notif_handler);  _notif_handler = 0; }
                if (_closed_handler != 0) { _ctx.disconnect(_closed_handler); _closed_handler = 0; }
            }
        }

        /**
         * Mirror server-side dismissals: when the user clears a notification
         * in the notification centre, drop our derived bubble state so the
         * unread badge doesn't accumulate forever even if the user never
         * clicked the bubble itself.
         */
        private void on_notification_closed(uint id, uint reason) {
            // Per freedesktop spec: reason=1 means the popup expired but the
            // notification is still in the notification centre. The bubble
            // (our derived "unread" state) should survive that. Only drop
            // when the user actually dismissed (2) or the client closed (3).
            if (reason == 1) return;

            string? hit_aid = null;
            Chat? hit_chat = null;
            foreach (var entry in _by_app.entries) {
                foreach (var c in entry.value) {
                    if (c.notif_ids.contains(id)) {
                        hit_aid = entry.key;
                        hit_chat = c;
                        break;
                    }
                }
                if (hit_chat != null) break;
            }
            if (hit_chat == null) return;
            hit_chat.notif_ids.remove(id);
            // unread = remaining live notifications for this chat
            hit_chat.unread = int.max(0, hit_chat.unread - 1);
            if (hit_chat.notif_ids.size == 0 || hit_chat.unread == 0) {
                _by_app[hit_aid].remove(hit_chat);
            }
            this.changed("");
        }

        /**
         * Key used for the _by_app map for any wayland-style app id (e.g.
         * "org.telegram.desktop"). MUST NOT strip a trailing ".desktop"
         * because for reverse-DNS-style ids it's part of the id itself,
         * not a file extension.
         */
        private static string normalize(string id) {
            return id.down();
        }

        /**
         * Key used for entries indexed by an AppInfo: strip the literal
         * ".desktop" file-extension once (AppInfo.get_id() always returns
         * "<id>.desktop"), then lowercase.
         */
        private static string normalize_from_appinfo(GLib.AppInfo info) {
            string id = info.get_id().down();
            if (id.has_suffix(".desktop"))
                return id.substring(0, id.length - ".desktop".length);
            return id;
        }

        /**
         * Returns the AppInfo for app_name if (and only if) its desktop file
         * declares itself as InstantMessaging or Chat. Cached per app_name.
         */
        private GLib.AppInfo? resolve_messaging_app(string app_name) {
            if (app_name == null || app_name.length == 0) return null;
            if (_app_lookup.has_key(app_name)) return _app_lookup[app_name];

            string needle = app_name.down();
            string needle_compact = needle.replace(" ", "").replace("-", "").replace("_", "").replace(".", "");

            GLib.AppInfo? hit = null;
            int total = 0, messaging = 0;
            foreach (var info in GLib.AppInfo.get_all()) {
                total++;
                var dai = info as DesktopAppInfo;
                if (dai == null) continue;

                string cats = dai.get_categories() ?? "";
                bool is_messaging =
                    cats.contains("InstantMessaging") ||
                    cats.contains("Chat") ||
                    cats.contains("IRCClient");
                if (!is_messaging) continue;
                messaging++;

                string nm = info.get_name().down();
                string nm_compact = nm.replace(" ", "").replace("-", "").replace("_", "").replace(".", "");
                string aid = info.get_id().down();
                if (aid.has_suffix(".desktop"))
                    aid = aid.substring(0, aid.length - ".desktop".length);
                string aid_compact = aid.replace(".", "").replace("-", "").replace("_", "");

                if (nm.contains(needle) ||
                    needle.contains(nm) ||
                    nm_compact.contains(needle_compact) ||
                    needle_compact.contains(nm_compact) ||
                    aid.contains(needle) ||
                    needle.contains(aid) ||
                    aid_compact.contains(needle_compact) ||
                    needle_compact.contains(aid_compact)) {
                    hit = info;
                    break;
                }
            }
            if (hit == null) {
                // Don't cache misses - if AppInfo wasn't fully populated yet
                // (e.g. flatpak exports loaded after first notification), a
                // later retry should still find the app.
                return null;
            }
            _app_lookup[app_name] = hit;
            return hit;
        }

        private void on_notification(uint id, string app_name, string summary, string body, string icon) {
            var info = resolve_messaging_app(app_name);
            if (info == null) return;

            string aid = normalize_from_appinfo(info);

            // The notification summary is conventionally the sender's name
            // (or "<chat> · <sender>" for group messages). Body is the line.
            string sender = summary.length > 0 ? summary : app_name;

            string? avatar = null;
            if (icon != null && icon.length > 0 &&
                (icon.has_prefix("/") || icon.has_prefix("file://"))) {
                avatar = icon;
            }

            if (!_by_app.has_key(aid))
                _by_app[aid] = new LinkedList<Chat>();
            var chats = _by_app[aid];

            Chat? existing = null;
            foreach (var c in chats) {
                if (c.sender == sender) { existing = c; break; }
            }
            if (existing != null) {
                chats.remove(existing);
                existing.unread++;
                existing.last_message = body;
                existing.received_at = GLib.get_monotonic_time();
                if (avatar != null) existing.avatar_path = avatar;
                existing.notif_ids.add(id);
                chats.add(existing);
            } else {
                var c = new Chat(sender, body, avatar);
                c.notif_ids.add(id);
                chats.add(c);
            }
            while (chats.size > MAX_CHATS_PER_APP) chats.remove_at(0);
            // Emit with empty app_id so the dock iterates ALL items and lets
            // our matches() decide. dock_matches' filter on the wid is too
            // strict and misses cases like wid="org.telegram.desktop.desktop"
            // (pinned-with-file-ext) vs stored key "org.telegram.desktop".
            this.changed("");
        }

        private void expire_old(string aid) {
            if (!_by_app.has_key(aid)) return;
            var chats = _by_app[aid];
            int64 now = GLib.get_monotonic_time();
            var stale = new ArrayList<Chat>();
            foreach (var c in chats) {
                if (now - c.received_at > EXPIRE_US) stale.add(c);
            }
            foreach (var c in stale) chats.remove(c);
            if (stale.size > 0) this.changed(aid);
        }

        // ── DockItemExtension ────────────────────────────────────────────────
        public bool matches(string app_id) {
            // The dock can pass either "foo" (wayland app_id) or "foo.desktop"
            // (pinned-apps entry stored with the file extension). Try both.
            string a = app_id.down();
            if (_by_app.has_key(a) && _by_app[a].size > 0) return true;
            if (a.has_suffix(".desktop")) {
                string b = a.substring(0, a.length - ".desktop".length);
                if (_by_app.has_key(b) && _by_app[b].size > 0) return true;
            } else {
                string b = a + ".desktop";
                if (_by_app.has_key(b) && _by_app[b].size > 0) return true;
            }
            return false;
        }

        // Same shape as matches(): try both variants of app_id.
        private string? lookup_key(string app_id) {
            string a = app_id.down();
            if (_by_app.has_key(a)) return a;
            if (a.has_suffix(".desktop")) {
                string b = a.substring(0, a.length - ".desktop".length);
                if (_by_app.has_key(b)) return b;
            } else {
                string b = a + ".desktop";
                if (_by_app.has_key(b)) return b;
            }
            return null;
        }

        public Gdk.Paintable? get_icon_override(string app_id) { return null; }

        public Gtk.Widget? create_suffix_widget(string app_id) {
            string? nid = lookup_key(app_id);
            if (nid == null) return null;
            expire_old(nid);
            var chats = _by_app[nid];
            if (chats.size == 0) return null;

            var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
            box.valign = Align.CENTER;

            // Newest-first
            var sorted = new ArrayList<Chat>();
            for (int i = chats.size - 1; i >= 0; i--) sorted.add(chats[i]);

            foreach (var c in sorted) {
                var btn = new Gtk.Button();
                btn.has_frame = false;
                btn.add_css_class("dock-suffix-bubble");
                btn.add_css_class("telegram-avatar-bubble");

                var overlay = new Gtk.Overlay();
                overlay.set_child(build_avatar(c.avatar_path, 28));

                if (c.unread > 1) {
                    string badge_text = c.unread > 99 ? "99+" : "%d".printf(c.unread);
                    var badge = new Gtk.Label(badge_text);
                    badge.add_css_class("dock-suffix-badge");
                    badge.add_css_class("telegram-unread-badge");
                    badge.halign = Align.END;
                    badge.valign = Align.START;
                    badge.can_target = false;
                    overlay.add_overlay(badge);
                }

                btn.set_child(overlay);
                btn.tooltip_text = "%s: %s".printf(c.sender, c.last_message);

                Chat captured = c;
                string captured_aid = nid.dup();
                btn.clicked.connect(() => {
                    if (_by_app.has_key(captured_aid))
                        _by_app[captured_aid].remove(captured);
                    // Dismiss every notification we kept for this chat from
                    // the notification daemon too (popup + history entry).
                    if (_ctx != null) {
                        foreach (uint nid_dismiss in captured.notif_ids) {
                            _ctx.dismiss_notification(nid_dismiss);
                        }
                    }
                    captured.notif_ids.clear();
                    // Empty app_id → dock re-applies on every item, bypassing
                    // its internal dock_matches filter which doesn't always
                    // bridge wid="<id>.desktop" vs stored "<id>".
                    this.changed("");
                    activate_app(captured_aid);
                });
                box.append(btn);
            }
            return box;
        }

        private void activate_app(string normalized_aid) {
            // Try the most likely .desktop-file candidates for this aid.
            string[] candidates = {
                normalized_aid + ".desktop",
                normalized_aid.replace("-", ".") + ".desktop",
                normalized_aid.replace("_", ".") + ".desktop"
            };
            foreach (var id in candidates) {
                var info = new DesktopAppInfo(id);
                if (info != null) {
                    try { info.launch(null, null); return; } catch {}
                }
            }
            // Fallback: scan all DesktopAppInfo to find a matching id.
            foreach (var info in GLib.AppInfo.get_all()) {
                string aid = info.get_id().down();
                if (aid.has_suffix(".desktop"))
                    aid = aid.substring(0, aid.length - ".desktop".length);
                if (aid == normalized_aid) {
                    try { info.launch(null, null); return; } catch {}
                }
            }
        }

        private static Gtk.Widget build_avatar(string? path, int size) {
            if (path != null && path.length > 0) {
                string p = path.has_prefix("file://")
                    ? GLib.Uri.unescape_string(path.substring(7))
                    : path;
                if (GLib.FileUtils.test(p, GLib.FileTest.EXISTS)) {
                    try {
                        var pixbuf = new Gdk.Pixbuf.from_file_at_scale(p, size, size, true);
                        var img = new Gtk.Image.from_paintable(Gdk.Texture.for_pixbuf(pixbuf));
                        img.pixel_size = size;
                        img.add_css_class("telegram-avatar");
                        img.overflow = Overflow.HIDDEN;
                        return img;
                    } catch {}
                }
            }
            var fb = new Gtk.Image.from_icon_name("avatar-default-symbolic");
            fb.pixel_size = size;
            fb.add_css_class("telegram-avatar");
            fb.add_css_class("telegram-avatar-fallback");
            return fb;
        }
    }
}

public class MessagingDockPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private MessagingDock.Extension? extension;
    private Gtk.CssProvider? css_provider = null;

    private const string CSS = """
.dock-suffix-bubble.telegram-avatar-bubble {
    padding: 1px;
    background-color: transparent;
}
.dock-suffix-bubble.telegram-avatar-bubble:hover {
    background-color: alpha(@text_color, 0.15);
}
.telegram-avatar {
    border-radius: 9999px;
    background-color: alpha(@text_color, 0.10);
}
.telegram-avatar-fallback {
    color: alpha(@text_color, 0.7);
    padding: 3px;
}
.dock-suffix-badge.telegram-unread-badge {
    min-width: 14px;
    min-height: 14px;
    padding: 0 4px;
    font-size: 10px;
    margin-top: -3px;
    margin-right: -3px;
    box-shadow: 0 0 0 2px @window_bg_color;
}
""";

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        css_provider = new Gtk.CssProvider();
        css_provider.load_from_data(CSS.data);
        var display = Gdk.Display.get_default();
        if (display != null)
            Gtk.StyleContext.add_provider_for_display(
                display, css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        extension = new MessagingDock.Extension(ctx);
        context.add_dock_item_extension(extension);
    }

    public void deactivate() {
        if (extension != null) {
            extension.disconnect_signals();
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
