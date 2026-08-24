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

import 'canvas_area.dart';
import 'commands.dart';
import 'context_panel.dart';
import 'doc_tabs.dart';
import 'editor_model.dart';
import 'menu_bar.dart';
import 'metrics.dart';
import 'plugin_area.dart';
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
    closeDocument: () => model.closeDocument(model.activeIndex),
    zoomIn: () => model.zoomBy(ZoomMetrics.step, _viewport),
    zoomOut: () => model.zoomBy(1 / ZoomMetrics.step, _viewport),
    zoomActual: () => model.setZoom(1.0),
    zoomToPage: () => model.zoomToRect(model.active.page.rect, _viewport),
    zoomToSelection: () =>
        model.zoomToRect(model.selection.selectionBounds, _viewport),
    showPanel: (String id) {
      if (!model.openPanels.contains(id)) model.openPanels.add(id);
      model.activePanel = id;
      model.refresh('${PanelIds.names[id]} shown');
    },
    quit: () => model.refresh('Close the window to exit'),
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
  void _save() {
    final String? existing = model.hasDocument ? model.active.filePath : null;
    if (existing == null) {
      _saveAs('svg');
      return;
    }
    _writeTo(existing, _formatOf(existing));
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
        title: format == 'svg' ? 'Save drawing' : 'Export as ${format.toUpperCase()}',
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
    _writeTo(target, format);
  }

  static String _formatOf(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot < 0) return 'svg';
    return path.substring(dot + 1).toLowerCase();
  }

  void _writeTo(String target, String format) {
    if (!model.hasDocument) return;
    final DocumentSession session = model.active;
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
      // Only a format the editor can read back counts as "this document now
      // lives here"; exporting a PDF does not make the PDF the document.
      if (format == 'svg' || format == 'cdr') {
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
  void _onViewportResized(Size size) {
    _viewport = size;
    if (!model.hasDocument || model.active.fittedOnce) return;
    if (size.width < 40 || size.height < 40) return;
    model.active.fittedOnce = true;
    model.zoomToRect(model.active.page.rect, size);
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = CommandCatalog(model: model, services: _services);
    final menus = catalog.menus;

    // ComboBoxScope has to sit above everything that hosts a combo box, for
    // the same reason the menu overlay does: a drop-down painted inside its
    // field would be under every widget that follows it.
    return ComboBoxScope(
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
                    openIndex: model.openMenu,
                    onOpen: (int index) {
                      model.openMenu = index;
                      model.refresh();
                    },
                  ),
                  StandardToolbar(commands: catalog.standardToolbar),
                  ContextPanel(model: model),
                  DocumentTabs(
                    documents: model.documents,
                    activeIndex: model.activeIndex,
                    onSelected: model.selectDocument,
                    onClosed: model.closeDocument,
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Toolbox(
                          activeTool: model.tool,
                          fill: model.currentFill,
                          stroke: model.currentStroke,
                          onToolSelected: (ToolMode tool) {
                            model.tool = tool;
                            model.refresh('Tool: ${tool.name}');
                          },
                        ),
                        Expanded(
                          child: CanvasArea(
                            model: model,
                            onViewportResized: _onViewportResized,
                          ),
                        ),
                        PluginArea(model: model),
                      ],
                    ),
                  ),
                  ColorPaletteBar(
                    swatchSize: ChromeMetrics.paletteSwatchSize,
                    height: ChromeMetrics.paletteHeight,
                    onColorSelected: model.setFill,
                    onStrokeColorSelected: model.setStroke,
                  ),
                  EditorStatusBar(model: model),
                ],
              ),
            ),
            if (model.openMenu >= 0)
              Positioned.fill(
                child: EditorMenuOverlay(
                  menus: menus,
                  openIndex: model.openMenu,
                  onDismiss: () {
                    model.openMenu = -1;
                    model.refresh();
                  },
                ),
              ),
          ],
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
