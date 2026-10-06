using Gtk;
using Singularity;
using Peas;
using GLib;
using Gdk;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(ClipboardHistoryPlugin));
}

private class ClipEntry : Object {
    public string? text;
    public Gdk.Texture? image;
    public ClipEntry.with_text(string t) { text = t; }
    public ClipEntry.with_image(Gdk.Texture i) { image = i; }
}

public class ClipboardHistoryPlugin : Object, Singularity.Plugin {
    private const int MAX_ENTRIES = 20;
    private const int PREVIEW_LEN = 60;
    private PluginContext context;
    private MenuButton panel_btn;
    private Popover popover;
    private ListBox list_box;
    private Gdk.Clipboard clipboard;
    private ulong changed_handler = 0;
    private List<ClipEntry> history = new List<ClipEntry>();

    public void activate(PluginContext ctx) {
        this.context = ctx;

        panel_btn = new MenuButton();
        panel_btn.icon_name = "edit-paste-symbolic";
        panel_btn.add_css_class("flat");
        panel_btn.add_css_class("panel-button");
        panel_btn.tooltip_text = "Clipboard History";

        var popover_box = new Box(Orientation.VERTICAL, 0);

        var header = new Label("Clipboard History");
        header.add_css_class("heading");
        header.margin_top = 8;
        header.margin_bottom = 4;
        header.margin_start = 12;
        header.margin_end = 12;
        header.halign = Align.START;
        popover_box.append(header);

        var clear_btn = new Button.with_label("Clear");
        clear_btn.add_css_class("flat");
        clear_btn.add_css_class("destructive-action");
        clear_btn.halign = Align.END;
        clear_btn.margin_end = 8;
        clear_btn.clicked.connect(() => {
            history = new List<ClipEntry>();
            rebuild_list();
        });
        popover_box.append(clear_btn);

        var scrolled = new ScrolledWindow();
        scrolled.set_size_request(280, -1);
        scrolled.max_content_height = 360;
        scrolled.propagate_natural_height = true;

        list_box = new ListBox();
        list_box.selection_mode = SelectionMode.NONE;
        list_box.add_css_class("boxed-list");
        scrolled.set_child(list_box);
        popover_box.append(scrolled);

        popover = new Popover();
        popover.set_child(popover_box);
        panel_btn.popover = popover;

        context.add_panel_widget(panel_btn, Align.END);

        clipboard = Gdk.Display.get_default().get_clipboard();
        changed_handler = clipboard.changed.connect(on_clipboard_changed);
    }

    public void deactivate() {
        if (changed_handler != 0 && clipboard != null) {
            clipboard.disconnect(changed_handler);
            changed_handler = 0;
        }
        if (panel_btn != null) {
            context.remove_panel_widget(panel_btn);
            panel_btn = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return new Label("Stores up to %d clipboard entries.".printf(MAX_ENTRIES));
    }

    private void on_clipboard_changed() {
        var formats = clipboard.get_formats();
        if (formats != null && formats.contain_mime_type("x-kde-passwordManagerHint")) return;
        // Prefer an image when the clipboard offers one, otherwise fall back to
        // text. read_text_async returns null for image-only offers, which is
        // why images never showed up before.
        if (formats != null && formats.contain_gtype(typeof(Gdk.Texture))) {
            clipboard.read_texture_async.begin(null, (obj, res) => {
                try {
                    var tex = clipboard.read_texture_async.end(res);
                    if (tex != null) add_entry(new ClipEntry.with_image(tex));
                } catch {}
            });
            return;
        }
        clipboard.read_text_async.begin(null, (obj, res) => {
            try {
                string? text = clipboard.read_text_async.end(res);
                if (text == null || text.length == 0) return;
                add_entry(new ClipEntry.with_text(text));
            } catch {}
        });
    }

    private void add_entry(ClipEntry entry) {
        // Dedup text entries against the most recent and any earlier copy.
        if (entry.text != null) {
            if (history.length() > 0 && history.data.text == entry.text) return;
            unowned List<ClipEntry>? cur = history;
            while (cur != null) {
                if (cur.data.text == entry.text) { history.remove_link(cur); break; }
                cur = cur.next;
            }
        }
        history.prepend(entry);
        while (history.length() > MAX_ENTRIES) {
            history.delete_link(history.last());
        }
        rebuild_list();
    }

    private void rebuild_list() {
        Widget? child = list_box.get_first_child();
        while (child != null) {
            Widget? next = child.get_next_sibling();
            list_box.remove(child);
            child = next;
        }

        if (history.length() == 0) {
            var empty_label = new Label("No clipboard history yet");
            empty_label.add_css_class("dim-label");
            empty_label.margin_top = 12;
            empty_label.margin_bottom = 12;
            list_box.append(empty_label);
            return;
        }

        foreach (ClipEntry entry in history) {
            var row = new ListBoxRow();
            var btn = new Button();
            btn.add_css_class("flat");

            if (entry.image != null) {
                var pic = new Gtk.Picture.for_paintable(entry.image);
                pic.content_fit = Gtk.ContentFit.CONTAIN;
                pic.set_size_request(-1, 56);
                pic.halign = Align.START;
                btn.set_child(pic);
                var tex = entry.image;
                btn.clicked.connect(() => {
                    var v = GLib.Value(typeof(Gdk.Texture));
                    v.set_object(tex);
                    clipboard.set_content(new Gdk.ContentProvider.for_value(v));
                    popover.popdown();
                });
            } else {
                var preview = entry.text.replace("\n", " ").replace("\t", " ");
                if (preview.char_count() > PREVIEW_LEN) {
                    preview = preview.substring(0, preview.index_of_nth_char(PREVIEW_LEN)) + "…";
                }
                var lbl = new Label(preview);
                lbl.halign = Align.START;
                lbl.ellipsize = Pango.EllipsizeMode.END;
                lbl.xalign = 0;
                btn.set_child(lbl);
                string entry_copy = entry.text;
                btn.clicked.connect(() => {
                    clipboard.set_text(entry_copy);
                    popover.popdown();
                });
            }

            row.set_child(btn);
            list_box.append(row);
        }
    }
}
