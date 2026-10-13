/// What CorelDRAW does, feature by feature, and what this editor does of it.
///
/// The features and their priorities are `doc/vector_editor_catalogo_coreldraw.md`
/// (public documentation only). A feature counts as done when every command
/// it names is registered, or when the test named in `evidence` proves the
/// behaviour; `partial` marks one that works short of CorelDRAW's. Graded
/// by behaviour, not by whether a menu row exists - and erring low.
library;

/// One feature of the reference.
final class ParityFeature {
  const ParityFeature(
    this.section,
    this.name,
    this.priority, {
    this.commands = const <String>[],
    this.evidence,
    this.partial,
  });

  final String section;
  final String name;

  /// P0 core, P1 productive, P2 advanced.
  final String priority;

  /// The commands that implement it; all must be registered.
  final List<String> commands;

  /// A test that proves a behaviour no command names (a canvas gesture).
  final String? evidence;

  /// What is missing when it works only in part.
  final String? partial;
}

const String _tools = 'Caixa de ferramentas';
const String _canvas = 'Interações no canvas';
const String _bar = 'Barra de propriedades';
const String _dockers = 'Dockers';
const String _object = 'Operações de objeto';
const String _align = 'Alinhar e distribuir (teclas)';
const String _menus = 'Menus';
const String _nodes = 'Edição de nós';
const String _snap = 'Encaixe, guias, réguas e grade';
const String _page = 'Página e documento';
const String _files = 'Formatos de arquivo';

