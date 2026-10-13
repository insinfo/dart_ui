/// The editor window: the whole sK1 layout, assembled.
///
/// Top to bottom: menu bar, standard toolbar, contextual property bar, document
/// tabs, then the work area (tool box | rulers + canvas | plugin area), then the
/// colour palette and the status bar.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';

import '../engine/editor_model.dart';
import 'canvas_area.dart';
import 'commands.dart';
import 'context_menus.dart';
import 'context_panel.dart';
import 'doc_tabs.dart';
import 'menu_bar.dart';
import 'metrics.dart';
import 'standard_toolbar.dart';
import 'status_bar.dart';
import 'toolbox.dart';

/// The primary desktop window for the vector editor.
class MainWindow extends StatefulWidget {
  const MainWindow({super.key, this.initialDoc, this.initialName});

  final VectorDocument? initialDoc;
  final String? initialName;

  @override
  State<MainWindow> createState() => MainWindowState();
}

class MainWindowState extends State<MainWindow> {
  late final EditorModel model = EditorModel(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// The canvas box, kept so zoom-to-fit knows what it is fitting into.
  Size _viewport = const Size(800, 600);

  /// Where a save falls back to when the platform has no dialog.
  ///
  /// Only reached when [FilePicker] raises - a headless run, a Linux box with
  /// no zenity, kdialog or yad installed. The status bar says which file it
  /// wrote, because a save that silently invents a path is worse than one that
  /// fails.
  static const String _fallbackDirectory = 'vector_editor_output';

  int _untitledCounter = 1;

  @override
  void initState() {
    super.initState();
    model.documents.add(
      DocumentSession(
        document: widget.initialDoc ?? buildSampleDocument(),
        name: widget.initialName ?? 'Untitled 1',
      ),
    );
    // "Follow the system" needs to know what the system is; asked once at
    // start, and again whenever the user picks that mode.
    unawaited(SystemInfo.isDarkMode().then((bool? dark) {
      if (!mounted) return;
      model.systemDark = dark;
      model.refresh();
    }).catchError((Object _) {}));
  }

  // -------------------------------------------------------------------------
  // Services the command catalog calls into
  // -------------------------------------------------------------------------

  late final EditorServices _services = EditorServices(
    newDocument: () {
      _untitledCounter++;
      model.addDocument(
        DocumentSession(
          document: VectorDocument(docUnits: model.units),
          name: 'Untitled $_untitledCounter',
        ),
      );
    },
    openDocument: _open,
    saveDocument: _save,
    saveDocumentAs: () => _saveAs('svg'),
    exportDocument: _saveAs,
    printDocument: () => _saveAs('pdf'),
    closeDocument: () => _closeDocument(model.activeIndex),
    zoomIn: () => model.zoomBy(ZoomMetrics.step, _viewport),
    zoomOut: () => model.zoomBy(1 / ZoomMetrics.step, _viewport),
    zoomActual: () => model.zoomAbout(1.0, _viewport),
    zoomToPage: () => model.zoomToRect(model.active.page.rect, _viewport),
    zoomToSelection: () =>
        model.zoomToRect(model.selection.selectionBounds, _viewport),
    showPanel: model.showPanelTab,
    quit: () => unawaited(_quit()),
  );

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

  /// Opens a drawing through the operating system's own file dialog.
  ///
  /// This used to scan the working directory and open the first `.svg` it
  /// found, on the conclusion that the framework had no file picker. It has
  /// one - `FilePicker.openFile`, `GetOpenFileNameW` on Windows, `NSOpenPanel`
  /// on macOS, zenity/kdialog/yad on Linux - and this is it.
  void _open() {
    unawaited(_openAsync());
  }

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
    final String name = picked.name;
    try {
      final VectorDocument document;
      if (name.toLowerCase().endsWith('.cdr')) {
        document = CdrDocument.fromBytes(picked.bytes).toVectorDocument();
      } else {
        // utf8, not String.fromCharCodes: an SVG is a text file and its
        // <title> or a text element may hold anything, and reading it a byte
        // per character mangles every accented letter in it.
        document = VectorSvgCodec.importFromSvg(
          utf8.decode(picked.bytes, allowMalformed: true),
        );
      }
      model.addDocument(DocumentSession(
        document: document,
        name: name,
        filePath: picked.path,
      ));
    } on Object catch (error) {
      model.refresh('Could not read $name: $error');
    }
  }

  /// Save: writes over the file this document came from, or asks for one.
  ///
  /// Only an SVG is written over. A drawing opened from a `.cdr` is saved as
  /// SVG under a new name: the CDR writer produces a minimal CDR6 that keeps
  /// neither colours nor text, and writing it over the original would destroy
  /// the user's file.
  void _save() {
    if (!model.hasDocument) return;
    final String? existing = model.active.filePath;
    if (existing == null || _formatOf(existing) != 'svg') {
      if (existing != null) {
        model.refresh('${_basename(existing)} is not SVG - choose where to '
            'save the drawing as SVG');
      }
      _saveAs('svg');
      return;
    }
    _writeTo(model.active, existing, 'svg');
  }

