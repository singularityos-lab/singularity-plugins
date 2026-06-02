shared_module('caffeine',
  'caffeine.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/caffeine'
)

configure_file(
  input: 'caffeine.plugin',
  output: 'caffeine.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/caffeine'
)
