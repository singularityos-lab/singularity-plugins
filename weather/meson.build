shared_module('weather',
  'weather.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/weather'
)

configure_file(
  input: 'weather.plugin',
  output: 'weather.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/weather'
)
