/// A home folder made up for screenshots, tests and a no-disk demo.
library;

import 'file_system.dart';
import 'location.dart';

/// The known folders of [demoDisk].
const Map<Place, String> kDemoPlaces = <Place, String>{
  Place.home: '/Users/ana',
  Place.desktop: '/Users/ana/Desktop',
  Place.downloads: '/Users/ana/Downloads',
  Place.documents: '/Users/ana/Documents',
  Place.pictures: '/Users/ana/Pictures',
  Place.music: '/Users/ana/Music',
  Place.videos: '/Users/ana/Videos',
};

/// A disk with a user's folders and a few dozen files of every kind.
MemoryFileSystem demoDisk() {
  final MemoryFileSystem fs =
      MemoryFileSystem(clock: () => DateTime(2026, 10, 13, 9, 30));
  for (final String path in kDemoPlaces.values) {
    fs.addFolder(path);
  }
  const String docs = '/Users/ana/Documents';
  for (final String folder in <String>[
    'Adobe',
    'Design',
    'Fonts',
    'Project Files',
    'Templates',
    'Visual Studio',
  ]) {
    fs.addFolder('$docs/$folder', modified: DateTime(2026, 9, 2, 14, 12));
  }
  final List<(String, int, DateTime)> files = <(String, int, DateTime)>[
    ('IMG_2022_06_01.jpg', 3481231, DateTime(2022, 6, 1, 18, 4)),
    ('IMG_2022_06_02.jpg', 2981122, DateTime(2022, 6, 2, 9, 41)),
    ('New Text Document.txt', 0, DateTime(2026, 10, 12, 21, 3)),
    ('Untitled Document.pptx', 845201, DateTime(2026, 8, 30, 11, 20)),
    ('History of Skateboarding.docx', 120334, DateTime(2026, 7, 14, 16, 55)),
    ('license.txt', 1071, DateTime(2025, 1, 3, 10, 0)),
    ('Focus Sessions.xlsx', 51234, DateTime(2026, 10, 1, 8, 15)),
    ('Untitled Spreadsheet.xlsx', 9123, DateTime(2026, 10, 2, 8, 15)),
    ('After Dark.mp3', 7340032, DateTime(2024, 3, 9, 23, 1)),
    ('poppins-regular.ttf', 158240, DateTime(2023, 5, 5, 5, 5)),
    ('Annual Report 2025.pdf', 2411724, DateTime(2026, 2, 11, 15, 30)),
    ('trip.mp4', 52428800, DateTime(2026, 4, 20, 19, 45)),
    ('backup.zip', 10485760, DateTime(2026, 6, 6, 6, 6)),
    ('main.dart', 4096, DateTime(2026, 10, 13, 2, 21)),
  ];
  for (final (String name, int size, DateTime modified) in files) {
    fs.addFile('$docs/$name', size: size, modified: modified);
  }
  fs.addFile('$docs/Project Files/plan.md', size: 2048);
  fs.addFile('$docs/Project Files/report2.txt', size: 100);
  fs.addFile('$docs/Project Files/report10.txt', size: 200);
  fs.addFile('/Users/ana/Downloads/setup.exe', size: 31457280);
  fs.addFile('/Users/ana/Pictures/wallpaper.png', size: 4194304);
  fs.mounted = const <Volume>[
    Volume(
        path: '/',
        label: 'Windows (C:)',
        totalBytes: 511 << 30,
        freeBytes: 182 << 30),
    Volume(
        path: '/Volumes/Projects',
        label: 'Projects (P:)',
        totalBytes: 931 << 30,
        freeBytes: 77 << 30),
  ];
  return fs;
}
