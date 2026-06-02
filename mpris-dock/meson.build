shared_module('mpris-dock',
  'mpris-dock.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('libsoup-3.0'), dependency('gee-0.8')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/mpris-dock'
)

configure_file(
  input: 'mpris-dock.plugin',
  output: 'mpris-dock.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/mpris-dock'
)
