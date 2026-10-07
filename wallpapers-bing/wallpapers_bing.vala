using GLib;
using Gtk;
using Gee;
using Singularity;
using Singularity.Widgets;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(WallpapersBingPlugin));
}

namespace WallpapersBing {

    /**
     * Bing's daily wallpaper images, across every market. Requires the
     * external `ncz-wallpaper-bing` helper, which is not shipped by plain
     * Singularity -- this plugin is disabled by default.
     */
    public class Provider : WallpaperHelperProvider, WallpaperProvider {
        // Set by choices() from the helper's own answer, never re-derived
        // from the config file -- see WallpaperBing.CONSOLIDATED_ID. False
        // until the first choices() call, so the name starts as plain "Bing"
        // and the browser refreshes the label once the helper has replied.
        private bool combined = false;
        public string id { get { return WallpaperBing.PROVIDER_ID; } }
        // Matches the collection label the rotator helper writes for the
        // same de-duplicated view, so the online browser and the wallpaper
        // theme picker name one thing one way.
        public string display_name {
            owned get { return combined ? _("Bing (Combined, All Markets)") : _("Bing"); }
        }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }
        public Provider() { base("/usr/local/bin/ncz-wallpaper-bing"); }
        public async string market_list(Cancellable? cancel) throws Error {
            return yield command({helper, "markets"}, cancel, 30);
        }
        public async string preferred_market(Cancellable? cancel) throws Error {
            return (yield command({helper, "market"}, cancel, 30)).strip();
        }
        public async void set_preferred_market(string market, Cancellable? cancel) throws Error {
            yield command({helper, "market", market}, cancel, 30);
        }
        public async ArrayList<WallpaperProviderChoice> choices(string index, Cancellable? cancel) throws Error {
            var loaded = WallpaperBing.markets(yield command({helper, "markets"}, cancel, 30));
            // The helper is expected to always advertise the combined view
            // (it fetches every market), so this should unconditionally be
            // the only browsing axis -- per-market browsing is no longer
            // reachable through the picker.
            var only = WallpaperBing.combined_view(loaded);
            combined = only != null;
            if (!combined) {
                warning("wallpapers-bing: helper did not advertise the consolidated view " +
                    "(got %d raw market choices) -- the deployed helper may predate the " +
                    "always-combine contract change", loaded.size);
            }
            return only ?? loaded;
        }
        public async WallpaperProviderResult browse(string market, string query, int page,
                bool refresh, Cancellable? cancel) throws Error {
            var result = new WallpaperProviderResult();
            string selector = market == WallpaperBing.CONSOLIDATED_ID ? "--consolidated" : market;
            result.items = WallpaperBing.items(yield command({helper, "list", selector}, cancel, 60, refresh));
            return result;
        }
        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            throw new IOError.NOT_SUPPORTED("Bing wallpapers are already installed locally.");
        }
    }
}

public class WallpapersBingPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private WallpapersBing.Provider? provider;
    private const string BING_MARKETS_ID_ALL = "all";

    public void activate(PluginContext ctx) {
        this.context = ctx;
        provider = new WallpapersBing.Provider();
        context.add_wallpaper_provider(provider);
    }

    public void deactivate() {
        if (provider != null) {
            context.remove_wallpaper_provider(provider);
            provider = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 8);
        var lbl = new Label(_("Adds Bing's daily wallpaper images to the wallpaper browser. Requires the ncz-wallpaper-bing helper."));
        lbl.wrap = true;
        lbl.xalign = 0;
        box.append(lbl);
        load_bing_markets.begin(box);
        return box;
    }

    private async void load_bing_markets(Box box) {
        if (provider == null) return;
        var bing_markets_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
        bing_markets_options.add(new Singularity.Core.AppSettingOption() { id = BING_MARKETS_ID_ALL, label = _("All Markets, No Preference") });
        string bing_markets_current = BING_MARKETS_ID_ALL;
        try {
            foreach (string line in (yield provider.market_list(null)).split("\n")) {
                string[] columns = line.split("\t");
                if (columns.length < 2 || columns[0].strip() == "") continue;
                bing_markets_options.add(new Singularity.Core.AppSettingOption() {
                    id = columns[0].strip(), label = columns[1].strip() });
            }
            string configured = yield provider.preferred_market(null);
            if (configured.ascii_down() != BING_MARKETS_ID_ALL) {
                foreach (var option in bing_markets_options) {
                    if (option.id == configured) bing_markets_current = configured;
                }
            }
        } catch (Error e) {
            warning("wallpapers-bing: could not load market settings: %s", e.message);
            return;
        }
        var bing_markets_row = new SelectionRow.with_options(_("Bing Preferred Region"), bing_markets_options,
            bing_markets_current);
        bing_markets_row.subtitle = _("Bing always combines every region's photo of the day; this only picks whose caption and credit win when the same photo is shared");
        bing_markets_row.selected.connect((id) => {
            persist_bing_market.begin(id);
        });
        box.append(bing_markets_row);
    }

    private async void persist_bing_market(string market) {
        if (provider == null) return;
        try {
            yield provider.set_preferred_market(market, null);
        } catch (Error e) {
            warning("wallpapers-bing: could not save preferred market: %s", e.message);
        }
    }
}
