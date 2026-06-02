using Gtk;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(NotificationTestPlugin));
}

public class NotificationTestPlugin : Object, Singularity.Plugin {
    private PluginContext context;

    public void activate(PluginContext context) {
        this.context = context;
        context.notify("Plugin Loaded", "The Notification Test Plugin has been activated!");
    }

    public void deactivate() {
        // Nothing to cleanup
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 10);
        box.append(new Label("Notification Test Plugin"));
        var btn = new Button.with_label("Send Test Notification");
        btn.clicked.connect(() => {
             if (context != null) {
                 context.notify("Manual Trigger", "Button clicked!");
             }
        });
        box.append(btn);
        return box;
    }
}
