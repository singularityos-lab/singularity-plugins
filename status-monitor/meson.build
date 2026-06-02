shared_module('status-monitor',
  'status-monitor.vala',
  dependencies: [dependency('gtk4'), libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/status-monitor'
)

configure_file(
  input: 'status-monitor.plugin',
  output: 'status-monitor.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/status-monitor'
)
