using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(DiskUsagePlugin));
}

public class DiskUsagePlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Box sidebar_widget;
    private uint update_timer_id = 0;

    // Mount points to monitor
    private string[] mount_points;
    private Box[] mount_rows;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        sidebar_widget = new Box(Orientation.VERTICAL, 8);
        sidebar_widget.add_css_class("disk-usage-widget");
        sidebar_widget.margin_bottom = 12;

        var header = new Box(Orientation.HORIZONTAL, 8);
        var icon = new Image.from_icon_name("drive-harddisk-symbolic");
        icon.pixel_size = 16;
        header.append(icon);
        var title = new Label("Disk Usage");
        title.add_css_class("caption-heading");
        title.halign = Align.START;
        title.hexpand = true;
        header.append(title);
        sidebar_widget.append(header);

        // Collect valid, distinct mount points
        var valid_mounts = new GLib.List<string>();
        string home_dir = Environment.get_home_dir();
        string[] candidates = { "/", home_dir, "/home" };
        string? root_id = get_mount_device("/");

        foreach (var mp in candidates) {
            if (!FileUtils.test(mp, FileTest.IS_DIR)) continue;
            // Skip if same device as root (to avoid duplicates)
            if (mp != "/" && get_mount_device(mp) == root_id) continue;
            // Skip /home if we already have home_dir
            if (mp == "/home" && valid_mounts.find_custom("/home", strcmp) != null) continue;
            bool already = false;
            foreach (var v in valid_mounts) {
                if (v == mp) { already = true; break; }
            }
            if (!already) valid_mounts.append(mp);
        }

        // Make sure root is first
        if (valid_mounts.length() == 0) valid_mounts.append("/");

        mount_points = new string[valid_mounts.length()];
        mount_rows = new Box[valid_mounts.length()];
        int idx = 0;
        foreach (var mp in valid_mounts) {
            mount_points[idx] = mp;
            var row = create_mount_row(mp);
            mount_rows[idx] = row;
            sidebar_widget.append(row);
            idx++;
        }

        update_usage.begin();
        update_timer_id = Timeout.add_seconds(30, () => {
            update_usage.begin();
            return true;
        });

        context.add_sidebar_widget(sidebar_widget);
    }

    public void deactivate() {
        if (update_timer_id != 0) {
            Source.remove(update_timer_id);
            update_timer_id = 0;
        }
        if (sidebar_widget != null) {
            context.remove_sidebar_widget(sidebar_widget);
            sidebar_widget = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var lbl = new Label("Shows disk usage for / and home mount points. Updates every 30 seconds.");
        lbl.margin_top = 12;
        lbl.margin_bottom = 12;
        lbl.margin_start = 12;
        lbl.margin_end = 12;
        lbl.wrap = true;
        lbl.halign = Align.START;
        return lbl;
    }

    private string? get_mount_device(string path) {
        try {
            var file = File.new_for_path(path);
            var info = file.query_info(FileAttribute.ID_FILESYSTEM, FileQueryInfoFlags.NONE, null);
            return info.get_attribute_string(FileAttribute.ID_FILESYSTEM);
        } catch (Error e) {
            return null;
        }
    }

    private Box create_mount_row(string mount_point) {
        var row = new Box(Orientation.VERTICAL, 4);

        var info_row = new Box(Orientation.HORIZONTAL, 4);
        var name_lbl = new Label(mount_point == Environment.get_home_dir() ? "Home" : mount_point);
        name_lbl.add_css_class("caption");
        name_lbl.halign = Align.START;
        name_lbl.hexpand = true;
        info_row.append(name_lbl);

        var size_lbl = new Label("…");
        size_lbl.add_css_class("caption");
        size_lbl.add_css_class("dim-label");
        size_lbl.set_data<string>("role", "size");
        info_row.append(size_lbl);
        row.append(info_row);

        var progress = new ProgressBar();
        progress.add_css_class("disk-usage-bar");
        progress.set_data<string>("role", "progress");
        row.append(progress);

        return row;
    }

    private async void update_usage() {
        if (sidebar_widget == null) return;
        for (int idx = 0; idx < mount_points.length; idx++) {
            if (mount_rows[idx] == null) continue;
            string mp = mount_points[idx];
            yield update_mount_row(mount_rows[idx], mp);
        }
    }

    private async void update_mount_row(Box row, string mount_point) {
        try {
            var file = File.new_for_path(mount_point);
            var info = yield file.query_filesystem_info_async(
                FileAttribute.FILESYSTEM_FREE + "," + FileAttribute.FILESYSTEM_SIZE,
                Priority.LOW, null);

            uint64 total = info.get_attribute_uint64(FileAttribute.FILESYSTEM_SIZE);
            uint64 free  = info.get_attribute_uint64(FileAttribute.FILESYSTEM_FREE);
            uint64 used  = total > free ? total - free : 0;
            double fraction = total > 0 ? (double) used / (double) total : 0.0;

            // Update size label and progress bar
            var child = row.get_first_child();
            while (child != null) {
                if (child is Box) {
                    var sub = ((Box) child).get_first_child();
                    while (sub != null) {
                        if (sub is Label && sub.get_data<string>("role") == "size") {
                            ((Label) sub).label = "%s / %s".printf(
                                format_bytes(used), format_bytes(total));
                        }
                        sub = sub.get_next_sibling();
                    }
                } else if (child is ProgressBar && child.get_data<string>("role") == "progress") {
                    ((ProgressBar) child).fraction = fraction;
                }
                child = child.get_next_sibling();
            }
        } catch (Error e) {
            // Ignore - mount may be unavailable
        }
    }

    private string format_bytes(uint64 bytes) {
        if (bytes >= 1024 * 1024 * 1024) {
            return "%.1f GB".printf((double) bytes / (1024.0 * 1024.0 * 1024.0));
        } else if (bytes >= 1024 * 1024) {
            return "%.1f MB".printf((double) bytes / (1024.0 * 1024.0));
        } else {
            return "%.0f KB".printf((double) bytes / 1024.0);
        }
    }
}
