shared_module('quick-notes',
  'quick-notes.vala',
  dependencies: [dependency('gtk4'), dependency('gee-0.8'), libsingularity_dep, dependency('libpeas-2')],
  c_args: ['-DGETTEXT_PACKAGE="singularity-desktop"'],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/quick-notes'
)

configure_file(
  input: 'quick-notes.plugin',
  output: 'quick-notes.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/quick-notes'
)
