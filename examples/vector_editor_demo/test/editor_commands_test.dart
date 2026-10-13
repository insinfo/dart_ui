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

  @override
  void findReplace() => asked.add('find');
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

  test('Clear Transformations brings back the shapes, centred in place', () {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': 40})
      ..execute('shape.ellipse',
          <String, Object?>{'x': 200, 'y': 0, 'width': 80, 'height': 20})
      ..execute('edit.selectAll')
      ..execute('object.rotate', <String, Object?>{'degrees': 30})
      ..execute('object.flip', <String, Object?>{'direction': 'horizontal'});
    final List<Offset> centres = <Offset>[
      for (final SelectableObject object in objects()) object.cacheBbox.center,
    ];
    expect(objects().first.cacheBbox.height, greaterThan(41),
        reason: 'rotated, the rectangle stands taller');

    expect(registry.execute('object.clearTransformations').ok, isTrue);
    final Rect rectangle = objects().first.cacheBbox;
    final Rect ellipse = objects().last.cacheBbox;
    expect(rectangle.width, closeTo(100, 2));
    expect(rectangle.height, closeTo(40, 2));
    expect(ellipse.width, closeTo(80, 2));
    expect(ellipse.height, closeTo(20, 2));
    for (int i = 0; i < 2; i++) {
      expect(
          (objects()[i].cacheBbox.center - centres[i]).distance, lessThan(0.5),
          reason: 'cleared where it stood');
    }
    expect(model.active.api.undoDescription, 'Clear transformations');
    expect(registry.execute('edit.undo').ok, isTrue);
    expect(objects().first.cacheBbox.height, greaterThan(41));
  });

  test('a curve has nothing to clear', () {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 40, 'height': 20})
      ..execute('selection.select', <String, Object?>{'index': 0})
      ..execute('object.rotate', <String, Object?>{'degrees': 45})
      ..execute('object.toCurves');
    final Rect before = objects().single.cacheBbox;
    expect(registry.execute('object.clearTransformations').ok, isTrue);
    expect(objects().single.cacheBbox, before);
    expect(model.status, contains('Nothing to clear'));
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

  test('page width and page height fit one side of the page, centred', () {
    final Rect page = model.active.page.rect;
    registry.execute('view.zoomPageWidth');
    final double zoom = model.active.zoom;
    expect(page.width * zoom, closeTo(800 - 48, 0.01));
    // The page's centre is the window's centre.
    expect(model.active.pan.dx + page.center.dx * zoom, closeTo(400, 0.01));
    expect(model.active.pan.dy + page.center.dy * zoom, closeTo(300, 0.01));
    registry.execute('view.zoomPageHeight');
    expect(page.height * model.active.zoom, closeTo(600 - 48, 0.01));
  });

  test('select all of a type; replace text across the page in one undo', () {
    registry
      ..execute('shape.rectangle', <String, Object?>{
        'x': 0,
        'y': 0,
        'width': 10,
        'height': 10,
      })
      ..execute('shape.text', <String, Object?>{
        'x': 0,
        'y': 50,
        'text': 'Hello world, hello',
      })
      ..execute('shape.text', <String, Object?>{
        'x': 0,
        'y': 80,
        'text': 'Nothing here',
      });
    expect(
        registry.execute(
            'edit.selectAll', <String, Object?>{'type': 'text'}).result,
        <String, Object?>{'selected': 2});
    expect(
        model.selection.selectedObjects.whereType<VectorText>(), hasLength(2));
    expect(
        registry.execute('edit.replaceText', <String, Object?>{
          'find': 'hello',
          'replace': 'bye',
          'matchCase': false,
        }).result,
        <String, Object?>{'replaced': 2});
    expect(
        objects().whereType<VectorText>().first.textContent, 'bye world, bye');
    model.undo();
    expect(objects().whereType<VectorText>().first.textContent,
        'Hello world, hello');
    registry.execute('edit.findReplace');
    expect(host.asked, contains('find'), reason: 'the dialog is the host\'s');
  });

  test('to front and back of the page cross layers', () {
    registry.execute('shape.rectangle', <String, Object?>{
      'x': 0,
      'y': 0,
      'width': 10,
      'height': 10,
    });
    final SelectableObject rect = objects().single;
    registry.execute('layer.new');
    final List<VectorLayer> layers = model.active.layers;
    expect(layers, hasLength(2));
    model.pickObject(rect);
    registry.execute('object.toFrontOfPage');
    expect(rect.parent, same(layers.last), reason: 'onto the top layer');
    registry.execute('object.toBackOfPage');
    expect(rect.parent, same(layers.first));
    expect(layers.first.children.first, same(rect));
  });

  test('a curve made by command takes arrowheads by name', () {
    expect(
        registry.execute('shape.curve', <String, Object?>{
          'points': <double>[0, 0, 100, 0, 100, 50],
        }).ok,
        isTrue);
    final VectorCurve curve = objects().whereType<VectorCurve>().single;
    expect(curve.paths.single.points, hasLength(2));
    registry.execute('object.arrows',
        <String, Object?>{'start': 'circle', 'end': 'triangle'});
    expect(ArrowHead.of(curve.style.stroke.startArrow), ArrowHead.circle);
    expect(ArrowHead.of(curve.style.stroke.endArrow), ArrowHead.triangle);
    expect(
        registry['object.arrows']!.isCheckedWith(
            const CommandArgs(<String, Object?>{'end': 'triangle'})),
        isTrue);
    registry.execute('object.arrows', <String, Object?>{'end': 'none'});
    expect(ArrowHead.of(curve.style.stroke.endArrow), ArrowHead.none);
    expect(
        registry.execute('shape.curve', <String, Object?>{
          'points': <double>[0, 0, 1],
        }).ok,
        isFalse,
        reason: 'an odd list is refused');
  });

  test('a text takes a font, bold, italic and alignment, each undoable', () {
    registry.execute(
        'shape.text', <String, Object?>{'x': 0, 'y': 50, 'text': 'Title'});
    final VectorText text = objects().whereType<VectorText>().single;
    registry.execute('text.font', <String, Object?>{'family': 'Georgia'});
    expect(text.style.textStyle.fontFamily, 'Georgia');
    expect(registry.execute('text.bold').result, isTrue, reason: 'toggled on');
    expect(registry['text.bold']!.isChecked, isTrue);
    registry.execute('text.italic', <String, Object?>{'on': true});
    expect(text.style.textStyle.italic, isTrue);
    registry.execute('text.align', <String, Object?>{'align': 'right'});
    expect(text.style.textStyle.alignment, VectorTextAlign.right);
    model.undo();
    expect(text.style.textStyle.alignment, VectorTextAlign.left);
    expect(registry.execute('text.bold').result, isFalse,
        reason: 'toggled back off');
  });

  test('a fountain fill, linear along an angle or radial, in one undo', () {
    registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10});
    final SelectableObject rect = objects().single;
    registry.execute('object.fountainFill', <String, Object?>{
      'type': 'linear',
      'from': '#FF0000',
      'to': '#0000FF',
      'angle': 90,
    });
    final FillDescriptor fill = rect.style.fill;
    expect(fill.fillType, FillType.linearGradient);
    expect(fill.gradientStops.first.color, const Color(0xFFFF0000));
    expect(fill.gradientStops.last.color, const Color(0xFF0000FF));
    expect(fill.gradientStart.dx, closeTo(0.5, 1e-9), reason: '90 degrees');
    expect(fill.gradientEnd.dy, closeTo(1, 1e-9), reason: 'runs downward');
    expect(
        registry['object.fountainFill']!.isCheckedWith(
            const CommandArgs(<String, Object?>{'type': 'linear'})),
        isTrue);
    registry.execute('object.fountainFill', <String, Object?>{
      'type': 'radial',
      'from': '#FFFFFF',
      'to': '#000000',
    });
    expect(rect.style.fill.fillType, FillType.radialGradient);
    model.undo();
    expect(rect.style.fill.fillType, FillType.linearGradient);
  });
}
