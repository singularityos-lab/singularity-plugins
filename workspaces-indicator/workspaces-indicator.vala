using Gtk;
using Singularity;
using Peas;
using GLib;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(WorkspacesIndicatorPlugin));
}

public class WorkspacesIndicatorPlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Box container;
    private ulong workspaces_handler = 0;

    public void activate(PluginContext ctx) {
        this.context = ctx;

        container = new Box(Orientation.HORIZONTAL, 4);
        container.add_css_class("workspaces-indicator");
        container.valign = Align.CENTER;

        rebuild();
        workspaces_handler = context.workspaces_changed.connect(rebuild);
        context.add_panel_widget(container, Align.CENTER);
    }

    public void deactivate() {
        if (workspaces_handler != 0) {
            context.disconnect(workspaces_handler);
            workspaces_handler = 0;
        }
        if (container != null) {
            context.remove_panel_widget(container);
            container = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        return new Label("Shows workspace dots in the panel.");
    }

    private void rebuild() {
        Widget? child = container.get_first_child();
        while (child != null) {
            Widget? next = child.get_next_sibling();
            container.remove(child);
            child = next;
        }

        foreach (var ws in context.get_workspaces()) {
            var btn = new Button();
            btn.add_css_class("flat");
            btn.add_css_class("workspace-dot-btn");
            btn.tooltip_text = ws.name;

            var dot = new Label("●");
            dot.add_css_class("workspace-dot");
            if (ws.active) {
                dot.add_css_class("workspace-dot-active");
            }
            btn.set_child(dot);

            int ws_index = ws.index;
            btn.clicked.connect(() => {
                context.switch_workspace(ws_index);
            });

            container.append(btn);
        }
    }
}
