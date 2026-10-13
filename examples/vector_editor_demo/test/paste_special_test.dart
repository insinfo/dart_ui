/// Edit > Paste Special and Copy as a picture, against a host with a
/// system clipboard of its own.
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';
import 'package:vector_editor_demo/src/engine/editor_commands.dart';
import 'package:vector_editor_demo/src/engine/editor_host.dart';
import 'package:vector_editor_demo/src/engine/editor_model.dart';

/// No dialogs, a clipboard in memory.
final class _Host implements EditorHost, EditorClipboardHost {
  Uint8List? image;
  String? text;
  List<String>? offered;
  List<SelectableObject>? pictured;

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

  @override
  Future<Set<String>> clipboardFormats() async => <String>{
        if (image != null) 'image',
        if (text != null) 'text',
      };

  @override
  Future<Uint8List?> clipboardImage() async => image;

  @override
  Future<String?> clipboardText() async => text;

  @override
  Future<void> copyPicture(List<SelectableObject> objects) async =>
      pictured = objects;

  @override
  void choosePasteFormat(List<String> formats) => offered = formats;
}

Uint8List _png() => encodePng(
      width: 2,
      height: 2,
      pixels: Uint8List.fromList(<int>[
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 255, 255,
      ]),
    );

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

  Future<CommandOutcome> run(String id, [Map<String, Object?>? params]) async {
    final CommandOutcome outcome = registry.execute(id, params);
    return outcome.isPending ? outcome.completion! : outcome;
  }

  test('without a format it offers what there is, copies first', () async {
    registry
      ..execute('shape.rectangle',
          <String, Object?>{'x': 0, 'y': 0, 'width': 10, 'height': 10})
      ..execute('edit.selectAll')
      ..execute('edit.copy');
    host.image = _png();
    expect((await run('edit.pasteSpecial')).ok, isTrue);
    expect(host.offered, <String>['objects', 'image']);
    expect(host.pictured, hasLength(1),
        reason: 'the copy also went to the system clipboard as a picture');
  });

  test('an image comes in as a picture in the middle of the page', () async {
    host.image = _png();
    final CommandOutcome outcome =
        await run('edit.pasteSpecial', <String, Object?>{'format': 'image'});
    expect(outcome.ok, isTrue, reason: outcome.error);
    final VectorPixmap picture = objects().single as VectorPixmap;
    expect(picture.pixelWidth, 2);
    final PageFormat page = model.active.page.pageFormat;
    expect(picture.cacheBbox.center.dx, closeTo(page.width / 2, 1e-6));
    expect(model.active.api.undoDescription, isNotNull);
  });

  test('SVG text comes in as its objects; other text as a text', () async {
    host.text = '<svg xmlns="http://www.w3.org/2000/svg" width="100" '
        'height="100"><rect x="0" y="0" width="40" height="20"/>'
        '<circle cx="80" cy="80" r="10"/></svg>';
    expect(
        (await run('edit.pasteSpecial', <String, Object?>{'format': 'text'}))
            .ok,
        isTrue);
    expect(objects(), hasLength(2));
    host.text = 'Hello\nworld';
    await run('edit.pasteSpecial', <String, Object?>{'format': 'text'});
    expect((objects().last as VectorText).textContent, 'Hello\nworld');
  });

  test('asking for what is not there is a refusal that says why', () async {
    final CommandOutcome noImage =
        await run('edit.pasteSpecial', <String, Object?>{'format': 'image'});
    expect(noImage.ok, isFalse);
    expect(noImage.error, contains('no image'));
    final CommandOutcome nothing = await run('edit.pasteSpecial');
    expect(nothing.error, contains('empty'));
  });
}
