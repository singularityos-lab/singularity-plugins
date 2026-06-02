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

public class ClipboardHistoryPlugin : Object, Singularity.Plugin {
    private const int MAX_ENTRIES = 20;
    private const int PREVIEW_LEN = 60;
    private PluginContext context;
    private MenuButton panel_btn;
    private Popover popover;
    private ListBox list_box;
    private Gdk.Clipboard clipboard;
    private ulong changed_handler = 0;
    private List<string> history = new List<string>();

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
            history = new List<string>();
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
        clipboard.read_text_async.begin(null, (obj, res) => {
            try {
                string? text = clipboard.read_text_async.end(res);
                if (text == null || text.length == 0) return;
                // Dedup: if same as most recent, skip
                if (history.length() > 0 && history.data == text) return;
                // Remove existing occurrence
                unowned List<string>? existing = history.find_custom(text, strcmp);
                if (existing != null) history.remove_link(existing);
                // Prepend new entry
                history.prepend(text);
                // Trim to max
                while (history.length() > MAX_ENTRIES) {
                    history.delete_link(history.last());
                }
                rebuild_list();
            } catch {}
        });
    }

    private void rebuild_list() {
        // Clear existing rows
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

        foreach (string entry in history) {
            var row = new ListBoxRow();
            var btn = new Button();
            btn.add_css_class("flat");

            var preview = entry.replace("\n", " ").replace("\t", " ");
            if (preview.char_count() > PREVIEW_LEN) {
                preview = preview.substring(0, preview.index_of_nth_char(PREVIEW_LEN)) + "…";
            }
            var lbl = new Label(preview);
            lbl.halign = Align.START;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.xalign = 0;
            btn.set_child(lbl);

            string entry_copy = entry;
            btn.clicked.connect(() => {
                clipboard.set_text(entry_copy);
                popover.popdown();
            });

            row.set_child(btn);
            list_box.append(row);
        }
    }
}
