shared_module('disk-usage',
  'disk-usage.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/disk-usage'
)

configure_file(
  input: 'disk-usage.plugin',
  output: 'disk-usage.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/disk-usage'
)
