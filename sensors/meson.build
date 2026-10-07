shared_module('sensors',
  'sensors.vala',
  'contrast.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, system_dep, dependency('libpeas-2'), meson.get_compiler('c').find_library('m')],
  c_args: ['-DGETTEXT_PACKAGE="singularity-desktop"'],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/sensors'
)

configure_file(
  input: 'sensors.plugin',
  output: 'sensors.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/sensors'
)

contrast_test = executable('sensors-contrast-test',
  'contrast.vala', 'tests/contrast-test.vala',
  dependencies: [dependency('glib-2.0'), dependency('gobject-2.0'), meson.get_compiler('c').find_library('m')],
  install: false
)
test('sensors-contrast', contrast_test)
