project('wifiman', 'vala', 'c',
  version: '0.1.0',
  license: 'GPL3+',
  meson_version: '>= 0.60.0'
)

# Dependencies
gnome = import('gnome')

gtk4_dep = dependency('gtk4')
nm_dep = dependency('libnm')
gio_dep = dependency('gio-2.0')

# Source files
src_files = [
  'src/Application.vala',
  'src/MainWindow.vala',
  'src/viewmodels/WifiViewModel.vala',
  'src/main.vala',
  # Models
  'src/models/WifiNetwork.vala',
  # Services
  'src/services/NetworkManagerService.vala',
  # Widgets
  'src/widgets/WifiNetworkRow.vala',
  # Utils
  'src/utils/WifiUtils.vala',
]

# Resource file
resources = gnome.compile_resources('wifi_resources',
  'data/resources.gresource.xml',
  source_dir: ['.', 'data', 'data/ui']
)

# Application
executable(meson.project_name(),
  src_files,
  resources,
  dependencies: [gtk4_dep, nm_dep, gio_dep],
  install: true
)
