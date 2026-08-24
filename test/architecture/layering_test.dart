/// The layering rule, checked as a test rather than trusted as a convention.
///
/// Section 8.2 of the roadmap fixes the dependency direction, and the Fase 6
/// gate ends with "nenhum Win32 type no core". That is the kind of rule that is
/// obeyed for months and then broken by one convenient import - at which point
/// the framework silently stops being portable and nobody notices until the
/// Linux build fails.
///
/// So it is asserted here, over the actual source files.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The layers that make up the portable core, in dependency order.
///
/// A layer may import itself and anything *earlier* in this list, and nothing
/// else. `backends` is deliberately absent: no core layer may name one.
const Map<String, List<String>> _allowedDependencies = <String, List<String>>{
  // Package tooling is reachable only from bin/dart_ui.dart and deliberately
  // imports no runtime framework layer. Keeping it declared here means a
  // future convenient import cannot silently couple build tooling to widgets
  // or a native backend.
  'tooling': <String>[],
  'foundation': <String>[],
  'geometry': <String>[],
  // Raw native-ABI plumbing: COM vtables, GUIDs, HRESULTs, a native
  // allocator. It sits this low because it names no operating system and no
  // window - it manipulates pointers and integers, and the identifier ban
  // below applies to it like any other core layer. It knows `foundation`
  // because ordered teardown is `DisposableBag`'s job and a second
  // implementation of that order is how the order stops being one rule.
  'ffi': <String>['foundation'],
  // Portable audio contracts depend only on lifecycle ownership. Native
  // adapters use the OS-neutral ABI helpers; they never reach into a window or
  // renderer backend.
  'audio': <String>['ffi', 'foundation'],
  'scheduler': <String>['foundation'],
  // Native image codecs live behind conditional imports in graphics. They
  // may use the OS-neutral ABI helpers, while platform/window types remain
  // forbidden here and the stub keeps those imports out of unsupported
  // targets.
  'graphics': <String>['ffi', 'foundation', 'geometry'],
  // Cryptographic primitives are portable core code. The optional native
  // accelerator reaches only the OS-neutral ABI helpers and falls back to
  // the pure-Dart implementation on unsupported targets.
  'crypto': <String>['ffi'],
  // PDF is a document/graphics format layer: it consumes geometry and display
  // lists and delegates hashes/ciphers to the crypto layer, while remaining
  // independent from layout, widgets and platform backends.
  'pdf': <String>['crypto', 'geometry', 'graphics'],
  // CorelDRAW parsing shares the PDF byte reader/exporter and the portable
  // vector/image primitives. It likewise stays below layout and widgets.
  'cdr': <String>['geometry', 'graphics', 'pdf'],
  // Animation sits above the scheduler because time enters it through a frame
  // callback rather than through a clock it reads itself; see
  // `animation/clock.dart`. It knows geometry because a tween interpolates an
  // Offset, and nothing else.
  'animation': <String>['foundation', 'geometry', 'scheduler'],
  'text': <String>['foundation', 'geometry', 'graphics'],
  'platform': <String>['ffi', 'foundation', 'geometry', 'scheduler'],
  // Gesture recognizers sit above raw pointer events and the injected
  // scheduler used by deadlines, but below render objects and widgets. The
  // GestureDetector that owns a render object lives in `widgets`.
  'gestures': <String>['geometry', 'platform', 'scheduler'],
  // rendering may know what a glyph is, because rasterizing one is its job.
  // The reverse is forbidden: section 22.7 requires the font parser to stay
  // independent of any renderer, so `text` must never appear to depend on
  // `rendering`.
  // `ffi` is here for the same reason `dart:ffi` itself is: a GPU backend that
  // talks to a driver is native-ABI code, and the Direct3D 11 backend calls
  // COM vtables. It is an ABI dependency, not a platform one - nothing in
  // `ffi` names a window, a display server or an operating system.
  'rendering': <String>[
    'ffi',
    'foundation',
    'geometry',
    'graphics',
    'platform',
    'text',
  ],
  // `text` is here for exactly one type: [TextDirection]. Reading direction is
  // a property of text, and it is the input that turns a logical `start` edge
  // into a physical `left` one - so a layout that resolves `EdgeInsetsDirectional`
  // or lays a right-to-left row out has to name it. The alternative was a
  // second copy of the enum in `layout`, which is how a framework ends up with
  // two incompatible spellings of right-to-left and a conversion function
  // between them. No cycle is introduced and no new code becomes reachable:
  // `layout` already depends on `rendering`, and `rendering` already depends
  // on `text`.
  'layout': <String>[
    'foundation',
    'geometry',
    'graphics',
    'rendering',
    'text',
  ],
  'widgets': <String>[
    'animation',
    'cdr',
    'foundation',
    'geometry',
    'graphics',
    'gestures',
    'layout',
    'platform',
    'pdf',
    'rendering',
    'scheduler',
    'text',
  ],
  // The overlay draws its own numbers, and the join between a face and a
  // display list is `rendering/text` - the same one every widget uses. The
  // alternative was a second, private bitmap font living in diagnostics.
  'diagnostics': <String>[
    'foundation',
    'geometry',
    'graphics',
    'rendering',
    'text',
  ],
  'gallery': <String>[
    'foundation',
    'geometry',
    'graphics',
    'layout',
    'platform',
    'rendering',
    'scheduler',
    'text',
    'widgets',
  ],
  // The application shell sits above everything, which is precisely why it is
  // listed last and why `backends` is still absent from its row: `runApp` has
  // to assemble a backend without being allowed to name one, and the entries
  // it is handed are the seam that makes that possible.
  'app': <String>[
    'diagnostics',
    'foundation',
    'gallery',
    'geometry',
    'graphics',
    'layout',
    'platform',
    'rendering',
    'scheduler',
    'text',
    'widgets',
  ],
};

