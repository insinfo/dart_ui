import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';
import 'package:vector_editor_demo/src/engine/editor_commands.dart';
import 'package:vector_editor_demo/src/engine/editor_host.dart';
import 'package:vector_editor_demo/src/engine/editor_model.dart';

/// A host with no dialogs, recording what the commands asked of it.
final class _Host implements EditorHost {
  final List<String> asked = <String>[];

  @override
  Size get viewport => const Size(800, 600);

  @override
  void pickAndOpen() => asked.add('open');

  @override
  void pickAndSave(String format) => asked.add('save $format');

  @override
  void closeDocument(int index) => asked.add('close $index');

  @override
  void quit() => asked.add('quit');
}

void main() {
  late EditorModel model;
  late CommandRegistry registry;
  late _Host host;

  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  setUp(() {
    model = EditorModel(onChanged: () {});
    host = _Host();
    registry = CommandRegistry();
    registerEditorCommands(registry, model, host);
    model.newDocument();
  });

  List<SelectableObject> objects() =>
      model.active.layer.children.whereType<SelectableObject>().toList();

  test('a drawing can be made with commands alone', () {
    expect(
        registry.execute('shape.rectangle', <String, Object?>{
          'x': 10,
          'y': 20,
          'width': 100,
          'height': 50,
        }).result,
        <String, Object?>{'index': 0});
    expect(
        registry.execute('shape.ellipse', <String, Object?>{
          'x': 200,
          'y': 20,
          'width': 60,
          'height': 60,
        }).ok,
        isTrue);
    expect(
        registry
            .execute('object.fill', <String, Object?>{'color': '#ff0000'}).ok,
        isTrue);
    expect(objects(), hasLength(2));
    expect(objects().last.style.fill.color, const Color(0xFFFF0000));
    final Rect box = objects().first.cacheBbox;
    expect(box.left, closeTo(10, 1.5));
    expect(box.width, closeTo(100, 3));
  });

  test('a batch is one undo step', () {
    final outcome = registry.batch(
      <({String command, Map<String, Object?> params})>[
        (
          command: 'shape.rectangle',
          params: <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10},
        ),
        (
          command: 'shape.polygon',
          params: <String, Object?>{'cx': 50, 'cy': 50, 'radius': 20},
        ),
        (command: 'object.rotate', params: <String, Object?>{'degrees': 45}),
      ],
      label: 'Two shapes',
    );
    expect(outcome.ok, isTrue, reason: outcome.error);
    expect(objects(), hasLength(2));
    expect(model.active.api.undoDescription, 'Two shapes');
    expect(registry.execute('edit.undo').ok, isTrue);
    expect(objects(), isEmpty);
  });

  test('a typo in a parameter is refused before anything is drawn', () {
    final outcome = registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'widht': 10, 'height': 10});
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('did you mean `width`'));
    expect(objects(), isEmpty);
  });

  test('a command that needs a selection says so', () {
    final outcome = registry.execute('object.toCurves');
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('select'));
  });

  test('select, convert to curves and save to a path, no dialog', () {
    registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'width': 40, 'height': 20});
    expect(
        registry.execute('selection.select', <String, Object?>{'index': 0}).ok,
        isTrue);
    expect(registry.execute('object.toCurves').ok, isTrue);
    expect(objects().single, isA<VectorCurve>());

    final Directory dir = Directory.systemTemp.createTempSync('vector_cmd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/drawing.svg';
    final outcome =
        registry.execute('file.save', <String, Object?>{'path': path});
    expect(outcome.ok, isTrue, reason: outcome.error);
    expect(File(path).readAsStringSync(), contains('<svg'));
    expect(model.active.name, 'drawing.svg');
    expect(host.asked, isEmpty);

    expect(registry.execute('file.open', <String, Object?>{'path': path}).ok,
        isTrue);
    expect(model.documents, hasLength(2));
  });

  test('without a path, saving and opening ask the host', () {
    registry.execute('file.save');
    registry.execute('file.open');
    registry.execute('file.export', <String, Object?>{'format': 'pdf'});
    expect(host.asked, <String>['save svg', 'open', 'save pdf']);
    expect(
        registry
            .execute('file.export', <String, Object?>{'format': 'png'}).error,
        contains('cannot export png'));
  });

  test('layer commands take an index, and their state follows it', () {
    expect(registry.execute('layer.new').ok, isTrue);
    final spec = registry['layer.visible']!;
    expect(spec.isCheckedWith(const CommandArgs(<String, Object?>{'index': 0})),
        isTrue);
    registry.execute(
        'layer.visible', <String, Object?>{'index': 0, 'visible': false});
    expect(spec.isCheckedWith(const CommandArgs(<String, Object?>{'index': 0})),
        isFalse);
    expect(
        registry.execute('layer.delete', <String, Object?>{'index': 9}).error,
        contains('no such layer'));
  });

  test('combine joins outlines into one curve; break apart undoes it', () {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': 100})
      ..execute('shape.ellipse',
          <String, Object?>{'x': 25, 'y': 25, 'width': 50, 'height': 50})
      ..execute('edit.selectAll');
    final Rect before = model.selection.selectionBounds;

    expect(registry.execute('object.combine').ok, isTrue);
    final VectorCurve combined = objects().single as VectorCurve;
    expect(combined.paths, hasLength(2));
    expect(combined.cacheBbox.left, closeTo(before.left, 1.5));
    expect(combined.cacheBbox.width, closeTo(before.width, 3));
    expect(combined.style.fill.fillRule, FillRule.evenOdd,
        reason: 'the inner outline is a hole, as in CorelDRAW');
    expect(model.selection.selectedObjects, <Object>[combined]);

    expect(registry.execute('object.breakApart').ok, isTrue);
    expect(objects(), hasLength(2));
    expect(objects().every((o) => o is VectorCurve), isTrue);

    registry.execute('edit.undo');
    expect(objects().single, isA<VectorCurve>());
    registry.execute('edit.undo');
    expect(objects(), hasLength(2));
    expect(objects().first, isA<VectorRectangle>());
  });

  test('combine needs two objects, break apart several outlines', () {
    registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10});
    expect(registry.execute('object.combine').error, contains('two or more'));
    expect(registry.execute('object.breakApart').error,
        contains('several outlines'));
  });

  test('tools are commands with their CorelDRAW keys', () {
    expect(registry.execute('tool.rectangle').ok, isTrue);
    expect(model.tool, ToolMode.rectangle);
    expect(registry['tool.rectangle']!.isChecked, isTrue);
    expect(
        registry['tool.rectangle']!.shortcut, const KeyGesture(logicalKeyF6));
  });

  test('every command describes itself', () {
    final described = registry.describe();
    expect(described.length, registry.length);
    expect(described.length, greaterThan(60));
    for (final command in described) {
      expect(command['label'], isNotEmpty, reason: '${command['id']}');
    }
  });
}