  /// Save As / Export: always asks, then writes.
  void _saveAs(String format) {
    unawaited(_saveAsAsync(format));
  }

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
    _writeTo(session, target, format);
  }

  static String _formatOf(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0) return 'svg';
    return path.substring(dot + 1).toLowerCase();
  }

  void _writeTo(DocumentSession session, String target, String format) {
    try {
      switch (format) {
        case 'svg':
          File(target)
              .writeAsStringSync(VectorSvgCodec.exportToSvg(session.document));
        case 'pdf':
          File(target).writeAsBytesSync(
            VectorPdfExporter.exportToPdf(session.document),
          );
        case 'cdr':
          File(target).writeAsBytesSync(
            CdrTranslator.toCdrBytes(session.document),
          );
        default:
          model.refresh('Unknown export format $format');
          return;
      }
      // Only the format the editor saves in counts as "this document now
      // lives here"; exporting a PDF or a CDR does not make that the document.
      if (format == 'svg') {
        session
          ..filePath = target
          ..name = _basename(target)
          ..modified = false;
      }
      model.refresh('Wrote $target');
    } on Object catch (error) {
      model.refresh('Export failed: $error');
    }
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }

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

  @override
  Widget build(BuildContext context) {
    // A tab opened or switched to since the last frame is fitted once.
    _fitPending();
    final theme = model.theme;
    final catalog = CommandCatalog(model: model, services: _services);
    model.nativeMenuAvailable = PlatformMenuBar.hasNativeMenuBar(context);
    final contextMenus = model.contextMenus = EditorContextMenus(catalog);
    final menus = catalog.menus;

    // ComboBoxScope has to sit above everything that hosts a combo box, for
    // the same reason the menu overlay does: a drop-down painted inside its
    // field would be under every widget that follows it.
    void selectTool(ToolMode tool) {
      model.tool = tool;
      model.refresh('Tool: ${tool.name}');
    }

    // One table for the keyboard: the menus' chords (Cmd on a Mac, Ctrl
    // elsewhere) and the tool box's single keys.
    final Map<KeyGesture, void Function()?> bindings =
        <KeyGesture, void Function()?>{
      for (final ToolEntry? tool in kToolEntries)
        if (tool?.shortcut != null)
          tool!.shortcut!: () => selectTool(tool.mode),
    };
    // Arrow keys nudge the selection; Shift for ten times, the command key
    // for a tenth.
    if (model.hasSelection) {
      for (final (int key, int dx, int dy) in <(int, int, int)>[
        (logicalKeyArrowLeft, -1, 0),
        (logicalKeyArrowRight, 1, 0),
        (logicalKeyArrowUp, 0, -1),
        (logicalKeyArrowDown, 0, 1),
      ]) {
        bindings[KeyGesture(key)] = () => model.nudge(dx, dy);
        bindings[KeyGesture(key, shift: true)] =
            () => model.nudge(dx, dy, big: true);
        bindings[KeyGesture(key, command: true)] =
            () => model.nudge(dx, dy, small: true);
      }
    }
    catalog.keyBindings(menus).forEach((KeyGesture gesture, run) {
      if (bindings[gesture] == null) bindings[gesture] = run;
    });

    // The document area - its tabs and the canvas - is the fixed middle of
    // the docking layout; the panels arrange themselves around it.
    model.workspace.refresh(
      model,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DocumentTabs(
            documents: model.documents,
            activeIndex: model.activeIndex,
            onSelected: model.selectDocument,
            onClosed: (int index) => unawaited(_closeDocument(index)),
            contextMenu: () =>
                PlatformMenuBar.menuWidgets(contextMenus.documentTab()),
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

    return Theme(
      data: theme,
      child: CallbackShortcuts(
        bindings: bindings,
        child: ComboBoxScope(
          child: ColoredBox(
            color: theme.surface,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      EditorMenuBar(
                        menus: menus,
                        controllers: model.menuControllers,
                        native: model.nativeMenuBar,
                      ),
                      StandardToolbar(commands: catalog.standardToolbar),
                      ContextPanel(model: model),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Toolbox(
                              activeTool: model.tool,
                              fill: model.shownFill,
                              stroke: model.shownStroke,
                              onToolSelected: selectTool,
                              // Double-clicking the pick tool selects everything,
                              // which is what CorelDRAW and sK1 both do. Only the
                              // pick tool: a second click on "create rectangle"
                              // means nothing, and making it mean Select All would
                              // be a surprise rather than a shortcut.
                              onToolDoubleTapped: (ToolMode tool) {
                                if (tool != ToolMode.select) return;
                                model.selectAll();
                              },
                            ),
                            Expanded(
                              child: Docking(
                                layout: model.workspace.layout,
                                maximizableItem: false,
                                maximizableTab: false,
                                onItemFloat: (DockingItem item, Offset at) =>
                                    unawaited(model.workspace
                                        .float(
                                          item,
                                          at: at,
                                          window: WindowScope.of(context),
                                          theme: model.theme,
                                          model: model,
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
                        selectedFill: model.shownFill.isNone
                            ? null
                            : model.shownFill.color,
                        selectedStroke: model.shownStroke.isNone ||
                                model.shownStroke.width <= 0
                            ? null
                            : model.shownStroke.color,
                        onColorSelected: model.setFill,
                        onStrokeColorSelected: model.setStroke,
                      ),
                      EditorStatusBar(model: model),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
