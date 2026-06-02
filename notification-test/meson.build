shared_module('notification-test',
  'notification-test.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/notification-test'
)

configure_file(
  input: 'notification-test.plugin',
  output: 'notification-test.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/notification-test'
)
