/// The shared vocabulary of [Shell]: how a launch is described, how a
/// failure is reported, and the command planning that is pure string work.
///
/// The planners live here, outside the `io` implementation, because deciding
/// *what to run* is arithmetic over strings and deciding it is the part worth
/// testing on every machine. Executing the plan - `Process.run`, or
/// `ShellExecuteW` through FFI - is the thin part, and it is the only part
/// that differs per target.
library;

/// One external command a shell operation may run.
final class ShellCommand {
  const ShellCommand({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;

  @override
  String toString() => 'ShellCommand($executable ${arguments.join(' ')})';
}

/// A shell operation that could not be completed.
final class ShellException implements Exception {
  const ShellException({
    required this.operation,
    required this.reason,
    this.platform,
    this.errorCode,
  });

  final String operation;
  final String reason;
  final String? platform;
  final int? errorCode;

  @override
  String toString() => 'ShellException: $operation failed'
      '${platform == null ? '' : ' on $platform'}'
      '${errorCode == null ? '' : ' (code $errorCode)'} - $reason';
}

/// Validates [url] for [Shell.openUrl] and returns it parsed.
///
/// The requirement is an *absolute* URI: something with a scheme. That is
/// what separates "open this in the browser" from "run this program" - on
/// Windows the same native call does both, and a caller who passes
/// `cmd.exe` must get a [ShellException], not a command prompt.
Uri parseLaunchableUrl(String url) {
  final Uri? parsed = Uri.tryParse(url.trim());
  if (parsed == null || !parsed.hasScheme) {
    throw ShellException(
      operation: 'openUrl',
      reason: 'not an absolute URL: "$url" (a scheme such as https: is '
          'required, so that a bare program name cannot be launched as one)',
    );
  }
  return parsed;
}

/// The launchers a Linux desktop may have, in preference order, for opening
/// [target] (a URL or a path) with the default application.
///
/// `xdg-open` is the freedesktop entry point and is installed nearly
/// everywhere; `gio open` ships with GLib and is what `xdg-open` itself
/// defers to on GNOME; `kde-open5` covers a KDE without xdg-utils.
List<ShellCommand> linuxOpenCommands(String target) => <ShellCommand>[
      ShellCommand(executable: 'xdg-open', arguments: <String>[target]),
      ShellCommand(executable: 'gio', arguments: <String>['open', target]),
      ShellCommand(executable: 'kde-open5', arguments: <String>[target]),
    ];

/// The commands that select [absolutePath] in a Linux file manager, best
/// effort first.
///
/// The portable interface is the D-Bus `org.freedesktop.FileManager1`
/// service, which every major file manager implements; the last resort is
/// opening the containing directory without selection, which is degraded and
/// says so by being last.
List<ShellCommand> linuxRevealCommands(String absolutePath) {
  final String fileUri = Uri.file(absolutePath).toString();
  final int slash = absolutePath.lastIndexOf('/');
  final String parent = slash <= 0 ? '/' : absolutePath.substring(0, slash);
  return <ShellCommand>[
    ShellCommand(
      executable: 'dbus-send',
      arguments: <String>[
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:$fileUri',
        'string:',
      ],
    ),
    ...linuxOpenCommands(parent),
  ];
}

/// `open`, macOS's own launcher, for a URL or path.
ShellCommand macOpenCommand(String target) =>
    ShellCommand(executable: '/usr/bin/open', arguments: <String>[target]);

/// `open -R`, which reveals (selects) the file in the Finder.
ShellCommand macRevealCommand(String absolutePath) => ShellCommand(
      executable: '/usr/bin/open',
      arguments: <String>['-R', absolutePath],
    );

/// The parameter string for `explorer.exe` that opens the containing folder
/// with [absolutePath] selected.
///
/// The quoting matters: `/select,` takes the rest of the parameter string as
/// the path, and Explorer only honours paths with spaces when they are
/// quoted. There is deliberately no space after the comma - with one,
/// some Windows builds fall back to opening Documents.
String windowsRevealParameters(String absolutePath) =>
    '/select,"$absolutePath"';
