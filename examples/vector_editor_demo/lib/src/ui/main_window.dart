/// The editor window: the whole sK1 layout, assembled.
///
/// Top to bottom: menu bar, standard toolbar, contextual property bar, document
/// tabs, then the work area (tool box | rulers + canvas | plugin area), then the
/// colour palette and the status bar.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_commands.dart';
import '../engine/editor_files.dart';
import '../engine/editor_host.dart';
import '../engine/editor_model.dart';
import 'canvas_area.dart';
import 'context_panel.dart';
import 'doc_tabs.dart';
import 'editor_scope.dart';
import 'editor_ui.dart';
import 'menu_bar.dart';
import 'menus.dart';
import 'metrics.dart';
import 'standard_toolbar.dart';
import 'status_bar.dart';
import 'toolbox.dart';

/// The primary desktop window for the vector editor.
class MainWindow extends StatefulWidget {
  const MainWindow({
    super.key,
    this.initialDoc,
    this.initialName,
    this.onReady,
    this.systemBrightness,
  });

  final VectorDocument? initialDoc;
  final String? initialName;
  final void Function(MainWindowState window)? onReady;

  /// The desktop's light or dark setting, which "Follow the system" wears;
  /// null when the window has no [MediaQuery] to ask - a widget test - and
  /// the editor then keeps its own dark default. Handed down by
  /// [VectorEditorApp], which rebuilds this window only when it changes.
  final Brightness? systemBrightness;

  @override
  State<MainWindow> createState() => MainWindowState();
}

