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

  List<SelectableObject> objects() =>
      model.active.layer.children.whereType<SelectableObject>().toList();

  /// Two 100x100 squares overlapping by a quarter, the second red and
  /// selected last - the target.
  void twoSquares() {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': 100})
      ..execute('shape.rectangle',
          <String, Object?>{'x': 50, 'y': 50, 'width': 100, 'height': 100})
      ..execute('selection.select', <String, Object?>{'index': 1})
      ..execute('object.fill', <String, Object?>{'color': '#ff0000'})
      ..execute('selection.select', <String, Object?>{'index': 0})
      ..execute('selection.select', <String, Object?>{'index': 1, 'add': true});
  }

  double areaOf(SelectableObject object) {
    final VectorCurve curve = object as VectorCurve;
    var total = 0.0;
    for (final VectorPath path in curve.paths) {
      final List<Offset> polygon = <Offset>[
        path.start,
        for (final Object p in path.points)
          p is CurvePoint ? p.endpoint : p as Offset,
      ];
      for (var i = 0; i < polygon.length; i++) {
        final Offset a = polygon[i];
        final Offset b = polygon[(i + 1) % polygon.length];
        total += a.dx * b.dy - b.dx * a.dy;
      }
    }
    return (total / 2).abs();
  }

  void ok(String id) {
    final outcome = registry.execute(id);
    expect(outcome.ok, isTrue, reason: '$id: ${outcome.error}');
  }

  test('shaping needs two outlines', () {
    registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10});
    registry.execute('selection.select', <String, Object?>{'index': 0});
    expect(registry.execute('object.weld').error, contains('two or more'));
  });

  test('weld makes one curve in the target\'s style, one undo', () {
    twoSquares();
    ok('object.weld');
    expect(objects(), hasLength(1));
    expect(objects().single, isA<VectorCurve>());
    expect(areaOf(objects().single), closeTo(17500, 0.01));
    expect(objects().single.style.fill.color, const Color(0xFFFF0000));
    expect(model.selection.selectedObjects, objects());
    expect(model.active.api.undoDescription, 'Weld');
    ok('edit.undo');
    expect(objects(), hasLength(2));
  });

  test('trim cuts the others out of the target, and they stay', () {
    twoSquares();
    ok('object.trim');
    expect(objects(), hasLength(2));
    expect(objects()[0], isA<VectorRectangle>(), reason: 'the trimmer stays');
    expect(areaOf(objects()[1]), closeTo(7500, 0.01));
    expect(objects()[1].style.fill.color, const Color(0xFFFF0000));
  });

  test('intersect adds the overlap above the target', () {
    twoSquares();
    ok('object.intersect');
    expect(objects(), hasLength(3));
    expect(areaOf(objects().last), closeTo(2500, 0.01));
    expect(model.selection.selectedObjects.single, objects().last);
  });

  test('intersect of objects apart says so and changes nothing', () {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10})
      ..execute('shape.rectangle',
          <String, Object?>{'x': 50, 'y': 0, 'width': 10, 'height': 10})
      ..execute('edit.selectAll');
    expect(registry.execute('object.intersect').error, contains('overlap'));
    expect(objects(), hasLength(2));
  });
}
