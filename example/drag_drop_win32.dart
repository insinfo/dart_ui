/// A real window you can drop real files onto.
///
/// The half of drag and drop that no test on this machine can prove: that
/// Windows actually calls the `IDropTarget` vtable
/// `lib/src/backends/win32/win32_drag_drop.dart` builds in Dart, while a human
/// drags a file out of Explorer. `test/backends/win32/win32_drag_drop_test.dart`
/// pins everything up to that point - the vtable, the ABI, the `IDataObject`
/// read, the registration - by calling the slots itself; this is the one that
/// needs a mouse.
///
/// ```
/// dart run example/drag_drop_win32.dart
/// ```
///
/// Drag a file or a selection of text onto the panel. Every drop prints its
/// paths to stdout and shows them in the window. Then drag the label at the
/// bottom *out* into Notepad or Explorer: that is `DoDragDrop` and the
/// `IDropSource`/`IDataObject` pair in `win32_drag_source.dart`, and it is the
/// half no test can drive either - `DoDragDrop` opens a modal loop and takes
/// the mouse.
///
/// Nothing in the widget tree knows it is on Windows: [DropTarget] and
/// [DragSource] are the same widgets the headless tests drive, and the same
/// ones an XDND or Wayland drag will reach.
library;

import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';

import 'gallery_shell.dart';

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    exitCode = reportUnavailable('this example needs Windows',
        what: 'the Win32 drop target');
    return;
  }
  try {
    final application = await runApp(
      const DropDemo(),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'win32',
          create: Win32WindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry.retainedCpu(
          name: 'win32-dib',
          deviceDescription: 'GDI DIB section, BGRA8888 top-down',
          create: (NativeWindow window) {
            final presenter = Win32CpuPresenter(window as Win32Window);
            return (
              present: presenter.renderDisplayList,
              presentNow: presenter.renderDisplayListNow,
              release: presenter.dispose,
            );
          },
        ),
      ],
      options: galleryOptions(
        arguments,
        title: 'dart_ui - drop files here',
      ),
    );
    exitCode = reportGallery(application, tag: 'WIN32_DROP_TARGET');
  } on BackendSelectionError catch (error) {
    exitCode = reportUnavailable(error, what: 'the Win32 drop target');
  }
}

/// A panel that takes files and says what it got.
final class DropDemo extends StatefulWidget {
  const DropDemo({super.key});

  @override
  State<DropDemo> createState() => _DropDemoState();
}

final class _DropDemoState extends State<DropDemo> {
  List<String> _dropped = const <String>[];
  String? _text;
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ColoredBox(
      color: theme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DropTarget(
          // Files first, text second: this panel is about files, and the
          // order here is the *target's* preference - see DropTarget.formats.
          formats: const <String>[DragFormats.uriList, DragFormats.text],
          semanticLabel: 'Drop files here',
          highlightColor: const Color(0x3300A0FF),
          onDragEnter: (DropDetails details) =>
              setState(() => _hovering = true),
          onDragLeave: () => setState(() => _hovering = false),
          onDrop: (DropDetails details) async {
            final List<String> paths = await details.data.readFilePaths();
            final String? text =
                paths.isEmpty ? await details.data.readText() : null;
            stdout.writeln('dropped ${details.action.name}: '
                '${paths.isEmpty ? text : paths.join(', ')}');
            setState(() {
              _hovering = false;
              _dropped = paths;
              _text = text;
            });
            // The honest answer: this panel copies, it never moves, so the
            // source must keep its original.
            return DragAction.copy;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _hovering ? 'Release to drop' : 'Drag files onto this window',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (_dropped.isEmpty && _text == null)
                Text('nothing dropped yet', style: theme.textTheme.bodyMedium)
              else if (_text != null)
                Text(_text!, style: theme.textTheme.bodyMedium)
              else
                for (final String path in _dropped)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(path, style: theme.textTheme.bodyMedium),
                  ),
              const SizedBox(height: 24),
              // The source half. `data` is a builder, so what leaves is what
              // the panel holds at the moment the gesture commits - which for
              // a real list would be the selection the user started pulling.
              DragSource(
                opaque: true,
                data: () => _dropped.isEmpty
                    ? MemoryDragData.text(_text ?? 'dragged out of dart_ui')
                    : MemoryDragData.filePaths(_dropped),
                allowedActions: const <DragAction>{DragAction.copy},
                onDragStarted: () => stdout.writeln('drag started'),
                onDragEnd: (DragAction action) =>
                    stdout.writeln('drag ended: ${action.name}'),
                onDragFailed: (DragDropException error) =>
                    stderr.writeln('drag refused: $error'),
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _dropped.isEmpty
                          ? 'drag this text out'
                          : 'drag those ${_dropped.length} file(s) back out',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
