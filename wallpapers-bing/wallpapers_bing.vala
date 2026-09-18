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

// Bing market row: 2-letter market code, UI display label, and region
// bucket ("Americas" / "Europe" / "Asia-Pacific") used as the label
// prefix in the settings SelectionRow's option list. Plain GLib.Object
// rather than a struct so it can be stored in a Gee.ArrayList (Vala
// disallows array types as generic type arguments).
private class BingMarketEntry : GLib.Object {
    public string code { get; set; }
    public string label { get; set; }
    public string region { get; set; }
}

public class WallpapersBingPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private WallpapersBing.Provider? provider;
    private const string BING_MARKETS_ID_ALL = "all";
    // 13 markets, grouped by region. Order matches the comment block in
    // cix-installer/post-install/45-wallpaper-rotator.sh's
    // ncz-wallpaper-bing (Americas, Europe, Asia-Pacific).
    // [0] = market code, [1] = display label, [2] = region header.
    private const string BING_MARKETS_TABLE = "en-US\tUnited States\tAmericas"
        + "|en-CA\tCanada English\tAmericas"
        + "|fr-CA\tCanada French\tAmericas"
        + "|pt-BR\tBrazil\tAmericas"
        + "|en-GB\tUnited Kingdom\tEurope"
        + "|fr-FR\tFrance\tEurope"
        + "|de-DE\tGermany\tEurope"
        + "|es-ES\tSpain\tEurope"
        + "|it-IT\tItaly\tEurope"
        + "|en-IN\tIndia\tAsia-Pacific"
        + "|ja-JP\tJapan\tAsia-Pacific"
        + "|zh-CN\tChina\tAsia-Pacific"
        + "|ko-KR\tSouth Korea\tAsia-Pacific";
    private Gee.ArrayList<BingMarketEntry> bing_markets_rows = new Gee.ArrayList<BingMarketEntry>();
    private SelectionRow? bing_markets_row = null;
    private bool bing_markets_updating = false;

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

        // Preferred-region selector. Every market is always fetched and
        // combined by the ncz-wallpaper-bing helper; this only sets which
        // region's copy of a duplicate photo wins the caption/credit when
        // the same photo is shared across regions -- see
        // ~/.config/ncz-wallpaper/bing-markets, which
        // 45-wallpaper-rotator.sh's ncz-wallpaper-bing reads verbatim.
        // A single inline SelectionRow (not a popup dialog): "All
        // Markets, No Preference" first, then all 13 markets from
        // BING_MARKETS_TABLE labelled "<Region> - <Market>" so the region
        // grouping survives as label text without section headers.
        init_bing_markets_table();
        var bing_markets_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
        bing_markets_options.add(new Singularity.Core.AppSettingOption() { id = BING_MARKETS_ID_ALL, label = _("All Markets, No Preference") });
        foreach (var market in bing_markets_rows) {
            bing_markets_options.add(new Singularity.Core.AppSettingOption() {
                id = market.code, label = "%s - %s".printf(market.region, market.label) });
        }
        // Initial selection reflects the file: "all" or absent = All
        // Markets; otherwise the first configured market code (a
        // preference is singular). Falls back to "all" if the file names
        // a code that isn't in the current table, so the row always
        // opens on a real entry.
        string bing_markets_current = BING_MARKETS_ID_ALL;
        if (!bing_markets_file_is_all()) {
            string[] configured = bing_markets_read_codes();
            if (configured.length > 0) {
                foreach (var opt in bing_markets_options) {
                    if (opt.id == configured[0]) { bing_markets_current = configured[0]; break; }
                }
            }
        }
        bing_markets_row = new SelectionRow.with_options(_("Bing Preferred Region"), bing_markets_options,
            bing_markets_current);
        bing_markets_row.subtitle = _("Bing always combines every region's photo of the day; this only picks whose caption and credit win when the same photo is shared");
        bing_markets_row.selected.connect((id) => {
            if (bing_markets_updating || bing_markets_row == null) return;
            if (id == BING_MARKETS_ID_ALL) {
                write_bing_markets_all();
            } else {
                write_bing_markets_codes({id});
            }
        });
        box.append(bing_markets_row);
        return box;
    }

    // Lower-case an ASCII string. Vala's GLib string has no public
    // lowercase() (only casefold(), which is Unicode-aware and therefore
    // locale-sensitive -- the bing-market codes are all ISO 639-1 +
    // ISO 3166-1 letters, so a literal ASCII fold is both correct and
    // cheaper).
    private static string ascii_lower(string s) {
        string out = "";
        for (int i = 0; i < s.length; i++) {
            char c = s[i];
            if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
            out += c.to_string();
        }
        return out;
    }

    // Parse BING_MARKETS_TABLE into bing_markets_rows ({code, label,
    // region}), in table order. Called once per get_settings_widget()
    // build, before the SelectionRow option list is built from it.
    private void init_bing_markets_table() {
        bing_markets_rows.clear();
        foreach (string entry in BING_MARKETS_TABLE.split("|")) {
            string[] cols = entry.split("\t");
            if (cols.length != 3) continue;
            var row = new BingMarketEntry() { code = cols[0], label = cols[1], region = cols[2] };
            bing_markets_rows.add(row);
        }
    }

    // Full path to the bing-markets file the cix-installer rotator
    // already reads. Lives under XDG_CONFIG_HOME so it tracks the user
    // even when $HOME is relocated for test sessions.
    private string bing_markets_file_path() {
        return GLib.Path.build_filename(
            GLib.Environment.get_user_config_dir(),
            "ncz-wallpaper",
            "bing-markets");
    }

    // Read the bing-markets file and report whether its content
    // (trimmed, lowercased) is the "all" sentinel -- i.e. "no preferred
    // region". Absent file also returns true so the SelectionRow starts
    // on "All Markets, No Preference" on a fresh install, matching the
    // rotator's own default (preferred_market() in
    // 45-wallpaper-rotator.sh returns None for an absent file too).
    private bool bing_markets_file_is_all() {
        string path = bing_markets_file_path();
        if (!FileUtils.test(path, FileTest.EXISTS)) return true;
        string text;
        try {
            FileUtils.get_contents(path, out text);
        } catch (Error e) {
            return true;
        }
        return ascii_lower(text.strip()) == "all";
    }

    // Read the bing-markets file and return the configured codes as an
    // array. "all" (any case) or absent -> empty list. Otherwise split
    // on any of whitespace/comma and keep tokens matching the
    // 2-letter-2-letter market pattern, preserving file order. Only the
    // FIRST entry is ever honoured as the preference, but every matched
    // token is returned so a legacy multi-market file degrades to "the
    // first one wins" rather than silently losing the whole value.
    private string[] bing_markets_read_codes() {
        string path = bing_markets_file_path();
        if (!FileUtils.test(path, FileTest.EXISTS)) return {};
        string text;
        try {
            FileUtils.get_contents(path, out text);
        } catch (Error e) {
            return {};
        }
        if (ascii_lower(text.strip()) == "all") return {};
        string[] codes = {};
        string[] seen = {};
        foreach (string tok in text.strip().split_set(" \t\n,")) {
            if (tok.length == 0) continue;
            if (tok.length != 5 || tok[2] != '-') continue;
            bool dup = false;
            foreach (string existing in seen) if (existing == tok) { dup = true; break; }
            if (dup) continue;
            seen += tok;
            codes += tok;
        }
        return codes;
    }

    // Atomic write of a single-line contents string to the bing-markets
    // file, so the daemon (which polls the file) never reads a
    // half-flushed value. Creates the directory if absent. Silent on
    // failure -- the daemon's default kicks in if the file is missing.
    private void write_bing_markets_contents(string contents) {
        string path = bing_markets_file_path();
        string dir = GLib.Path.get_dirname(path);
        try {
            GLib.DirUtils.create_with_parents(dir, 0700);
            string tmp = path + ".tmp";
            FileUtils.set_contents(tmp, contents);
            if (FileUtils.rename(tmp, path) != 0) {
                warning("bing markets: could not rename %s into place", path);
            }
        } catch (Error e) {
            warning("bing markets: could not write %s: %s", path, e.message);
        }
    }

    private void write_bing_markets_all() {
        write_bing_markets_contents("all\n");
    }

    // Write the chosen preferred market as a single line. Empty list ->
    // fall back to "all" rather than an empty file, making the user's
    // "no preferred region" intent explicit on disk.
    private void write_bing_markets_codes(string[] codes) {
        if (codes.length == 0) {
            write_bing_markets_all();
            return;
        }
        write_bing_markets_contents(string.joinv(" ", codes) + "\n");
    }
}