class MainWindowState extends State<MainWindow>
    implements EditorHost, EditorClipboardHost {
  late final EditorModel model = EditorModel(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// The window's own state: theme, panels, menu bar placement.
  late final EditorUi ui = EditorUi(model);

  /// Every command of the editor - the document's and the window's. Menus,
  /// toolbars, shortcuts, right-click menus, tests and automation all run
  /// commands through it.
  final CommandRegistry registry = CommandRegistry();

  late final EditorMenus menus = EditorMenus(registry, ui);

  /// The canvas box, kept so zoom-to-fit knows what it is fitting into.
  Size _viewport = const Size(800, 600);

  @override
  Size get viewport => _viewport;

  /// Where a save falls back to when the platform has no dialog.
  ///
  /// Only reached when [FilePicker] raises - a headless run, a Linux box with
  /// no zenity, kdialog or yad installed. The status bar says which file it
  /// wrote, because a save that silently invents a path is worse than one that
  /// fails.
  static const String _fallbackDirectory = 'vector_editor_output';

  @override
  void initState() {
    super.initState();
    registerEditorCommands(registry, model, this);
    registerUiCommands(registry, ui);
    ui.workspace.registry = registry;
    // A command that refuses says why, where the user is looking.
    registry
      ..onExecuted = (String id, CommandOutcome outcome) {
        if (!outcome.ok) model.refresh(outcome.error);
      }
      // A command that finished later - Paste Special reading the system
      // clipboard - says why it refused the same way.
      ..onCompleted = (String id, CommandOutcome outcome) {
        if (!outcome.ok && mounted) model.refresh(outcome.error);
      };
    model.addDocument(
      DocumentSession(
        document: widget.initialDoc ?? buildSampleDocument(),
        name: widget.initialName ?? model.nextUntitledName(),
      ),
    );
    widget.onReady?.call(this);
    // "Follow the system" wears the desktop's brightness, which the
    // application keeps live; a change arrives through [didUpdateWidget].
    ui.systemDark = _isDark(widget.systemBrightness);
  }

  @override
  void didUpdateWidget(MainWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.systemBrightness != oldWidget.systemBrightness) {
      ui.systemDark = _isDark(widget.systemBrightness);
    }
  }

  static bool? _isDark(Brightness? brightness) => switch (brightness) {
        null => null,
        Brightness.dark => true,
        Brightness.light => false,
      };

  // -------------------------------------------------------------------------
  // EditorHost: what the commands need a person or the window for
  // -------------------------------------------------------------------------

  /// The file types this editor can read, in the order the dialog lists them.
  static const List<FilePickerFilter> _readableFilters = <FilePickerFilter>[
    FilePickerFilter(
      label: 'Vector drawings',
      extensions: <String>['svg', 'cdr'],
    ),
    FilePickerFilter(label: 'SVG drawing', extensions: <String>['svg']),
    FilePickerFilter(label: 'CorelDRAW drawing', extensions: <String>['cdr']),
    FilePickerFilter(label: 'All files', extensions: <String>['*']),
  ];

  static List<FilePickerFilter> _writableFilters(String format) =>
      <FilePickerFilter>[
        switch (format) {
          'svg' => const FilePickerFilter(
              label: 'SVG drawing',
              extensions: <String>['svg'],
            ),
          'pdf' => const FilePickerFilter(
              label: 'PDF document',
              extensions: <String>['pdf'],
            ),
          'cdr' => const FilePickerFilter(
              label: 'CorelDRAW drawing',
              extensions: <String>['cdr'],
            ),
          _ => FilePickerFilter(
              label: format.toUpperCase(),
              extensions: <String>[format],
            ),
        },
        const FilePickerFilter(label: 'All files', extensions: <String>['*']),
      ];

  @override
  void pickAndOpen() => unawaited(_openAsync());

  Future<void> _openAsync() async {
    final PickedFile? picked;
    try {
      picked = await FilePicker.openFile(
        title: 'Open drawing',
        filters: _readableFilters,
      );
    } on FilePickerException catch (error) {
      model.refresh('Could not open the file dialog: ${error.reason}');
      return;
    }
    if (picked == null) {
      model.refresh('Open cancelled');
      return;
    }
    try {
      model.addDocument(DocumentSession(
        document: readDrawing(picked.name, picked.bytes),
        name: picked.name,
        filePath: picked.path,
      ));
    } on Object catch (error) {
      model.refresh('Could not read ${picked.name}: $error');
    }
  }

  @override
  void pickAndSave(String format) => unawaited(_saveAsAsync(format));

  Future<void> _saveAsAsync(String format) async {
    if (!model.hasDocument) return;
    final DocumentSession session = model.active;
    final String suggested = '${session.name.replaceAll('*', '')}.$format';
    String? target;
    try {
      target = await FilePicker.saveFile(
        title: format == 'svg'
            ? 'Save drawing'
            : 'Export as ${format.toUpperCase()}',
        suggestedName: suggested,
        filters: _writableFilters(format),
        defaultExtension: format,
      );
    } on FilePickerException catch (error) {
      // No dialog on this machine: write beside the process rather than lose
      // the user's work, and say where it went.
      final Directory directory = Directory(_fallbackDirectory);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      target = '${directory.path}${Platform.pathSeparator}$suggested';
      model.refresh('No file dialog (${error.reason}); writing to $target');
    }
    if (target == null) {
      model.refresh('Save cancelled');
      return;
    }
    // The tab that asked, even if another one became current while the
    // dialog was open.
    if (!model.documents.contains(session)) return;
    try {
      writeDrawing(session, target, format);
      model.refresh('Wrote $target');
    } on Object catch (error) {
      model.refresh('Export failed: $error');
    }
  }

  @override
  void closeDocument(int index) => unawaited(_closeDocument(index));

  /// Closes tab [index], asking first when it has unsaved changes.
  Future<void> _closeDocument(int index) async {
    if (index < 0 || index >= model.documents.length) return;
    final DocumentSession session = model.documents[index];
    if (session.modified &&
        !await _confirmDiscard(<DocumentSession>[session])) {
      return;
    }
    final int now = model.documents.indexOf(session);
    if (now >= 0) model.closeDocument(now);
  }

  @override
  void quit() => unawaited(_quit());

  @override
  void findReplace() => unawaited(showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _FindReplaceDialog(registry: registry),
      ));

  // --- the system clipboard ---------------------------------------------

  RichClipboard? get _clipboard => switch (ClipboardScope.maybeOf(context)) {
        final RichClipboard rich => rich,
        _ => null,
      };

  @override
  Future<Set<String>> clipboardFormats() async {
    final RichClipboard? clipboard = _clipboard;
    if (clipboard == null) return const <String>{};
    try {
      final Set<ClipboardFormat> formats = await clipboard.availableFormats();
      return <String>{
        if (formats.contains(ClipboardFormat.image)) 'image',
        if (formats.contains(ClipboardFormat.text) ||
            formats.contains(ClipboardFormat.html))
          'text',
      };
    } on ClipboardException {
      return const <String>{};
    }
  }

  @override
  Future<Uint8List?> clipboardImage() async {
    try {
      return await _clipboard?.readImage();
    } on ClipboardException {
      return null;
    }
  }

  @override
  Future<String?> clipboardText() async {
    try {
      return await _clipboard?.readText();
    } on ClipboardException {
      return null;
    }
  }

  @override
  Future<void> copyPicture(List<SelectableObject> objects) async {
    final RichClipboard? clipboard = _clipboard;
    if (clipboard == null || objects.isEmpty) return;
    // Two pixels per point: crisp on a Retina screen, and a picture another
    // program shrinks rather than blows up.
    final DecodedImage? image =
        VectorRenderer.rasterizeObjects(objects, scale: 2);
    final Uint8List? png =
        image == null ? null : VectorPixmap.fromImage(image).toPng();
    if (png == null) return;
    try {
      await clipboard.writeImage(png);
    } on ClipboardException catch (error) {
      if (mounted) model.refresh('Copied here, not to other programs: $error');
    }
  }

  @override
  void choosePasteFormat(List<String> formats) => unawaited(showDialog<void>(
        context: context,
        builder: (BuildContext context) =>
            _PasteSpecialDialog(registry: registry, formats: formats),
      ));

  /// Exit: the same as the window's close button, after the same question.
  Future<void> _quit() async {
    final List<DocumentSession> unsaved =
        model.documents.where((d) => d.modified).toList();
    if (unsaved.isNotEmpty && !await _confirmDiscard(unsaved)) return;
    if (!mounted) return;
    final WindowController? window = WindowScope.of(context);
    if (window == null) {
      model.refresh('Close the window to exit');
      return;
    }
    window.close();
  }

  /// Whether the user agrees to lose the changes in [sessions].
  Future<bool> _confirmDiscard(List<DocumentSession> sessions) async {
    final String names = sessions.map((s) => s.name).join(', ');
    try {
      return await NativeMessageBox.show(
        title: 'Unsaved changes',
        message: sessions.length == 1
            ? '$names has changes that have not been saved. Close it and '
                'discard them?'
            : '$names have changes that have not been saved. Discard them?',
        kind: MessageBoxKind.confirm,
      );
    } on MessageBoxException {
      // No dialog on this machine: keep the work rather than guess.
      model.refresh('Save $names first - no dialog to confirm with');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // The view
  // -------------------------------------------------------------------------

  /// Learns the canvas box, and fits the page into it the first time.
  ///
  /// After that, a resize keeps whatever is at the centre of the view at the
  /// centre: a panel opening or the window growing must not slide the page
  /// off to one side.
  void _onViewportResized(Size size) {
    final Size before = _viewport;
    _viewport = size;
    if (_fitPending()) {
      model.refresh();
      return;
    }
    if (!model.hasDocument || before.width < 40 || before.height < 40) return;
    final Offset shift = Offset(
        (size.width - before.width) / 2, (size.height - before.height) / 2);
    if (shift == Offset.zero) return;
    for (final DocumentSession session in model.documents) {
      if (!session.fittedOnce) continue;
      if (!session.viewTouched && identical(session, model.active)) {
        // Nobody has framed this view by hand yet: keep the page fitted.
        model.fitRect(session.page.rect, size);
      } else {
        session.pan += shift;
      }
    }
    model.refresh();
  }

  /// Fits the current document's page once, as soon as the canvas size is
  /// known - for the first document, and for every tab opened afterwards.
  /// Sets the viewport without rebuilding; returns whether it changed it.
  bool _fitPending() {
    if (!model.hasDocument || model.active.fittedOnce) return false;
    if (_viewport.width < 40 || _viewport.height < 40) return false;
    model.active.fittedOnce = true;
    model.fitRect(model.active.page.rect, _viewport);
    return true;
  }

  /// The window's keyboard: every command's shortcut, plus the arrow keys,
  /// which nudge the selection - Shift for ten times, the command key for a
  /// tenth.
  Map<KeyGesture, void Function()?> _keyBindings() {
    final Map<KeyGesture, void Function()?> bindings = registry.keyBindings();
    if (!model.hasSelection) return bindings;
    for (final (int key, int dx, int dy) in <(int, int, int)>[
      (logicalKeyArrowLeft, -1, 0),
      (logicalKeyArrowRight, 1, 0),
      (logicalKeyArrowUp, 0, -1),
      (logicalKeyArrowDown, 0, 1),
    ]) {
      for (final (KeyGesture gesture, String step) in <(KeyGesture, String)>[
        (KeyGesture(key), 'normal'),
        (KeyGesture(key, shift: true), 'big'),
        (KeyGesture(key, command: true), 'small'),
      ]) {
        bindings[gesture] = () => registry.execute('object.nudge',
            <String, Object?>{'dx': dx, 'dy': dy, 'step': step});
      }
    }
    return bindings;
  }

  // -------------------------------------------------------------------------

  /// How many times the window has built - for a test that holds the line
  /// on what may rebuild it (a pointer move must not).
  int debugBuildCount = 0;

  @override
  Widget build(BuildContext context) {
    debugBuildCount++;
    // A tab opened or switched to since the last frame is fitted once.
    _fitPending();
    final theme = ui.theme;
    ui.nativeMenuAvailable = PlatformMenuBar.hasNativeMenuBar(context);

    // The document area - its tabs and the canvas - is the fixed middle of
    // the docking layout; the panels arrange themselves around it.
    ui.workspace.refresh(
      model,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DocumentTabs(
            documents: model.documents,
            activeIndex: model.activeIndex,
            onSelected: (int index) => registry
                .execute('document.select', <String, Object?>{'index': index}),
            onClosed: (int index) => registry
                .execute('file.close', <String, Object?>{'index': index}),
            contextMenu: () => menus.widgets(menus.documentTab),
          ),
          Expanded(
            child: CanvasArea(
              model: model,
              onViewportResized: _onViewportResized,
            ),
          ),
        ],
      ),
    );

    return EditorScope(
      ui: ui,
      registry: registry,
      menus: menus,
      child: Theme(
        data: theme,
        child: CallbackShortcuts(
          bindings: _keyBindings(),
          // ComboBoxScope has to sit above everything that hosts a combo box:
          // a drop-down painted inside its field would be under every widget
          // that follows it.
          child: ComboBoxScope(
            child: ColoredBox(
              color: theme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  EditorMenuBar(
                    menus: menus.barMenus(),
                    native: ui.nativeMenuBar,
                  ),
                  StandardToolbar(
                    registry: registry,
                    items: EditorMenus.standardToolbar,
                  ),
                  ContextPanel(model: model, registry: registry),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Toolbox(
                          activeTool: model.tool,
                          fill: model.shownFill,
                          stroke: model.shownStroke,
                          onToolSelected: (ToolMode tool) =>
                              registry.execute(toolCommandOf(tool)),
                          // Double-clicking the pick tool selects everything,
                          // which is what CorelDRAW and sK1 both do. Only the
                          // pick tool: a second click on "create rectangle"
                          // means nothing.
                          onToolDoubleTapped: (ToolMode tool) {
                            if (tool != ToolMode.select) return;
                            registry.execute('edit.selectAll');
                          },
                        ),
                        Expanded(
                          child: Docking(
                            layout: ui.workspace.layout,
                            maximizableItem: false,
                            maximizableTab: false,
                            onItemFloat: (DockingItem item, Offset at) =>
                                unawaited(ui.workspace
                                    .float(
                                      item,
                                      at: at,
                                      window: WindowScope.of(context),
                                      ui: ui,
                                      registry: registry,
                                      menus: menus,
                                    )
                                    .then((_) => model.refresh(
                                        '${item.name} in its own window'))),
                            onItemClose: (DockingItem item) =>
                                model.refresh('${item.name} closed - '
                                    'Window menu brings it back'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ColorPaletteBar(
                    swatchSize: ChromeMetrics.of(theme).paletteSwatchSize,
                    height: ChromeMetrics.of(theme).paletteHeight,
                    // Which cell the selection is already wearing, so the
                    // palette answers "what colour is this?" as well as
                    // "make it that colour".
                    selectedFill:
                        model.shownFill.isNone ? null : model.shownFill.color,
                    selectedStroke:
                        model.shownStroke.isNone || model.shownStroke.width <= 0
                            ? null
                            : model.shownStroke.color,
                    onColorSelected: (Color? color) => registry.execute(
                        'object.fill',
                        <String, Object?>{'color': hexOf(color)}),
                    onStrokeColorSelected: (Color? color) => registry.execute(
                        'object.outline',
                        <String, Object?>{'color': hexOf(color)}),
                  ),
                  EditorStatusBar(model: model),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [color] as the `#aarrggbb` a command takes, or null for none.
String? hexOf(Color? color) =>
    color == null ? null : '#${color.value.toRadixString(16).padLeft(8, '0')}';

/// The document a fresh editor opens with.
///
/// Public so the headless shell test can assert against the same artwork the
/// application shows.
VectorDocument buildSampleDocument() {
  final doc = VectorDocument(
    docUnits: DocUnit.mm,
    docOrigin: DocOrigin.upperLeft,
    metaInfo: DocumentMetaInfo(
      author: 'dart_ui',
      notes: 'Created in the pure Dart vector editor',
    ),
  );

  final page = doc.getPage(0);
  final layer = page.children.whereType<VectorLayer>().first;

  void add(DocumentObject object) {
    object.parent = layer;
    layer.children.add(object);
    object.update();
  }

  add(VectorText(
    textContent: 'Vector Editor - 100% Dart',
    trafo: <double>[1, 0, 0, 1, 60, 60],
    style: const VectorStyle(
      fill: FillDescriptor.solid(Color(0xFF1565C0)),
      textStyle: TextStyleDescriptor(fontFamily: 'Sans', fontSize: 18),
    ),
  ));

  add(VectorRectangle(
    startX: 60,
    startY: 100,
    rectWidth: 160,
    rectHeight: 90,
    style: const VectorStyle(
      fill: FillDescriptor.solid(Color(0xFF2196F3)),
      stroke: StrokeDescriptor(color: Color(0xFF0D47A1), width: 2),
    ),
  ));

  add(VectorCircle.fromRect(
    <double>[280, 145, 90, 90],
    style: const VectorStyle(
      fill: FillDescriptor.solid(Color(0xFFFFC107)),
      stroke: StrokeDescriptor(color: Color(0xFFFF8F00), width: 2),
    ),
  ));

  add(VectorPolygon(
    cornersNum: 5,
    coef1: 1,
    coef2: 0.5,
    trafo: <double>[90, 0, 0, 90, 420, 145],
    style: const VectorStyle(
      fill: FillDescriptor.solid(Color(0xFF9C27B0)),
      stroke: StrokeDescriptor(color: Color(0xFF4A148C), width: 2),
    ),
  ));

  doc.update();
  return doc;
}

/// Edit > Find and Replace, for text: what to find, what to put instead,
/// whether case matters - then `edit.replaceText`, one undo step.
class _FindReplaceDialog extends StatefulWidget {
  const _FindReplaceDialog({required this.registry});

  final CommandRegistry registry;

  @override
  State<_FindReplaceDialog> createState() => _FindReplaceDialogState();
}

class _FindReplaceDialogState extends State<_FindReplaceDialog> {
  final TextEditingController _find = TextEditingController('');
  final TextEditingController _replace = TextEditingController('');
  bool _matchCase = false;

  /// Text, or colour: CorelDRAW's Find and Replace does both.
  bool _colours = false;

  /// Where a colour is replaced: fill, outline or both.
  String _target = 'both';

  void _replaceAll() {
    if (_find.value.isEmpty) return;
    final CommandOutcome outcome = _colours
        ? widget.registry.execute('edit.replaceColor', <String, Object?>{
            'from': _find.value.trim(),
            'to': _replace.value.trim(),
            'target': _target,
          })
        : widget.registry.execute('edit.replaceText', <String, Object?>{
            'find': _find.value,
            'replace': _replace.value,
            'matchCase': _matchCase,
          });
    // A colour typed wrong keeps the dialog open; the status bar says why.
    if (outcome.ok) closeDialog<void>(context);
  }

  /// Selects what has the colour in the first field, and closes.
  void _findColour() {
    if (_find.value.trim().isEmpty) return;
    final CommandOutcome outcome =
        widget.registry.execute('edit.findObjects', <String, Object?>{
      if (_target != 'outline') 'fill': _find.value.trim(),
      if (_target == 'outline') 'outline': _find.value.trim(),
    });
    if (outcome.ok) closeDialog<void>(context);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 380,
        child: Dialog(
          title: 'Find and Replace',
          onDismiss: () => closeDialog<void>(context),
          actions: <Widget>[
            if (_colours)
              Button(
                label: 'Find',
                accent: false,
                onPressed: _findColour,
              ),
            Button(
                label: 'Replace All', isDefault: true, onPressed: _replaceAll),
            Button(
              label: 'Cancel',
              accent: false,
              isCancel: true,
              onPressed: () => closeDialog<void>(context),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Radio<bool>(
                    value: false,
                    groupValue: _colours,
                    label: 'Text',
                    onChanged: (bool value) => setState(() => _colours = value),
                  ),
                  const SizedBox(width: 12),
                  Radio<bool>(
                    value: true,
                    groupValue: _colours,
                    label: 'Colour',
                    onChanged: (bool value) => setState(() => _colours = value),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                  controller: _find,
                  label: _colours ? 'Find colour (#rrggbb)' : 'Find',
                  onSubmitted: (_) => _replaceAll()),
              const SizedBox(height: 8),
              TextField(
                  controller: _replace,
                  label: _colours ? 'Replace with (#rrggbb)' : 'Replace with',
                  onSubmitted: (_) => _replaceAll()),
              const SizedBox(height: 8),
              if (_colours)
                Row(
                  children: <Widget>[
                    for (final (String id, String label)
                        in const <(String, String)>[
                      ('fill', 'Fills'),
                      ('outline', 'Outlines'),
                      ('both', 'Both'),
                    ]) ...<Widget>[
                      Radio<String>(
                        value: id,
                        groupValue: _target,
                        label: label,
                        onChanged: (String value) =>
                            setState(() => _target = value),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ],
                )
              else
                CheckBox(
                  value: _matchCase,
                  label: 'Match case',
                  onChanged: (bool value) => setState(() => _matchCase = value),
                ),
            ],
          ),
        ),
      );
}

/// Edit > Paste Special: one choice per format there is to paste.
final class _PasteSpecialDialog extends StatelessWidget {
  const _PasteSpecialDialog({required this.registry, required this.formats});

  final CommandRegistry registry;
  final List<String> formats;

  static const Map<String, String> _labels = <String, String>{
    'objects': 'Objects copied in this editor',
    'image': 'Picture from the clipboard (PNG)',
    'text': 'Text from the clipboard (an SVG drawing comes in as objects)',
  };

  void _paste(BuildContext context, String format) {
    closeDialog<void>(context);
    registry.execute('edit.pasteSpecial', <String, Object?>{'format': format});
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 420,
        child: Dialog(
          title: 'Paste Special',
          onDismiss: () => closeDialog<void>(context),
          actions: <Widget>[
            Button(
              label: 'Cancel',
              accent: false,
              isCancel: true,
              onPressed: () => closeDialog<void>(context),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text('Paste as:'),
              for (final String format in formats) ...<Widget>[
                const SizedBox(height: 8),
                Button(
                  label: _labels[format] ?? format,
                  accent: format == formats.first,
                  isDefault: format == formats.first,
                  onPressed: () => _paste(context, format),
                ),
              ],
            ],
          ),
        ),
      );
}
