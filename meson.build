project('singularity-plugins', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

add_project_arguments('--pkg=posix', language: 'vala')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)
system_dep = dependency('singularity-system-1.0',
  fallback: ['libsingularity', 'libsingularity_system_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

if system_dep.type_name() == 'internal'
  system_vapi_dir = join_paths(meson.current_source_dir(), '..', 'libsingularity', 'src', 'vapi')
  add_project_arguments(['--vapidir=' + system_vapi_dir], language: 'vala')
endif

subdir('status-monitor')
subdir('sensors')
subdir('notification-test')
subdir('tray-icons')
subdir('workspaces-indicator')
subdir('caffeine')
subdir('media-controls')
subdir('quick-notes')
subdir('disk-usage')
subdir('weather')
subdir('mpris-dock')
subdir('downloads-dock')
subdir('telegram-dock')
subdir('launcher-entry-dock')
subdir('emoji-search')
subdir('tailscale')
subdir('exe-icon')
subdir('example-dock')
subdir('wallpapers-ocs')
subdir('wallpapers-bing')
subdir('wallpapers-stock')
