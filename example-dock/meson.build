shared_module('example-dock',
  'example-dock.vala',
  dependencies: [dependency('gtk4'), dependency('gtk4-layer-shell-0'),
                 dependency('gio-unix-2.0'),
                 libsingularity_dep, dependency('libpeas-2'), dependency('gee-0.8')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/example-dock'
)

configure_file(
  input: 'example-dock.plugin',
  output: 'example-dock.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/example-dock'
)
