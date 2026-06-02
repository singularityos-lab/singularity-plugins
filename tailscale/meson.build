shared_module('tailscale',
  'tailscale.vala',
  dependencies: [
    dependency('gtk4'),
    libsingularity_dep,
    dependency('libpeas-2'),
    dependency('json-glib-1.0')
  ],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/tailscale'
)

configure_file(
  input: 'tailscale.plugin',
  output: 'tailscale.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/tailscale'
)
