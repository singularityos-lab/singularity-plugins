shared_module('emoji-search',
  'emoji-search.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2'), dependency('gee-0.8')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/emoji-search'
)

configure_file(
  input: 'emoji-search.plugin',
  output: 'emoji-search.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/emoji-search'
)
