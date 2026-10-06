using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(QuickNotesPlugin));
}

public class QuickNotesPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Box sidebar_widget;
    private Gtk.TextView text_view;
    private Singularity.Notes.NoteStore store;
    private Singularity.Notes.Note? current = null;
    private ulong store_changed_id = 0;
    private bool loading = false;
    private uint save_timer_id = 0;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        store = Singularity.Notes.NoteStore.get_default();

        sidebar_widget = new Box(Orientation.VERTICAL, 8);
        sidebar_widget.add_css_class("quick-notes-widget");
        sidebar_widget.margin_bottom = 12;

        var header = new Box(Orientation.HORIZONTAL, 8);
        var icon = new Image.from_icon_name("accessories-text-editor-symbolic");
        icon.pixel_size = 16;
        header.append(icon);
        var title = new Label(_("Quick Notes"));
        title.add_css_class("caption-heading");
        title.halign = Align.START;
        title.hexpand = true;
        header.append(title);
        sidebar_widget.append(header);

        var scroll = new ScrolledWindow();
        scroll.set_size_request(-1, 160);
        scroll.vexpand = false;

        text_view = new Gtk.TextView();
        text_view.add_css_class("card");
        text_view.wrap_mode = Gtk.WrapMode.WORD_CHAR;
        text_view.left_margin = 8;
        text_view.right_margin = 8;
        text_view.top_margin = 8;
        text_view.bottom_margin = 8;
        scroll.set_child(text_view);
        sidebar_widget.append(scroll);

        load_notes();

        text_view.buffer.changed.connect(schedule_save);
        store_changed_id = store.changed.connect(() => {
            if (save_timer_id == 0) load_notes();
        });

        context.add_sidebar_widget(sidebar_widget);
    }

    public void deactivate() {
        if (save_timer_id != 0) {
            Source.remove(save_timer_id);
            save_timer_id = 0;
            save_notes();
        }
        if (store_changed_id != 0) {
            store.disconnect(store_changed_id);
            store_changed_id = 0;
        }
        if (sidebar_widget != null) {
            context.remove_sidebar_widget(sidebar_widget);
            sidebar_widget = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var lbl = new Label(_("Quick Notes are saved automatically and appear as a pinned note in Notes."));
        lbl.margin_top = 12;
        lbl.margin_bottom = 12;
        lbl.margin_start = 12;
        lbl.margin_end = 12;
        lbl.wrap = true;
        lbl.halign = Align.START;
        return lbl;
    }

    private void load_notes() {
        if (text_view == null) return;
        var note = store.lookup(Singularity.Notes.NoteStore.QUICK_NOTE_ID);
        current = note != null ? note.copy() : null;
        show_text(note != null ? note.body : "");
    }

    private void show_text(string body) {
        if (text_view.buffer.text == body) return;
        Gtk.TextIter it;
        text_view.buffer.get_iter_at_mark(out it, text_view.buffer.get_insert());
        int offset = it.get_offset();
        loading = true;
        text_view.buffer.text = body;
        loading = false;
        text_view.buffer.get_iter_at_offset(out it, int.min(offset, text_view.buffer.get_char_count()));
        text_view.buffer.place_cursor(it);
    }

    private void schedule_save() {
        if (loading) return;
        if (save_timer_id != 0) {
            Source.remove(save_timer_id);
        }
        save_timer_id = Timeout.add(1500, () => {
            save_timer_id = 0;
            save_notes();
            return false;
        });
    }

    private void save_notes() {
        if (text_view == null) return;
        string content = text_view.buffer.text;
        try {
            if (content.strip() == "") {
                if (current != null && !store.remove_unchanged(current)) load_notes();
                current = null;
                return;
            }
            var note = current ?? store.ensure(Singularity.Notes.NoteStore.QUICK_NOTE_ID, true).copy();
            if (note.body == content) return;
            note.body = content;
            store.save(note);
            current = note.copy();
            show_text(note.body);
        } catch (Error e) {
            warning("QuickNotes: Failed to save: %s", e.message);
        }
    }
}
