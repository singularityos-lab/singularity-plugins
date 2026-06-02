using GLib;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(EmojiSearchPlugin));
}

namespace EmojiSearch {

    /**
     * Minimal in-memory emoji search provider. Demonstrates the
     * SearchProvider contract; covers a handful of common emoji so the
     * plugin is genuinely useful while staying tiny.
     */
    public class Provider : Object, SearchProvider {
        public string id   { get { return "emoji"; } }
        public string name { get { return "Emoji"; } }

        // Tab-separated emoji + space-separated keywords. Kept short on
        // purpose - production emoji DBs are megabytes; this is a sample.
        private static string[] TABLE = {
            "😀\thappy smile face grin",
            "😂\tlaugh crying joy lol",
            "❤️\theart love red",
            "🔥\tfire hot lit flame",
            "👍\tthumbs up like ok approve",
            "👎\tthumbs down dislike",
            "🎉\tparty celebration tada",
            "🚀\trocket launch ship",
            "✨\tsparkle shiny magic",
            "🤔\tthink hmm wonder",
            "😴\tsleep tired zzz",
            "🍕\tpizza food",
            "☕\tcoffee tea drink",
            "🐍\tsnake python",
            "🐧\tpenguin linux",
            "🍎\tapple fruit mac",
            "💻\tlaptop computer",
            "🎵\tnote music sound",
            "📷\tcamera photo picture",
            "✅\tcheck done ok yes",
            "❌\tx no fail cross",
            "⚠️\twarning alert"
        };

        public async List<SearchResult> search(string text, GLib.Cancellable? cancellable) throws Error {
            var lower = text.down().strip();
            var results = new List<SearchResult>();
            if (lower.length == 0) return (owned) results;
            foreach (var line in TABLE) {
                if (cancellable != null && cancellable.is_cancelled()) break;
                int tab = line.index_of("\t");
                if (tab <= 0) continue;
                string emoji = line.substring(0, tab);
                string kws = line.substring(tab + 1).down();
                if (!kws.contains(lower)) continue;
                double score = kws.has_prefix(lower) ? 0.7 : 0.4;
                var r = new SearchResult(this, emoji, kws, null, null, null);
                r.score = score;
                r.activated.connect(() => {
                    var disp = Gdk.Display.get_default();
                    if (disp != null) disp.get_clipboard().set_text(emoji);
                });
                results.append(r);
            }
            return (owned) results;
        }
    }
}

public class EmojiSearchPlugin : Object, Singularity.Plugin {
    private Singularity.PluginContext context;
    private EmojiSearch.Provider? provider;

    public void activate(Singularity.PluginContext ctx) {
        this.context = ctx;
        provider = new EmojiSearch.Provider();
        context.add_search_provider(provider);
    }

    public void deactivate() {
        if (provider != null) {
            context.remove_search_provider(provider);
            provider = null;
        }
    }

    public Gtk.Widget? get_settings_widget() { return null; }
}
