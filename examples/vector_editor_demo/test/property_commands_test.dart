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

  @override
  void findReplace() {}
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

  void ok(String id, [Map<String, Object?>? params]) {
    final outcome = registry.execute(id, params);
    expect(outcome.ok, isTrue, reason: '$id: ${outcome.error}');
  }

  SelectableObject drawn(String command, Map<String, Object?> params) {
    ok(command, params);
    ok('selection.select', <String, Object?>{'index': objects().length - 1});
    return objects().last;
  }

  const Map<String, Object?> box = <String, Object?>{
    'x': 10,
    'y': 20,
    'width': 100,
    'height': 50
  };

  test('position puts the top-left corner where asked', () {
    final SelectableObject r = drawn('shape.rectangle', box);
    ok('object.position', <String, Object?>{'x': 200, 'y': 300});
    expect(r.cacheBbox.left, closeTo(200, 1.5));
    expect(r.cacheBbox.top, closeTo(300, 1.5));
    ok('object.position', <String, Object?>{'x': 0});
    expect(r.cacheBbox.left, closeTo(0, 1.5));
    expect(r.cacheBbox.top, closeTo(300, 1.5), reason: 'y left alone');
  });

  test('outline width, caps, joins and dashes; checked follows', () {
    final SelectableObject r = drawn('shape.rectangle', box);
    ok('object.outlineWidth', <String, Object?>{'width': 3});
    ok('object.outlineStyle', <String, Object?>{
      'cap': 'round',
      'join': 'bevel',
      'dash': <Object?>[6, 3],
    });
    expect(r.style.stroke.width, 3);
    expect(r.style.stroke.cap, LineCap.round);
    expect(r.style.stroke.join, LineJoin.bevel);
    expect(r.style.stroke.dashPattern, <double>[6, 3]);
    final CommandSpec style = registry['object.outlineStyle']!;
    expect(
        style.isCheckedWith(
            const CommandArgs(<String, Object?>{'cap': 'round'})),
        isTrue);
    expect(
        style
            .isCheckedWith(const CommandArgs(<String, Object?>{'cap': 'butt'})),
        isFalse);
    expect(
        style.isCheckedWith(const CommandArgs(<String, Object?>{
          'dash': <Object?>[6, 3]
        })),
        isTrue);
    expect(
        registry.execute(
            'object.outlineStyle', <String, Object?>{'cap': 'pointy'}).error,
        contains('butt or round or square'));
  });

  test('changing the outline colour keeps its width and dashes', () {
    final SelectableObject r = drawn('shape.rectangle', box);
    ok('object.outlineWidth', <String, Object?>{'width': 4});
    ok('object.outlineStyle', <String, Object?>{
      'dash': <Object?>[2, 2]
    });
    ok('object.outline', <String, Object?>{'color': '#ff0000'});
    expect(r.style.stroke.color, const Color(0xFFFF0000));
    expect(r.style.stroke.width, 4);
    expect(r.style.stroke.dashPattern, <double>[2, 2]);
  });

  test('a dragged colour is one undo step', () {
    final SelectableObject r = drawn('shape.rectangle', box);
    final Color before = r.style.fill.color;
    for (final String c in <String>['#110000', '#220000', '#330000']) {
      ok('object.fill', <String, Object?>{'color': c, 'live': true});
    }
    expect(r.style.fill.color, const Color(0xFF330000));
    ok('edit.undo');
    expect(r.style.fill.color, before);
  });

  test('fill rule, rectangle corners, ellipse type, polygon corners', () {
    final VectorRectangle r = drawn('shape.rectangle', box) as VectorRectangle;
    ok('rectangle.round', <String, Object?>{'percent': 50});
    expect(r.corners, <double>[.5, .5, .5, .5]);
    ok('object.fillRule', <String, Object?>{'rule': 'evenOdd'});
    expect(r.style.fill.fillRule, FillRule.evenOdd);

    final VectorCircle c = drawn('shape.ellipse', box) as VectorCircle;
    ok('ellipse.type', <String, Object?>{'type': 'pieslice'});
    expect(c.arcType, ArcType.pieslice);
    expect(
        registry['ellipse.type']!.isCheckedWith(
            const CommandArgs(<String, Object?>{'type': 'pieslice'})),
        isTrue);
    expect(
        registry
            .execute('rectangle.round', <String, Object?>{'percent': 1}).error,
        contains('rectangle'));

    final VectorPolygon p = drawn('shape.polygon',
        <String, Object?>{'cx': 50, 'cy': 50, 'radius': 20}) as VectorPolygon;
    ok('polygon.corners', <String, Object?>{'corners': 8});
    expect(p.cornersNum, 8);
    expect(
        registry
            .execute('polygon.corners', <String, Object?>{'corners': 2}).error,
        contains('3 to 1000'));
  });

  test('text content and size', () {
    final VectorText t = drawn('shape.text', <String, Object?>{
      'x': 10,
      'y': 10,
      'text': 'Hello',
    }) as VectorText;
    ok('text.content', <String, Object?>{'text': 'Hello, world'});
    ok('text.size', <String, Object?>{'size': 36});
    expect(t.textContent, 'Hello, world');
    expect(t.style.textStyle.fontSize, 36);
  });
}
