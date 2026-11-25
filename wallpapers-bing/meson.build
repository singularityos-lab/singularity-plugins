shared_module('wallpapers-bing',
  'wallpapers_bing.vala',
  dependencies: [
    dependency('gtk4'),
    libsingularity_dep,
    dependency('libpeas-2'),
    dependency('json-glib-1.0'),
    dependency('gee-0.8'),
  ],
  c_args: ['-DGETTEXT_PACKAGE="singularity-desktop"'],
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/wallpapers-bing'
)

configure_file(
  input: 'wallpapers-bing.plugin',
  output: 'wallpapers-bing.plugin',
  copy: true,
  install: true,
  install_dir: get_option('libdir') / 'singularity/plugins/wallpapers-bing'
)

install_data('binghelper/binghelper',
  rename: 'singularity-binghelper',
  install_dir: get_option('bindir'),
  install_mode: 'rwxr-xr-x'
)

python = find_program('python3')
test('binghelper', python,
  args: [files('tests/test_binghelper.py')],
  env: {'BINGHELPER': meson.current_source_dir() / 'binghelper' / 'binghelper'}
)
