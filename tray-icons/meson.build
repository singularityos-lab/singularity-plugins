shared_module('tray-icons',
  ['tray-icons.vala', 'watcher.vala', 'tray_item.vala', 'sni_dbus.vala', 'dbusmenu_client.vala'],
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('gio-2.0'), dependency('gio-unix-2.0'), dependency('gee-0.8')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/tray-icons'
)

configure_file(
  input: 'tray-icons.plugin',
  output: 'tray-icons.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/tray-icons'
)
