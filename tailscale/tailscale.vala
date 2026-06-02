using GLib;
using Gtk;
using Singularity;
using Peas;

[ModuleInit]
public void peas_register_types(TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type(typeof(Singularity.Plugin), typeof(TailscalePlugin));
}

namespace Tailscale {

    /**
     * A single Tailscale node, toggled through the `tailscale` CLI. Tailscale
     * is not a NetworkManager connection (it runs its own daemon, tailscaled),
     * so it cannot be driven through libnm - we shell out to its CLI, which
     * the shell can reach directly because it runs on the host.
     */
    public class Connection : Object, Singularity.VpnConnection {
        private weak Provider _provider;
        private string _name = "Tailscale";
        private VpnState _state = VpnState.DISCONNECTED;
        private bool _needs_login = false;

        public Connection(Provider provider) { _provider = provider; }

        public string id { get { return "tailscale"; } }
        public string display_name { get { return _name; } }
        public VpnState state { get { return _state; } }
        public string icon_name { get { return "network-vpn-symbolic"; } }
        public bool can_remove { get { return false; } }

        /** Returns true if the public-facing label changed. */
        public bool update(VpnState s, bool needs_login, string? name) {
            string n = (name != null && name != "") ? name : "Tailscale";
            bool changed = (s != _state) || (n != _name);
            _state = s;
            _needs_login = needs_login;
            _name = n;
            return changed;
        }

        public async bool activate() throws Error {
            if (_needs_login) {
                _provider.report(false,
                    "Tailscale needs login. Open a terminal and run: tailscale login");
                return false;
            }
            bool ok = yield _provider.run({ "tailscale", "up" });
            if (!ok) _provider.report(false, "Could not bring Tailscale up.");
            _provider.refresh();
            return ok;
        }

        public async bool deactivate() throws Error {
            bool ok = yield _provider.run({ "tailscale", "down" });
            if (!ok) _provider.report(false, "Could not bring Tailscale down.");
            _provider.refresh();
            return ok;
        }

        public async bool remove() throws Error {
            // Tailscale is not removed from here - use `tailscale logout`.
            return false;
        }
    }

    public class Provider : Object, Singularity.VpnProvider {
        private string? _bin = null;
        private Connection _conn;
        private uint _poll_id = 0;
        private bool _available = false;

        public Provider() {
            _bin = Environment.find_program_in_path("tailscale");
            _conn = new Connection(this);
            if (_bin != null) {
                _available = true;
                refresh();
                // Poll so the row reflects connections / disconnections made
                // outside the shell (CLI, other machines, key expiry).
                _poll_id = GLib.Timeout.add_seconds(5, () => {
                    refresh();
                    return GLib.Source.CONTINUE;
                });
            }
        }

        ~Provider() {
            if (_poll_id != 0) GLib.Source.remove(_poll_id);
        }

        public string id { get { return "tailscale"; } }
        public string display_name { get { return "Tailscale"; } }

        public GLib.List<Singularity.VpnConnection> get_connections() {
            var l = new GLib.List<Singularity.VpnConnection>();
            if (_available) l.append(_conn);
            return l;
        }

        public void report(bool success, string message) {
            action_result(success, message);
        }

        /** Run a command to completion; returns true on exit code 0. */
        public async bool run(string[] argv) {
            try {
                var sp = new GLib.Subprocess.newv(argv,
                    SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE);
                yield sp.wait_async(null);
                return sp.get_successful();
            } catch (Error e) {
                warning("tailscale: '%s' failed: %s", argv[0], e.message);
                return false;
            }
        }

        /** Re-query daemon state and emit `changed` if the row should update. */
        public void refresh() {
            if (_bin == null) return;
            query_status.begin();
        }

        private async void query_status() {
            string stdout_buf = "";
            try {
                var sp = new GLib.Subprocess.newv(
                    { "tailscale", "status", "--json" },
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                yield sp.communicate_utf8_async(null, null, out stdout_buf, null);
            } catch (Error e) {
                return;
            }

            VpnState st = VpnState.DISCONNECTED;
            bool needs_login = false;
            string? name = null;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(stdout_buf);
                var root = parser.get_root().get_object();
                string backend = root.has_member("BackendState")
                    ? root.get_string_member("BackendState") : "";
                if (backend == "Running") st = VpnState.CONNECTED;
                else if (backend == "Starting") st = VpnState.CONNECTING;
                needs_login = (backend == "NeedsLogin" || backend == "NoState");

                if (root.has_member("Self")) {
                    var self = root.get_object_member("Self");
                    if (self != null && self.has_member("HostName")) {
                        string host = self.get_string_member("HostName");
                        if (host != "") name = "Tailscale (" + host + ")";
                    }
                }
            } catch (Error e) {
                // Malformed / empty status: treat as disconnected.
            }

            if (_conn.update(st, needs_login, name)) changed();
        }
    }
}

public class TailscalePlugin : Object, Singularity.Plugin {
    private PluginContext context;
    private Tailscale.Provider? provider;

    public void activate(PluginContext ctx) {
        this.context = ctx;
        provider = new Tailscale.Provider();
        context.add_vpn_provider(provider);
    }

    public void deactivate() {
        if (provider != null) {
            context.remove_vpn_provider(provider);
            provider = null;
        }
    }

    public Gtk.Widget? get_settings_widget() {
        var box = new Box(Orientation.VERTICAL, 8);
        var lbl = new Label("Adds your Tailscale connection to the Network settings, with connect and disconnect controls. Requires the tailscale CLI and a running tailscaled daemon.");
        lbl.wrap = true;
        lbl.xalign = 0;
        box.append(lbl);
        return box;
    }
}