/// Edges that break the declared order, each with the reason it is tolerated.
///
/// These predate Fase 6 and are recorded rather than silently allowed: the
/// test still fails on any *new* violation, and the companion test below fails
/// if one of these edges disappears, so the list cannot rot. Each is a
/// candidate for a small restructuring, not an accepted design.
const Map<String, String> _knownExceptions = <String, String>{
  'rendering/render_object.dart -> layout':
      'a compatibility typedef; RenderObject is an alias for layout RenderBox '
          'and the file exists only so older imports keep resolving',
  'scheduler/frame_scheduler.dart -> layout':
      'the frame scheduler drives PipelineOwner, so it sits above layout '
          'rather than beside it; it belongs in an application layer',
  'scheduler/frame_scheduler.dart -> graphics':
      'the same coordinator hands a DisplayList to the pipeline',
  'platform/native_window.dart -> rendering':
      'sections 9.3 and 9.7 pair a window with the surface it presents, so '
          'the window contract necessarily names the renderer surface type',
};

/// Names that must never appear in core source, in any form.
///
/// Matched against identifiers, so a mention inside a comment or a doc string
/// is fine - the rule is about what the code depends on, not about what it may
/// discuss.
const List<String> _forbiddenIdentifiers = <String>[
  'HWND',
  'WndProc',
  'CreateWindowEx',
  'user32',
  'gdi32',
  'kernel32',
  'LPARAM',
  'WPARAM',
  'xcb_',
  'NSWindow',
  'objc_msgSend',
  'IOSurface',
];

