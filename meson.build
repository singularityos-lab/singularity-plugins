project('singularity-plugins', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

add_project_arguments('--pkg=posix', language: 'vala')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('status-monitor')
subdir('notification-test')
subdir('tray-icons')
subdir('workspaces-indicator')
subdir('clipboard-history')
subdir('caffeine')
subdir('color-picker')
subdir('media-controls')
subdir('quick-notes')
subdir('pomodoro')
subdir('disk-usage')
subdir('weather')
subdir('mpris-dock')
subdir('downloads-dock')
subdir('telegram-dock')
subdir('launcher-entry-dock')
subdir('emoji-search')
subdir('tailscale')
subdir('example-dock')
