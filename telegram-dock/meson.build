shared_module('telegram-dock',
  'telegram-dock.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('gee-0.8'), dependency('gio-unix-2.0')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/telegram-dock'
)

configure_file(
  input: 'telegram-dock.plugin',
  output: 'telegram-dock.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/telegram-dock'
)
