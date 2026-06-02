shared_module('pomodoro',
  'pomodoro.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/pomodoro'
)

configure_file(
  input: 'pomodoro.plugin',
  output: 'pomodoro.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/pomodoro'
)
