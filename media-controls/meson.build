shared_module('media-controls',
  'media-controls.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('pango'), dependency('libsoup-3.0')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/media-controls'
)

configure_file(
  input: 'media-controls.plugin',
  output: 'media-controls.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/media-controls'
)
