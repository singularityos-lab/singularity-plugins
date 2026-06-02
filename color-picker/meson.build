shared_module('color-picker',
  'color-picker.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/color-picker'
)

configure_file(
  input: 'color-picker.plugin',
  output: 'color-picker.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/color-picker'
)
