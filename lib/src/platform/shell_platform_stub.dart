library;

import 'shell_types.dart';

Future<void> openUrl(String url) async {
  throw const ShellException(
    operation: 'openUrl',
    reason: 'this target has no shell implementation',
  );
}

Future<void> openPath(String path) async {
  throw const ShellException(
    operation: 'openPath',
    reason: 'this target has no shell implementation',
  );
}

Future<void> revealInFileManager(String path) async {
  throw const ShellException(
    operation: 'revealInFileManager',
    reason: 'this target has no shell implementation',
  );
}
