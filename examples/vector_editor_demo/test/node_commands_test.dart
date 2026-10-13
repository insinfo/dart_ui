import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';
import 'package:vector_editor_demo/src/engine/editor_commands.dart';
import 'package:vector_editor_demo/src/engine/editor_host.dart';
import 'package:vector_editor_demo/src/engine/editor_model.dart';

final class _Host implements EditorHost {
  @override
  Size get viewport => const Size(800, 600);

  @override
  void pickAndOpen() {}

  @override
  void pickAndSave(String format) {}

  @override
  void closeDocument(int index) {}

  @override
  void quit() {}
}

void main() {
  late EditorModel model;
  late CommandRegistry registry;

  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  setUp(() {
    model = EditorModel(onChanged: () {});
    registry = CommandRegistry();
    registerEditorCommands(registry, model, _Host());
    model.newDocument();
  });

  /// A rectangle converted to curves, selected, under the Shape tool.
  VectorCurve curve() {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': 50})
      ..execute('selection.select', <String, Object?>{'index': 0})
      ..execute('object.toCurves')
      ..execute('tool.shape');
    return model.selection.syncNodeCurve()!;
  }

  int nodes(VectorCurve c) => NodeEditing.nodeCount(c.paths.single);

  void ok(String id) {
    final outcome = registry.execute(id);
    expect(outcome.ok, isTrue, reason: '$id: ${outcome.error}');
  }

  test('node commands need a curve, then picked nodes', () {
    expect(registry.execute('path.selectAllNodes').error, contains('curve'));
    curve();
    expect(registry.execute('path.deleteNodes').error, contains('pick nodes'));
    ok('path.selectAllNodes');
    expect(model.selection.nodes.nodes, hasLength(4));
  });

  test('add node halves the segments before the picked nodes, one undo', () {
    final VectorCurve c = curve();
    final int before = nodes(c);
    ok('path.selectAllNodes');
    ok('path.addNode');
    expect(nodes(c), greaterThan(before));
    expect(model.active.api.undoDescription, 'Add node');
    ok('edit.undo');
    expect(nodes(c), before);
  });

  test('delete nodes removes them, and the curve when none is left', () {
    final VectorCurve c = curve();
    model.selection.nodes.select(<PathNode>[const PathNode(0, 1)]);
    ok('path.deleteNodes');
    expect(nodes(c), 3);

    ok('path.selectAllNodes');
    ok('path.deleteNodes');
    expect(model.active.layer.children.whereType<VectorCurve>(), isEmpty);
    ok('edit.undo');
    expect(model.active.layer.children.whereType<VectorCurve>(), hasLength(1));
  });

  test('Delete removes the picked nodes under the Shape tool, else the object',
      () {
    final VectorCurve c = curve();
    final KeyGesture delete =
        registry['edit.delete']!.shortcut!; // Backspace on a Mac
    model.selection.nodes.select(<PathNode>[const PathNode(0, 2)]);
    registry.keyBindings()[delete]!();
    expect(nodes(c), 3, reason: 'the node went, not the curve');
    expect(model.active.layer.children.whereType<VectorCurve>(), hasLength(1));

    model.selection.nodes.clearNodes();
    registry.keyBindings()[delete]!();
    expect(model.active.layer.children.whereType<VectorCurve>(), isEmpty);
  });

  test('to curve, then smooth: the node type follows', () {
    final VectorCurve c = curve();
    model.selection.nodes.select(<PathNode>[const PathNode(0, 1)]);
    ok('path.toCurve');
    ok('path.symmetrical');
    expect(NodeEditing.typeOf(c, const PathNode(0, 1)), NodeType.symmetrical);
    ok('path.cusp');
    expect(NodeEditing.typeOf(c, const PathNode(0, 1)), NodeType.cusp);
  });

  test('break opens the path; join closes it again', () {
    final VectorCurve c = curve();
    model.selection.nodes.select(<PathNode>[const PathNode(0, 2)]);
    ok('path.breakNode');
    expect(c.paths.every((VectorPath p) => !p.isClosed), isTrue);
    expect(model.selection.nodes.nodes, hasLength(2));
    ok('path.joinNodes');
    expect(c.paths.any((VectorPath p) => p.isClosed), isTrue);
  });

  test('the arrows nudge the picked nodes under the Shape tool', () {
    final VectorCurve c = curve();
    const PathNode node = PathNode(0, 1);
    final Offset before = NodeEditing.toDocument(
        c, NodeEditing.nodePoint(c.paths.single, node.index));
    final Rect box = c.cacheBbox;
    model.selection.nodes.select(<PathNode>[node]);
    expect(registry.execute('object.nudge', <String, Object?>{'dx': 1}).ok,
        isTrue);
    final Offset after = NodeEditing.toDocument(
        c, NodeEditing.nodePoint(c.paths.single, node.index));
    expect(after.dx - before.dx, closeTo(DocUnit.mm.toPoints, 1e-6));
    expect(after.dy, closeTo(before.dy, 1e-6));
    expect(model.active.api.undoDescription, 'Nudge nodes');

    model.selection.nodes.clearNodes();
    registry.execute('object.nudge', <String, Object?>{'dx': 1});
    expect(c.cacheBbox.left, isNot(closeTo(box.left, 1e-6)),
        reason: 'with no node picked the object moves');
  });

  test('F10 picks the Shape tool', () {
    final KeyGesture f10 = registry['tool.shape']!.shortcut!;
    expect(f10, const KeyGesture(logicalKeyF10));
    registry.keyBindings()[f10]!();
    expect(model.tool, ToolMode.shaper);
  });
}
