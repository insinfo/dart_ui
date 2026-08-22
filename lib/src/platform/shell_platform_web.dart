library;

import 'package:web/web.dart' as web;

import 'shell_types.dart';

Future<void> openUrl(String url) async {
  final Uri parsed = parseLaunchableUrl(url);
  // `noopener` severs the opener reference: the opened page must not be able
  // to script this one back through `window.opener`.
  final web.Window? opened =
      web.window.open(parsed.toString(), '_blank', 'noopener,noreferrer');
  // Popup blockers answer null. That is a real "did not open", and reporting
  // it lets the caller fall back to showing the URL for a user gesture.
  if (opened == null) {
    throw const ShellException(
      operation: 'openUrl',
      platform: 'web',
      reason: 'the browser refused to open a new tab; a popup blocker will '
          'do this for any open not caused directly by a user gesture',
    );
  }
}

Future<void> openPath(String path) async {
  throw const ShellException(
    operation: 'openPath',
    platform: 'web',
    reason: 'a browser exposes no local filesystem to open paths from',
  );
}

Future<void> revealInFileManager(String path) async {
  throw const ShellException(
    operation: 'revealInFileManager',
    platform: 'web',
    reason: 'a browser has no file manager to reveal a path in',
  );
}
