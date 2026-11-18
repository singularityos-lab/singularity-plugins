using GLib;
using Gtk;
using Gee;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(WallpapersBingPlugin));
}

namespace WallpapersBing {

    private const uint REFRESH_SECONDS = 86400;
    private const uint MAX_BACKOFF_SECONDS = 3600;

    public class Provider : WallpaperHelperProvider, WallpaperProvider {
        // Set by choices() from the helper's own answer, never re-derived
        // from the config file -- see WallpaperBing.CONSOLIDATED_ID. False
        // until the first choices() call, so the name starts as plain "Bing"
        // and the browser refreshes the label once the helper has replied.
        private bool combined = false;
        private bool prefetching = false;
        private int failures = 0;
        private uint refresh_source = 0;
        private ulong network_handler = 0;
        private Cancellable cancel_all = new Cancellable();
        public string id { get { return WallpaperBing.PROVIDER_ID; } }
        // Matches the collection label the rotator helper writes for the
        // same de-duplicated view, so the online browser and the wallpaper
        // theme picker name one thing one way.
        public string display_name {
            owned get { return combined ? _("Bing (Combined, All Markets)") : _("Bing"); }
        }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }
        public Provider() { base("singularity-wallpaper-bing"); }
        public void start_prefetch() {
            cancel_all = new Cancellable();
            if (network_handler == 0)
                network_handler = NetworkMonitor.get_default().network_changed.connect(() => {
                    if (failures > 0 || refresh_source == 0) prefetch();
                });
            prefetch();
        }

        public void stop_prefetch() {
            cancel_all.cancel();
            if (refresh_source != 0) Source.remove(refresh_source);
            refresh_source = 0;
            if (network_handler != 0) NetworkMonitor.get_default().disconnect(network_handler);
            network_handler = 0;
        }

        private void prefetch() {
            var monitor = NetworkMonitor.get_default();
            if (prefetching || cancel_all.is_cancelled() || !monitor.network_available || monitor.network_metered)
                return;
            prefetching = true;
            run_prefetch.begin();
        }

        private async void run_prefetch() {
            // Hold this run's own Cancellable: stop_prefetch() followed by
            // start_prefetch() replaces cancel_all while a fetch is in flight.
            var cancel = cancel_all;
            bool ok = false;
            try {
                yield command({helper, "fetch", "--if-stale"}, cancel, 900);
                ok = true;
            } catch (Error e) {
                if (!cancel.is_cancelled()) warning("wallpapers-bing: prefetch failed: %s", e.message);
            }
            prefetching = false;
            if (cancel.is_cancelled()) return;
            failures = ok ? 0 : failures + 1;
            uint delay = ok ? REFRESH_SECONDS : uint.min(30U << uint.min(failures - 1, 7U), MAX_BACKOFF_SECONDS);
            if (refresh_source != 0) Source.remove(refresh_source);
            refresh_source = Timeout.add_seconds(delay, () => {
                refresh_source = 0;
                prefetch();
                return Source.REMOVE;
            });
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

    public void activate(PluginContext ctx) {
        this.context = ctx;
        provider = new WallpapersBing.Provider();
        context.add_wallpaper_provider(provider);
        provider.start_prefetch();
    }

    public void deactivate() {
        if (provider != null) {
            provider.stop_prefetch();
            context.remove_wallpaper_provider(provider);
            provider = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 8);
        var lbl = new Label(_("Adds Bing's daily wallpaper images to the wallpaper browser. Requires the singularity-wallpaper-bing helper."));
        lbl.wrap = true;
        lbl.xalign = 0;
        box.append(lbl);
        return box;
    }
}
