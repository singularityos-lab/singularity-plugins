using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(PomodoroPlugin));
}

public class PomodoroPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Box container;
    private Button toggle_btn;
    private Label time_label;
    private uint timer_id = 0;
    private int seconds_left = 0;
    private bool running = false;
    private bool in_break = false;

    // Settings (in minutes)
    private int work_duration = 25;
    private int break_duration = 5;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        container = new Box(Orientation.HORIZONTAL, 4);
        container.add_css_class("pomodoro-widget");
        container.valign = Align.CENTER;

        toggle_btn = new Button.from_icon_name("media-playback-start-symbolic");
        toggle_btn.add_css_class("flat");
        toggle_btn.add_css_class("panel-button");
        toggle_btn.tooltip_text = "Start Pomodoro";
        toggle_btn.clicked.connect(toggle_timer);
        container.append(toggle_btn);

        time_label = new Label("%d:00".printf(work_duration));
        time_label.add_css_class("caption-heading");
        time_label.add_css_class("pomodoro-time");
        time_label.valign = Align.CENTER;
        container.append(time_label);

        reset_timer();
        context.add_panel_widget(container, Align.END);
    }

    public void deactivate() {
        stop_timer();
        if (container != null) {
            context.remove_panel_widget(container);
            container = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 12);
        box.margin_top = 12;
        box.margin_bottom = 12;
        box.margin_start = 12;
        box.margin_end = 12;

        var work_row = new Box(Orientation.HORIZONTAL, 8);
        var work_lbl = new Label("Work duration (min):");
        work_lbl.hexpand = true;
        work_lbl.halign = Align.START;
        work_row.append(work_lbl);
        var work_spin = new SpinButton.with_range(1, 120, 1);
        work_spin.value = work_duration;
        work_spin.value_changed.connect(() => {
            work_duration = (int) work_spin.value;
            if (!running) reset_timer();
        });
        work_row.append(work_spin);
        box.append(work_row);

        var break_row = new Box(Orientation.HORIZONTAL, 8);
        var break_lbl = new Label("Break duration (min):");
        break_lbl.hexpand = true;
        break_lbl.halign = Align.START;
        break_row.append(break_lbl);
        var break_spin = new SpinButton.with_range(1, 60, 1);
        break_spin.value = break_duration;
        break_spin.value_changed.connect(() => {
            break_duration = (int) break_spin.value;
        });
        break_row.append(break_spin);
        box.append(break_row);

        return box;
    }

    private void toggle_timer() {
        if (running) {
            stop_timer();
        } else {
            start_timer();
        }
    }

    private void start_timer() {
        running = true;
        toggle_btn.icon_name = "media-playback-stop-symbolic";
        toggle_btn.tooltip_text = "Stop Pomodoro";
        timer_id = Timeout.add_seconds(1, tick);
    }

    private void stop_timer() {
        if (timer_id != 0) {
            Source.remove(timer_id);
            timer_id = 0;
        }
        running = false;
        in_break = false;
        if (toggle_btn != null) {
            toggle_btn.icon_name = "media-playback-start-symbolic";
            toggle_btn.tooltip_text = "Start Pomodoro";
        }
        reset_timer();
    }

    private bool tick() {
        seconds_left--;
        update_label();

        if (seconds_left <= 0) {
            timer_id = 0;
            running = false;
            if (!in_break) {
                context.notify("Pomodoro", "Work session complete! Time for a break.");
                in_break = true;
                seconds_left = break_duration * 60;
            } else {
                context.notify("Pomodoro", "Break over! Ready for next work session?");
                in_break = false;
                seconds_left = work_duration * 60;
            }
            if (toggle_btn != null) {
                toggle_btn.icon_name = "media-playback-start-symbolic";
                toggle_btn.tooltip_text = "Start Pomodoro";
            }
            update_label();
            return false;
        }
        return true;
    }

    private void reset_timer() {
        in_break = false;
        seconds_left = work_duration * 60;
        update_label();
    }

    private void update_label() {
        if (time_label == null) return;
        int m = seconds_left / 60;
        int s = seconds_left % 60;
        time_label.label = "%d:%02d".printf(m, s);
        if (in_break) {
            time_label.add_css_class("pomodoro-break");
            time_label.remove_css_class("pomodoro-work");
        } else {
            time_label.add_css_class("pomodoro-work");
            time_label.remove_css_class("pomodoro-break");
        }
    }
}
