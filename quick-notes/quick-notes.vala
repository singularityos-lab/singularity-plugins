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
    private string notes_path;
    private uint save_timer_id = 0;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        string data_dir = GLib.Path.build_filename(
            Environment.get_user_data_dir(), "singularity");
        DirUtils.create_with_parents(data_dir, 0700);
        notes_path = GLib.Path.build_filename(data_dir, "quick-notes.txt");

        sidebar_widget = new Box(Orientation.VERTICAL, 8);
        sidebar_widget.add_css_class("quick-notes-widget");
        sidebar_widget.margin_bottom = 12;

        var header = new Box(Orientation.HORIZONTAL, 8);
        var icon = new Image.from_icon_name("accessories-text-editor-symbolic");
        icon.pixel_size = 16;
        header.append(icon);
        var title = new Label("Quick Notes");
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

        // Load existing notes
        load_notes();

        // Auto-save with debounce
        text_view.buffer.changed.connect(schedule_save);

        context.add_sidebar_widget(sidebar_widget);
    }

    public void deactivate() {
        if (save_timer_id != 0) {
            Source.remove(save_timer_id);
            save_timer_id = 0;
            save_notes();
        }
        if (sidebar_widget != null) {
            context.remove_sidebar_widget(sidebar_widget);
            sidebar_widget = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var lbl = new Label("Notes are saved automatically to ~/.local/share/singularity/quick-notes.txt");
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
        if (FileUtils.test(notes_path, FileTest.EXISTS)) {
            try {
                string content;
                FileUtils.get_contents(notes_path, out content);
                text_view.buffer.text = content;
            } catch (Error e) {
                warning("QuickNotes: Failed to load: %s", e.message);
            }
        }
    }

    private void schedule_save() {
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
        try {
            string content = text_view.buffer.text;
            FileUtils.set_contents(notes_path, content);
        } catch (Error e) {
            warning("QuickNotes: Failed to save: %s", e.message);
        }
    }
}
