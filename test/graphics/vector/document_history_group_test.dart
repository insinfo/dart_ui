import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late VectorDocument document;
  late DocumentHistory history;
  late VectorLayer layer;

  VectorRectangle rectangle(double x) => VectorRectangle(
        trafo: <double>[10, 0, 0, 10, x, 0],
        style: VectorStyle.defaultFill,
      );

  setUp(() {
    document = VectorDocument();
    layer = document.getPageLayers(document.getPage(0)).first;
    history = DocumentHistory(document);
  });

  test('a group of steps is one undo', () {
    history.group('Make two', () {
      history.record('First', () => layer.children.add(rectangle(0)));
      history.record('Second', () => layer.children.add(rectangle(20)));
    });
    expect(history.undoLabel, 'Make two');
    expect(layer.children, hasLength(2));
    history.undo();
    expect(layer.children, isEmpty);
    expect(history.canUndo, isFalse);
    history.redo();
    expect(layer.children, hasLength(2));
  });

  test('nested groups commit once, at the outermost', () {
    history.group('Outer', () {
      history.group('Inner', () {
        history.record('One', () => layer.children.add(rectangle(0)));
      });
      history.record('Two', () => layer.children.add(rectangle(20)));
    });
    expect(history.undoLabel, 'Outer');
    history.undo();
    expect(history.canUndo, isFalse);
  });

  test('a group that recorded nothing leaves no step', () {
    history.group('Nothing', () {});
    expect(history.canUndo, isFalse);
  });

  test('undo is refused inside a group', () {
    history.record('Before', () => layer.children.add(rectangle(0)));
    history.group('Group', () {
      expect(history.undo(), isFalse);
    });
    expect(layer.children, hasLength(1));
  });
}
