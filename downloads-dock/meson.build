shared_module('downloads-dock',
  'downloads-dock.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('gee-0.8'), dependency('gio-2.0')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/downloads-dock'
)

configure_file(
  input: 'downloads-dock.plugin',
  output: 'downloads-dock.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/downloads-dock'
)
