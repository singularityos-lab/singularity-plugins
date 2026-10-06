namespace LauncherEntryDock {

    public class EntryState {
        public string app_id;
        public string desktop_id;
        public int64 count;
        public bool count_visible;
        public double progress;
        public bool progress_visible;
        public bool urgent;
        public string? label;
        public int64 updated_at;
        public string? sender;
        public bool app_owned;

        public bool is_visible() {
            return count_visible || progress_visible || urgent;
        }

        public void merge(Variant props) {
            var c = unbox(props.lookup_value("count", null));
            if (c != null) {
                if (c.is_of_type(VariantType.INT64)) count = c.get_int64();
                else if (c.is_of_type(VariantType.INT32)) count = c.get_int32();
            }
            var cv = unbox(props.lookup_value("count-visible", null));
            if (cv != null && cv.is_of_type(VariantType.BOOLEAN)) count_visible = cv.get_boolean();
            var p = unbox(props.lookup_value("progress", null));
            if (p != null && p.is_of_type(VariantType.DOUBLE)) progress = p.get_double();
            var pv = unbox(props.lookup_value("progress-visible", null));
            if (pv != null && pv.is_of_type(VariantType.BOOLEAN)) progress_visible = pv.get_boolean();
            var u = unbox(props.lookup_value("urgent", null));
            if (u != null && u.is_of_type(VariantType.BOOLEAN)) urgent = u.get_boolean();
            var lbl = unbox(props.lookup_value("label", null));
            if (lbl != null && lbl.is_of_type(VariantType.STRING)) label = lbl.get_string();
            else if (count == 0) label = null;
        }

        private static Variant? unbox(Variant? v) {
            if (v != null && v.is_of_type(VariantType.VARIANT)) return v.get_variant();
            return v;
        }

        public static string? app_id_from_uri(string? uri) {
            string? desktop = desktop_id_from_uri(uri);
            return desktop != null ? desktop.down() : null;
        }

        public static string? desktop_id_from_uri(string? uri) {
            if (uri == null || uri.length == 0) return null;
            string s = uri;
            if (s.has_prefix("application://")) s = s.substring("application://".length);
            if (s.has_suffix(".desktop")) s = s.substring(0, s.length - ".desktop".length);
            return s.length > 0 ? s : null;
        }
    }

    public class EntryStore {
        public Gee.HashMap<string, EntryState> entries = new Gee.HashMap<string, EntryState>();

        public EntryState update(string uri, string? sender, Variant props) {
            string app_id = EntryState.app_id_from_uri(uri);
            var state = entries.has_key(app_id) ? entries[app_id] : new EntryState();
            state.app_id = app_id;
            state.desktop_id = EntryState.desktop_id_from_uri(uri);
            if (state.sender != sender) state.app_owned = false;
            state.sender = sender;
            state.merge(props);
            state.updated_at = GLib.get_monotonic_time();
            if (state.is_visible()) entries[app_id] = state;
            else entries.unset(app_id);
            return state;
        }

        public bool sender_vanished(string sender) {
            var gone = new Gee.ArrayList<string>();
            foreach (var entry in entries.entries) {
                if (entry.value.app_owned && entry.value.sender == sender) gone.add(entry.key);
            }
            foreach (var key in gone) entries.unset(key);
            return gone.size > 0;
        }

        public string to_data() {
            var kf = new KeyFile();
            foreach (var state in entries.values) {
                string g = state.desktop_id;
                kf.set_int64(g, "count", state.count);
                kf.set_boolean(g, "count-visible", state.count_visible);
                kf.set_double(g, "progress", state.progress);
                kf.set_boolean(g, "progress-visible", state.progress_visible);
                kf.set_boolean(g, "urgent", state.urgent);
                if (state.label != null) kf.set_string(g, "label", state.label);
                if (state.sender != null) kf.set_string(g, "sender", state.sender);
                kf.set_boolean(g, "app-owned", state.app_owned);
            }
            return kf.to_data();
        }

        public void load_data(string data) {
            var kf = new KeyFile();
            try {
                kf.load_from_data(data, -1, KeyFileFlags.NONE);
            } catch (Error e) {
                return;
            }
            foreach (var g in kf.get_groups()) {
                var state = new EntryState();
                state.desktop_id = g;
                state.app_id = g.down();
                try {
                    state.count = kf.get_int64(g, "count");
                    state.count_visible = kf.get_boolean(g, "count-visible");
                    state.progress = kf.get_double(g, "progress");
                    state.progress_visible = kf.get_boolean(g, "progress-visible");
                    state.urgent = kf.get_boolean(g, "urgent");
                    state.app_owned = kf.get_boolean(g, "app-owned");
                    if (kf.has_key(g, "label")) state.label = kf.get_string(g, "label");
                    if (kf.has_key(g, "sender")) state.sender = kf.get_string(g, "sender");
                } catch (Error e) {
                    continue;
                }
                if (state.is_visible()) entries[state.app_id] = state;
            }
        }
    }
}
