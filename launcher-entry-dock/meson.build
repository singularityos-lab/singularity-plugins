shared_module('launcher-entry-dock',
  'launcher-entry-dock.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('gee-0.8'), dependency('gio-2.0')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/launcher-entry-dock'
)

configure_file(
  input: 'launcher-entry-dock.plugin',
  output: 'launcher-entry-dock.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/launcher-entry-dock'
)
