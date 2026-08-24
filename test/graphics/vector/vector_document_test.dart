import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('VectorDocument Model Tests', () {
    test('default document structure initializes with 1 page and 1 layer', () {
      final doc = VectorDocument(docUnits: DocUnit.mm);

      expect(doc.pageCount, equals(1));
      final page = doc.getPage(0);
      expect(page.pageFormat.name, equals('A4'));
      expect(page.width, closeTo(595.28, 0.1));
      expect(page.height, closeTo(841.89, 0.1));

      final layers = doc.getPageLayers(page);
      expect(layers.length, equals(1));
      expect(layers.first.name, equals('Layer 1'));
      expect(layers.first.isVisible, isTrue);
      expect(layers.first.isEditable, isTrue);
    });

    test('adding and removing pages updates pageList and indices', () {
      final doc = VectorDocument();
      expect(doc.pageCount, equals(1));

      final page2 = doc.addPage(name: 'Page 2', format: const PageFormat.letterPortrait());
      expect(doc.pageCount, equals(2));
      expect(doc.getPage(1).name, equals('Page 2'));

      doc.removePage(0);
      expect(doc.pageCount, equals(1));
      expect(doc.getPage(0), equals(page2));
    });

    test('primitives creation, geometry evaluation, and bounding boxes', () {
      final doc = VectorDocument();
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      // 1. Rectangle
      final rect = methods.createRectangle(
        x: 10,
        y: 20,
        width: 100,
        height: 50,
      );
      methods.addObject(layer, rect);
      // With 1.0pt stroke width, bounds expand by 0.5 on each side
      expect(rect.cacheBbox, equals(const Rect.fromLTRB(9.5, 19.5, 110.5, 70.5)));

      // 2. Circle
      final circle = methods.createCircle(
        cx: 200,
        cy: 200,
        rx: 50,
        ry: 50,
      );
      methods.addObject(layer, circle);
      expect(circle.cacheBbox.width, closeTo(101.0, 0.1));
      expect(circle.cacheBbox.height, closeTo(101.0, 0.1));

      // 3. Polygon
      final poly = methods.createPolygon(
        cx: 300,
        cy: 300,
        radius: 40,
        cornersNum: 6,
      );
      methods.addObject(layer, poly);
      expect(poly.cornersNum, equals(6));
      expect(poly.cacheBbox.width, greaterThan(0));

      expect(layer.children.length, equals(3));
    });

    test('grouping and ungrouping objects preserves coordinates and transforms', () {
      final doc = VectorDocument();
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final r1 = methods.createRectangle(x: 0, y: 0, width: 20, height: 20);
      final r2 = methods.createRectangle(x: 50, y: 50, width: 20, height: 20);
      methods.addObject(layer, r1);
      methods.addObject(layer, r2);

      final group = methods.groupObjects([r1, r2]);
      expect(layer.children.length, equals(1));
      expect(layer.children.first, equals(group));
      expect(group.children.length, equals(2));

      // Move group
      methods.moveObject(group, 10, 10);
      expect(group.cacheBbox.left, closeTo(9.5, 0.1));

      // Ungroup
      final ungrouped = methods.ungroupObjects(group);
      expect(ungrouped.length, equals(2));
      expect(layer.children.length, equals(2));
    });

    test('deep copy clones document tree without sharing mutable instances', () {
      final doc = VectorDocument();
      final methods = DocumentMethods(doc);
      final page = doc.getPage(0);
      final layer = doc.getPageLayers(page).first;

      final r1 = methods.createRectangle(x: 10, y: 10, width: 50, height: 50);
      methods.addObject(layer, r1);

      final clone = doc.copy() as VectorDocument;
      expect(clone.pageCount, equals(doc.pageCount));
      expect(identical(clone, doc), isFalse);

      final cloneLayer = clone.getPageLayers(clone.getPage(0)).first;
      expect(identical(cloneLayer, layer), isFalse);
      expect(cloneLayer.children.length, equals(layer.children.length));
    });
  });
}
