shared_module('clipboard-history',
  ['clipboard-history.vala'],
  dependencies: [
    dependency('gtk4'),
    libsingularity_dep,
    dependency('libpeas-2'),
    dependency('pango'),
  ],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/clipboard-history'
)

configure_file(
  input: 'clipboard-history.plugin',
  output: 'clipboard-history.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/clipboard-history'
)