const List<ParityFeature> kParityCatalog = <ParityFeature>[
  // --- tool box ---------------------------------------------------------------
  ParityFeature(_tools, 'Pick', 'P0', commands: <String>['tool.select']),
  ParityFeature(_tools, 'Freehand pick', 'P2'),
  ParityFeature(_tools, 'Free transform', 'P2'),
  ParityFeature(_tools, 'Shape (F10)', 'P0'),
  ParityFeature(_tools, 'Smooth', 'P2'),
  ParityFeature(_tools, 'Smear', 'P2'),
  ParityFeature(_tools, 'Twirl', 'P2'),
  ParityFeature(_tools, 'Attract / Repel', 'P2'),
  ParityFeature(_tools, 'Smudge / Roughen', 'P2'),
  ParityFeature(_tools, 'Crop', 'P2'),
  ParityFeature(_tools, 'Knife', 'P1'),
  ParityFeature(_tools, 'Virtual segment delete', 'P2'),
  ParityFeature(_tools, 'Eraser (X)', 'P2'),
  ParityFeature(_tools, 'Zoom (Z)', 'P0', commands: <String>['tool.zoom']),
  ParityFeature(_tools, 'Pan (H)', 'P0', commands: <String>['tool.pan']),
  ParityFeature(_tools, 'Freehand (F5)', 'P0'),
  ParityFeature(_tools, '2-point line', 'P1'),
  ParityFeature(_tools, 'Bézier', 'P0', commands: <String>['tool.pen']),
  ParityFeature(_tools, 'Pen', 'P0', commands: <String>['tool.pen']),
  ParityFeature(_tools, 'B-spline', 'P2'),
  ParityFeature(_tools, 'Polyline', 'P1'),
  ParityFeature(_tools, '3-point curve', 'P2'),
  ParityFeature(_tools, 'Smart drawing', 'P2'),
  ParityFeature(_tools, 'LiveSketch', 'P2'),
  ParityFeature(_tools, 'Artistic media', 'P2'),
  ParityFeature(_tools, 'Rectangle (F6)', 'P0',
      commands: <String>['tool.rectangle', 'shape.rectangle']),
  ParityFeature(_tools, '3-point rectangle', 'P2'),
  ParityFeature(_tools, 'Ellipse (F7)', 'P0',
      commands: <String>['tool.ellipse', 'shape.ellipse']),
  ParityFeature(_tools, '3-point ellipse', 'P2'),
  ParityFeature(_tools, 'Polygon (Y)', 'P1',
      commands: <String>['tool.polygon', 'shape.polygon']),
  ParityFeature(_tools, 'Star', 'P1',
      partial: 'a polygon with a sharpness, but no Star tool or command'),
  ParityFeature(_tools, 'Complex star', 'P2'),
  ParityFeature(_tools, 'Graph paper', 'P2'),
  ParityFeature(_tools, 'Spiral', 'P2'),
  ParityFeature(_tools, 'Common shapes (arrow, flowchart...)', 'P2'),
  ParityFeature(_tools, 'Impact', 'P2'),
  ParityFeature(_tools, 'Text (F8)', 'P0',
      commands: <String>['tool.text', 'shape.text'],
      partial: 'artistic text only; no paragraph text'),
  ParityFeature(_tools, 'Table', 'P2'),
  ParityFeature(_tools, 'Parallel dimension', 'P2'),
  ParityFeature(_tools, 'Horizontal/vertical dimension', 'P2'),
  ParityFeature(_tools, 'Angular dimension', 'P2'),
  ParityFeature(_tools, 'Segment dimension', 'P2'),
  ParityFeature(_tools, '3-point callout', 'P2'),
  ParityFeature(_tools, 'Connectors', 'P2'),
  ParityFeature(_tools, 'Edit anchor', 'P2'),
  ParityFeature(_tools, 'Drop shadow', 'P1'),
  ParityFeature(_tools, 'Block shadow', 'P2'),
  ParityFeature(_tools, 'Contour', 'P2'),
  ParityFeature(_tools, 'Blend', 'P2'),
  ParityFeature(_tools, 'Distort', 'P2'),
  ParityFeature(_tools, 'Envelope', 'P2'),
  ParityFeature(_tools, 'Extrude', 'P2'),
  ParityFeature(_tools, 'Transparency', 'P1'),
  ParityFeature(_tools, 'Color eyedropper', 'P1'),
  ParityFeature(_tools, 'Attributes eyedropper', 'P1'),
  ParityFeature(_tools, 'Interactive fill (G)', 'P1'),
  ParityFeature(_tools, 'Mesh fill', 'P2'),
  ParityFeature(_tools, 'Smart fill', 'P2'),
  ParityFeature(_tools, 'Outline pen (F12)', 'P0',
      commands: <String>['panel.fillStroke', 'object.outline'],
      partial: 'colour and width; no dashes, caps or joins'),
  ParityFeature(_tools, 'Fill (F11)', 'P0',
      commands: <String>['panel.fillStroke', 'object.fill'],
      partial: 'uniform colour; no fountain, pattern or texture fills'),

  // --- canvas -----------------------------------------------------------------
  ParityFeature(_canvas, 'Click selects', 'P0',
      evidence: 'clicking a text selects it'),
  ParityFeature(_canvas, 'Drag on empty space: marquee', 'P0',
      evidence: 'a drag in empty space selects everything it encloses'),
  ParityFeature(_canvas, 'Ctrl+click: inside a group', 'P1'),
  ParityFeature(_canvas, 'Alt+click: the object below', 'P1',
      evidence: 'a plain click takes the top object, Alt+click the one '
          'below it'),
  ParityFeature(_canvas, 'Tab / Shift+Tab: next object', 'P2'),
  ParityFeature(_canvas, 'Esc: deselect', 'P0',
      commands: <String>['edit.deselect'], evidence: 'Esc drops the selection'),
  ParityFeature(_canvas, 'Handles: scale, then rotate and skew', 'P0',
      evidence: 'clicking a selected object toggles the frame, and again '
          'toggles back'),
  ParityFeature(_canvas, 'Right-drag: copy here', 'P1'),
  ParityFeature(_canvas, 'Numpad +: duplicate in place', 'P1',
      commands: <String>['edit.duplicate'],
      partial: 'Ctrl+D duplicates; the numpad key is not bound'),
  ParityFeature(_canvas, 'Arrows: nudge', 'P0',
      commands: <String>['object.nudge']),
  ParityFeature(_canvas, 'Ctrl while dragging: constrain', 'P0',
      evidence: 'Ctrl draws a circle, Shift grows it from the press point',
      partial: 'constrains creation; moving is not constrained'),
  ParityFeature(_canvas, 'Shift while resizing', 'P0',
      evidence: 'Shift keeps the aspect ratio while resizing'),
  ParityFeature(_canvas, 'Delete', 'P0', commands: <String>['edit.delete']),

  // --- property bar -----------------------------------------------------------
  ParityFeature(_bar, 'Pick, nothing selected: page and units', 'P0',
      evidence: 'the property bar changes with the selection'),
  ParityFeature(_bar, 'Pick, selection: position, size, rotation', 'P0',
      evidence: 'the property bar changes with the selection'),
  ParityFeature(_bar, 'Shape: nodes', 'P0'),
  ParityFeature(_bar, 'Rectangle: corners', 'P0',
      evidence: 'a single rectangle brings up the rectangle plugin'),
  ParityFeature(_bar, 'Ellipse: arc and pie', 'P1'),
  ParityFeature(_bar, 'Polygon / Star: points', 'P1',
      partial: 'corner count only'),
  ParityFeature(_bar, 'Freehand, Bézier, Pen', 'P0'),
  ParityFeature(_bar, 'Text: content and size', 'P0',
      partial: 'content and size; no font, style or alignment'),
  ParityFeature(_bar, 'Interactive fill', 'P1'),
  ParityFeature(_bar, 'Transparency', 'P1'),
  ParityFeature(_bar, 'Blend', 'P2'),
  ParityFeature(_bar, 'Contour', 'P2'),
  ParityFeature(_bar, 'Drop shadow', 'P1'),
  ParityFeature(_bar, 'Envelope', 'P2'),
  ParityFeature(_bar, 'Extrude', 'P2'),
  ParityFeature(_bar, 'Zoom', 'P0'),

  // --- dockers ----------------------------------------------------------------
  ParityFeature(_dockers, 'Objects', 'P0', commands: <String>['panel.objects']),
  ParityFeature(_dockers, 'Properties (Alt+Enter)', 'P0'),
  ParityFeature(_dockers, 'Transform', 'P1',
      commands: <String>['panel.transform']),
  ParityFeature(_dockers, 'Align and Distribute', 'P0',
      commands: <String>['panel.align']),
  ParityFeature(_dockers, 'Color styles / harmonies', 'P2'),
  ParityFeature(_dockers, 'Object styles', 'P2'),
  ParityFeature(_dockers, 'Pages', 'P1'),
  ParityFeature(_dockers, 'Text (character, paragraph)', 'P1'),
  ParityFeature(_dockers, 'Glyphs', 'P2'),
  ParityFeature(_dockers, 'Symbols', 'P2'),
  ParityFeature(_dockers, 'Contour / Envelope / Lens', 'P2'),
  ParityFeature(_dockers, 'Undo history', 'P1'),
  ParityFeature(_dockers, 'Export', 'P2'),
  ParityFeature(_dockers, 'Effects', 'P2'),
  ParityFeature(_dockers, 'Hints', 'P2'),

  // --- object -----------------------------------------------------------------
  ParityFeature(_object, 'Group / Ungroup', 'P0',
      commands: <String>['object.group', 'object.ungroup']),
  ParityFeature(_object, 'Combine (Ctrl+L)', 'P0',
      commands: <String>['object.combine']),
  ParityFeature(_object, 'Break apart (Ctrl+K)', 'P0',
      commands: <String>['object.breakApart']),
  ParityFeature(_object, 'Convert to curves (Ctrl+Q)', 'P0',
      commands: <String>['object.toCurves']),
  ParityFeature(_object, 'Convert outline to object', 'P1'),
  ParityFeature(_object, 'To front / back of page', 'P0',
      commands: <String>['object.toFront', 'object.toBack'],
      partial: 'of the layer; the page has one layer stack per layer'),
  ParityFeature(_object, 'To front / back of layer', 'P0',
      commands: <String>['object.toFront', 'object.toBack']),
  ParityFeature(_object, 'Forward one / Back one', 'P0',
      commands: <String>['object.forward', 'object.backward']),
  ParityFeature(_object, 'In front of / Behind / Reverse order', 'P2'),
  ParityFeature(_object, 'Lock / Unlock objects', 'P1',
      partial: 'layers lock; single objects do not'),
  ParityFeature(_object, 'Weld', 'P0'),
  ParityFeature(_object, 'Trim', 'P0'),
  ParityFeature(_object, 'Intersect', 'P0'),
  ParityFeature(_object, 'Simplify', 'P2'),
  ParityFeature(_object, 'Front minus back / Back minus front', 'P1'),
  ParityFeature(_object, 'Boundary', 'P2'),
  ParityFeature(_object, 'Join curves / Close path', 'P1'),
  ParityFeature(_object, 'PowerClip', 'P1'),
  ParityFeature(_object, 'Mirror, rotate', 'P0',
      commands: <String>['object.flip', 'object.rotate'],
      partial: 'no Clear transformations'),
  ParityFeature(_object, 'Align & distribute', 'P0',
      commands: <String>['object.align', 'panel.align']),
  ParityFeature(_object, 'Barcode, QR code', 'P2'),
  ParityFeature(_object, 'Symmetry', 'P2'),

  // --- align keys -------------------------------------------------------------
  ParityFeature(_align, 'L / R', 'P0',
      commands: <String>['object.alignLeft', 'object.alignRight'],
      evidence: 'L lines the selection up on the last object selected'),
  ParityFeature(_align, 'T / B', 'P0',
      commands: <String>['object.alignTop', 'object.alignBottom'],
      evidence: 'B aligns to the bottom with a selection, and is the pen '
          'without'),
  ParityFeature(_align, 'C', 'P0',
      commands: <String>['object.alignCentersVertically']),
  ParityFeature(_align, 'E', 'P0',
      commands: <String>['object.alignCentersHorizontally']),
  ParityFeature(_align, 'P', 'P0',
      commands: <String>['object.centerToPage'],
      evidence: 'P centres one object on the page'),
  ParityFeature(_align, 'Shift+L/R/T/B: distribute', 'P1',
      commands: <String>['object.distribute'],
      partial: 'distributes centres from the Align panel and by command; '
          'the Shift keys are not bound'),
  ParityFeature(_align, 'Shift+C / Shift+E', 'P1'),
  ParityFeature(_align, 'Shift+P / Shift+A', 'P1'),

  // --- menus ------------------------------------------------------------------
  ParityFeature(_menus, 'Edit', 'P0',
      commands: <String>['edit.undo', 'edit.cut', 'edit.paste'],
      partial: 'no Paste Special, Find and Replace or Select by type'),
  ParityFeature(_menus, 'Layout', 'P1',
      partial: 'the menu is there; every item is still planned'),
  ParityFeature(_menus, 'Object', 'P0', commands: <String>['object.group']),
  ParityFeature(_menus, 'Effects', 'P2'),
  ParityFeature(_menus, 'Text', 'P1',
      partial: 'the menu is there; every item is still planned'),
  ParityFeature(_menus, 'Table', 'P2'),
  ParityFeature(_menus, 'Window', 'P1',
      commands: <String>['panel.objects', 'window.resetWorkspace']),
  ParityFeature(_menus, 'Help', 'P2', commands: <String>['help.about']),

  // --- nodes ------------------------------------------------------------------
  ParityFeature(_nodes, 'Node types (cusp, smooth, symmetrical)', 'P0'),
  ParityFeature(_nodes, 'Line ↔ curve', 'P0'),
  ParityFeature(_nodes, 'Add node', 'P0'),
  ParityFeature(_nodes, 'Delete node', 'P0'),
  ParityFeature(_nodes, 'Drag a segment', 'P0'),
  ParityFeature(_nodes, 'Nudge nodes', 'P0'),
  ParityFeature(_nodes, 'Select all nodes', 'P1'),
  ParityFeature(_nodes, 'Join / Break', 'P0'),
  ParityFeature(_nodes, 'Reverse direction', 'P1'),
  ParityFeature(_nodes, 'Extract subpath', 'P1'),
  ParityFeature(_nodes, 'Reduce nodes', 'P1'),
  ParityFeature(_nodes, 'Stretch, rotate, skew, align nodes', 'P2'),
  ParityFeature(_nodes, 'Elastic mode', 'P2'),
  ParityFeature(_nodes, 'Parametric shapes: corner handles', 'P0'),

  // --- snapping ---------------------------------------------------------------
  ParityFeature(_snap, 'Snap to grid', 'P0',
      commands: <String>['view.snapGrid'],
      evidence: 'a move lands an edge of the box on a grid line'),
  ParityFeature(_snap, 'Snap off (Alt+Q)', 'P1'),
  ParityFeature(_snap, 'Dynamic / alignment guides', 'P1'),
  ParityFeature(_snap, 'Rulers', 'P0',
      evidence: 'both rulers are mounted, one per axis'),
  ParityFeature(_snap, 'Guides', 'P0',
      commands: <String>['view.guides'],
      partial: 'shown; not created by dragging from a ruler'),
  ParityFeature(_snap, 'Grid', 'P1', commands: <String>['view.grid']),
  ParityFeature(_snap, 'Master page', 'P2'),

  // --- page -------------------------------------------------------------------
  ParityFeature(_page, 'Page size', 'P0',
      evidence: 'the property bar changes with the selection'),
  ParityFeature(_page, 'Orientation', 'P0',
      evidence: 'the property bar changes with the selection'),
  ParityFeature(_page, 'Rendering resolution', 'P1'),
  ParityFeature(_page, 'Bleed', 'P2'),
  ParityFeature(_page, 'Page background', 'P1'),
  ParityFeature(_page, 'Multiple pages', 'P1'),
  ParityFeature(_page, 'Layout styles', 'P2'),
  ParityFeature(_page, 'Desktop area', 'P0',
      evidence: 'the canvas still draws its page and its artwork'),

  // --- files ------------------------------------------------------------------
  ParityFeature(_files, 'AI, EPS, PS', 'P2'),
  ParityFeature(_files, 'PSD, CPT, RAW, JP2', 'P2'),
  ParityFeature(_files, 'WMF / EMF, CGM, WPG, VSD...', 'P2'),
  ParityFeature(_files, 'TTF / PFB', 'P2'),
];
