shared_module('workspaces-indicator',
  ['workspaces-indicator.vala'],
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/workspaces-indicator'
)

configure_file(
  input: 'workspaces-indicator.plugin',
  output: 'workspaces-indicator.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/workspaces-indicator'
)
