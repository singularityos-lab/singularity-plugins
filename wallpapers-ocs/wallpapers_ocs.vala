using GLib;
using Gtk;
using Gee;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(WallpapersOcsPlugin));
}

namespace WallpapersOcs {

    /**
     * Wallpapers from OCS networks (pling.com, opendesktop.org,
     * kde-look.org, ...). Requires the external `ncz-wallpaper-ocs` helper
     * (shipped by distros that provide OCS access, not by plain Singularity)
     * -- exactly like the Tailscale VPN plugin needs a running tailscaled.
     */
    public class Provider : WallpaperHelperProvider, WallpaperProvider {
        // OCS answers `pagesize` items per request and its own default is 10,
        // not the ~50 the aggregate crawl was written against. Ask for the
        // server's maximum page size (100; anything above is rejected with
        // statuscode 400) so a single request per category returns a real
        // fraction of what a category holds instead of a token sample.
        private const string OCS_PAGE_SIZE = "100";
        public string id { get { return "ocs"; } }
        public string display_name { owned get { return _("OCS Network"); } }
        public bool requires_credentials { get { return false; } }
        public bool supports_search { get { return false; } }
        public Provider() { base("/usr/local/bin/ncz-wallpaper-ocs"); }
        public async ArrayList<WallpaperProviderChoice> choices(string index, Cancellable? cancel) throws Error {
            return WallpaperOcs.categories(yield command({helper, "index"}, cancel, 90), id);
        }
        public async WallpaperProviderResult browse(string category, string query, int page,
                bool refresh, Cancellable? cancel) throws Error {
            string[] identity = category.split(":");
            if (identity.length != 2 || !WallpaperOcs.provider_id(identity[0]) ||
                !WallpaperOcs.numeric_id(identity[1]))
                throw new WallpaperOcsError.INVALID("Invalid aggregate OCS category identity");
            string network = identity[0];
            string network_category = identity[1];
            string data = yield command({helper, "browse", network, network_category,
                "--pages", "1", "--page-size", OCS_PAGE_SIZE}, cancel, 60, refresh);
            var result = new WallpaperProviderResult();
            result.items = WallpaperOcs.items(data, network, network_category);
            var response = WallpaperOcs.document(data);
            var failed = response.get_member("failed_networks");
            if (failed != null && failed.get_node_type() == Json.NodeType.ARRAY && failed.get_array().get_length() > 0)
                result.warning = "Some OCS networks could not be reached.";
            var stale = response.get_member("stale");
            result.stale = stale != null && stale.get_value_type() == typeof(bool) && stale.get_boolean();
            if (result.stale) result.warning = "Using cached OCS results after refresh failure.";
            return result;
        }
        public async string import_item(WallpaperItem item, Cancellable? cancel) throws Error {
            return yield command({helper, "import", item.provider_id, item.id}, cancel, 600);
        }
    }
}

public class WallpapersOcsPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private WallpapersOcs.Provider? provider;

    public void activate(PluginContext ctx) {
        this.context = ctx;
        provider = new WallpapersOcs.Provider();
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
        var lbl = new Label(_("Adds OCS network wallpapers (pling.com, opendesktop.org, kde-look.org) to the wallpaper browser. Requires the ncz-wallpaper-ocs helper."));
        lbl.wrap = true;
        lbl.xalign = 0;
        box.append(lbl);
        return box;
    }
}
