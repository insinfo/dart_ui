import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/platform/standard_paths_platform_io.dart'
    as standard_paths_io;
import 'package:test/test.dart';

void main() {
  group('xdg user-dirs parsing', () {
    test('expands \$HOME, keeps absolute paths and skips the rest', () {
      const String content = '''
# This file is written by xdg-user-dirs-update
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="/mnt/storage/downloads/"
XDG_DOCUMENTS_DIR="\$HOME/Documentos"
XDG_MUSIC_DIR="\$HOME"
XDG_PICTURES_DIR="relative/is/not/allowed"
not an assignment at all
XDG_VIDEOS_DIR='single quotes are not the format'
''';
      final Map<String, String> dirs =
          parseXdgUserDirs(content, home: '/home/isaque');

      expect(dirs['XDG_DESKTOP_DIR'], '/home/isaque/Desktop');
      expect(dirs['XDG_DOWNLOAD_DIR'], '/mnt/storage/downloads',
          reason: 'trailing slash is stripped');
      expect(dirs['XDG_DOCUMENTS_DIR'], '/home/isaque/Documentos');
      expect(dirs.containsKey('XDG_MUSIC_DIR'), isFalse,
          reason: r'a value of $HOME means the user disabled the folder');
      expect(dirs.containsKey('XDG_PICTURES_DIR'), isFalse);
      expect(dirs.containsKey('XDG_VIDEOS_DIR'), isFalse);
    });

    test('maps media folders to their XDG keys and nothing else', () {
      expect(xdgUserDirKey(StandardFolder.downloads), 'XDG_DOWNLOAD_DIR');
      expect(xdgUserDirKey(StandardFolder.videos), 'XDG_VIDEOS_DIR');
      expect(xdgUserDirKey(StandardFolder.desktop), 'XDG_DESKTOP_DIR');
      expect(xdgUserDirKey(StandardFolder.appData), isNull);
      expect(xdgUserDirKey(StandardFolder.home), isNull);
    });
  });

  group('linux resolution (pure, injected environment)', () {
    const Map<String, String> environment = <String, String>{
      'HOME': '/home/isaque',
    };

    String? noUserDirs(String configHome) => null;

    test('bases fall back to the spec defaults under \$HOME', () {
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.appData,
          environment: environment,
          readUserDirs: noUserDirs,
        ),
        '/home/isaque/.config',
      );
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.appDataLocal,
          environment: environment,
          readUserDirs: noUserDirs,
        ),
        '/home/isaque/.local/share',
      );
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.cache,
          environment: environment,
          readUserDirs: noUserDirs,
        ),
        '/home/isaque/.cache',
      );
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.downloads,
          environment: environment,
          readUserDirs: noUserDirs,
        ),
        '/home/isaque/Downloads',
      );
    });

    test('XDG base variables win over the defaults', () {
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.appData,
          environment: const <String, String>{
            'HOME': '/home/isaque',
            'XDG_CONFIG_HOME': '/etc/per-user/isaque/',
          },
          readUserDirs: noUserDirs,
        ),
        '/etc/per-user/isaque',
      );
    });

    test('user-dirs.dirs wins for media folders, env variable wins over it',
        () {
      String? userDirs(String configHome) =>
          'XDG_DOWNLOAD_DIR="\$HOME/Baixados"\n';
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.downloads,
          environment: environment,
          readUserDirs: userDirs,
        ),
        '/home/isaque/Baixados',
      );
      expect(
        standard_paths_io.linuxStandardPath(
          StandardFolder.downloads,
          environment: const <String, String>{
            'HOME': '/home/isaque',
            'XDG_DOWNLOAD_DIR': '/srv/downloads',
          },
          readUserDirs: userDirs,
        ),
        '/srv/downloads',
      );
    });

    test('no \$HOME is a named failure', () {
      expect(
        () => standard_paths_io.linuxStandardPath(
          StandardFolder.documents,
          environment: const <String, String>{},
          readUserDirs: noUserDirs,
        ),
        throwsA(isA<StandardPathsException>()),
      );
    });
  });

  group('macOS resolution (pure)', () {
    test('follows the documented ~/Library layout', () {
      const String home = '/Users/isaque';
      expect(
        standard_paths_io.macStandardPath(StandardFolder.videos, home: home),
        '/Users/isaque/Movies',
        reason: 'macOS names the folder Movies',
      );
      expect(
        standard_paths_io.macStandardPath(StandardFolder.appData, home: home),
        '/Users/isaque/Library/Application Support',
      );
      expect(
        standard_paths_io.macStandardPath(StandardFolder.cache, home: home),
        '/Users/isaque/Library/Caches',
      );
      expect(
        standard_paths_io.macStandardPath(StandardFolder.home, home: home),
        home,
      );
    });
  });

  group('windows resolution (real machine)', () {
    test('the known folders resolve to directories that exist', () {
      if (!Platform.isWindows) return;
      const List<StandardFolder> mustExist = <StandardFolder>[
        StandardFolder.home,
        StandardFolder.documents,
        StandardFolder.downloads,
        StandardFolder.desktop,
        StandardFolder.appData,
        StandardFolder.appDataLocal,
        StandardFolder.cache,
        StandardFolder.temp,
      ];
      for (final StandardFolder folder in mustExist) {
        final String path = StandardPaths.resolve(folder);
        expect(path, isNotEmpty, reason: '$folder');
        expect(Directory(path).existsSync(), isTrue,
            reason: '$folder resolved to $path, which does not exist');
      }
    });

    test('the executable path names the running dart binary', () {
      if (!Platform.isWindows) return;
      final String executable = StandardPaths.executable;
      expect(File(executable).existsSync(), isTrue);
      expect(executable, Platform.resolvedExecutable);
    });

    test('appData and appDataLocal are the Roaming/Local pair', () {
      if (!Platform.isWindows) return;
      expect(StandardPaths.appData.toLowerCase(), contains('roaming'));
      expect(StandardPaths.appDataLocal.toLowerCase(), contains('local'));
    });
  });
}