void main() {
  final Directory lib = Directory('lib/src');

  group('layer dependencies', () {
    test('no core layer imports a backend', () {
      final List<String> violations = <String>[];
      for (final File file in _coreFiles(lib)) {
        final String source = file.readAsStringSync();
        for (final String import in _imports(source)) {
          if (!import.contains('backends/')) continue;
          violations.add('${_relative(file)} imports $import');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'a core file that names a backend stops the core being '
            'portable:\n${violations.join('\n')}',
      );
    });

    test('each layer imports only the layers it is allowed to', () {
      final List<String> violations = <String>[];
      for (final File file in _coreFiles(lib)) {
        final String layer = _layerOf(file);
        final String relative = _relative(file);
        final List<String>? allowed = _allowedDependencies[layer];
        if (allowed == null) {
          violations.add('$relative is in an undeclared layer');
          continue;
        }
        final String? subdirectory = relative.split('/').length > 2
            ? relative
                .split('/')
                .sublist(1, relative.split('/').length - 1)
                .join('/')
            : null;
        for (final String import in _imports(file.readAsStringSync())) {
          final String? target = _layerOfImport(
            import,
            from: layer,
            within: subdirectory,
          );
          if (target == null || target == layer) continue;
          if (allowed.contains(target)) continue;
          final String edge = '$relative -> $target';
          if (_knownExceptions.containsKey(edge)) continue;
          violations.add(edge);
        }
      }

      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('every recorded exception is still real', () {
      // An exception list that outlives the thing it excuses is worse than no
      // list: it silently permits a future violation on the same edge.
      final Set<String> live = <String>{};
      for (final File file in _coreFiles(lib)) {
        final String layer = _layerOf(file);
        final String relative = _relative(file);
        final String? subdirectory = relative.split('/').length > 2
            ? relative
                .split('/')
                .sublist(1, relative.split('/').length - 1)
                .join('/')
            : null;
        for (final String import in _imports(file.readAsStringSync())) {
          final String? target =
              _layerOfImport(import, from: layer, within: subdirectory);
          if (target == null || target == layer) continue;
          live.add('$relative -> $target');
        }
      }

      final List<String> stale = <String>[
        for (final String edge in _knownExceptions.keys)
          if (!live.contains(edge)) edge,
      ];
      expect(stale, isEmpty,
          reason: 'these exceptions no longer apply and should be deleted:\n'
              '${stale.join('\n')}');
    });

    test('no platform-specific identifier appears in core code', () {
      final List<String> violations = <String>[];
      for (final File file in _coreFiles(lib)) {
        final String code = _withoutCommentsAndStrings(file.readAsStringSync());
        for (final String identifier in _forbiddenIdentifiers) {
          if (!code.contains(identifier)) continue;
          violations.add('${_relative(file)} mentions $identifier');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'the core must not name a platform type:\n'
            '${violations.join('\n')}',
      );
    });
  });

  group('the check itself', () {
    test('it is looking at a real, non-empty set of files', () {
      // A layering test that silently matched nothing would pass forever.
      final List<File> files = _coreFiles(lib).toList();
      expect(files.length, greaterThan(30));
      expect(
        files.map(_layerOf).toSet(),
        containsAll(<String>['widgets', 'layout', 'rendering', 'geometry']),
      );
    });

    test('it actually parses imports out of the sources', () {
      // The vacuous-pass guard. A broken import pattern finds nothing, and
      // "no violations" then means "nothing was checked" - which is how a
      // layering rule quietly stops being enforced.
      final int total = _coreFiles(lib)
          .map((File file) => _imports(file.readAsStringSync()).length)
          .fold(0, (int sum, int count) => sum + count);
      expect(total, greaterThan(100));

      expect(
        _imports("import '../geometry/rect.dart';\nimport 'widget.dart';"),
        <String>['../geometry/rect.dart', 'widget.dart'],
      );
    });

    test('it would notice a cross-layer import', () {
      // layout may not reach into widgets: constraints flow down, not up.
      expect(
        _allowedDependencies['layout'],
        isNot(contains('widgets')),
      );
      expect(
        _layerOfImport('../widgets/theme.dart', from: 'layout'),
        'widgets',
      );
    });

    test('it would notice a forbidden identifier', () {
      const String sample = 'final int handle = CreateWindowEx(0);';
      expect(
        _withoutCommentsAndStrings(sample).contains('CreateWindowEx'),
        isTrue,
      );
      expect(
        _withoutCommentsAndStrings('// CreateWindowEx is a Win32 call')
            .contains('CreateWindowEx'),
        isFalse,
        reason: 'discussing a platform call in a comment is allowed',
      );
    });
  });
}

/// Every core source file: `lib/src` minus the backends.
Iterable<File> _coreFiles(Directory root) sync* {
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final String path = entity.path.replaceAll(r'\', '/');
    if (path.contains('/backends/')) continue;
    yield entity;
  }
}

String _relative(File file) =>
    file.path.replaceAll(r'\', '/').split('lib/src/').last;

String _layerOf(File file) => _relative(file).split('/').first;

final RegExp _importPattern =
    RegExp(r"^\s*import\s+'([^']+)'", multiLine: true);

List<String> _imports(String source) => <String>[
      for (final RegExpMatch match in _importPattern.allMatches(source))
        match.group(1)!,
    ];

/// The layer an import refers to, or null for a package or `dart:` import.
///
/// Resolved relative to the importing file rather than read off the first path
/// segment, because a layer has sub-directories: `rendering/path/...` and
/// `rendering/raster/...` are both the rendering layer, and treating
/// `import 'path/fill_rule.dart'` as a layer called "path" would invent
/// violations that do not exist.
String? _layerOfImport(String import, {required String from, String? within}) {
  if (!import.startsWith('.') && !_looksRelative(import)) return null;
  final List<String> directory = <String>[
    from,
    ...?within?.split('/'),
  ];
  final List<String> parts = <String>[...directory, ...import.split('/')];
  final List<String> resolved = <String>[];
  for (final String part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (resolved.isNotEmpty) resolved.removeLast();
      continue;
    }
    resolved.add(part);
  }
  // The first surviving segment is the layer directory under lib/src.
  return resolved.isEmpty ? from : resolved.first;
}

/// A bare `foo/bar.dart` is relative in Dart; only `package:`/`dart:` are not.
bool _looksRelative(String import) =>
    !import.startsWith('package:') && !import.startsWith('dart:');

/// Strips comments and string literals so a mention in prose is not a match.
String _withoutCommentsAndStrings(String source) {
  final StringBuffer out = StringBuffer();
  bool inLineComment = false;
  bool inBlockComment = false;
  String? quote;
  for (int i = 0; i < source.length; i++) {
    final String c = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';
    if (inLineComment) {
      if (c == '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        i++;
      }
      continue;
    }
    if (quote != null) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == quote) quote = null;
      continue;
    }
    if (c == '/' && next == '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      continue;
    }
    out.write(c);
  }
  return out.toString();
}
