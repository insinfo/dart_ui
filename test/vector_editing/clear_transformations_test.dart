/// Clear Transformations: an object back to the shape it was created with,
/// centred where it stands, with its fill brought back along.
library;

import 'package:dart_ui/vector.dart';
import 'package:test/test.dart';

void main() {
  late DocumentMethods methods;

  setUp(() => methods = DocumentMethods(VectorDocument()));

  List<double> rotation(double degrees, Offset about) {
    final List<double> turn = trafoRotate(degrees * 3.141592653589793 / 180);
    return multiplyTrafo(<double>[1, 0, 0, 1, about.dx, about.dy],
        multiplyTrafo(turn, <double>[1, 0, 0, 1, -about.dx, -about.dy]));
  }

  test('invertTrafo undoes a transform, and refuses a flattening one', () {
    const List<double> t = <double>[2, 0.5, -1, 3, 10, -4];
    final List<double> back = multiplyTrafo(invertTrafo(t)!, t);
    for (int i = 0; i < 6; i++) {
      expect(back[i], closeTo(kNormalTrafo[i], 1e-12));
    }
    expect(invertTrafo(const <double>[1, 2, 2, 4, 0, 0]), isNull);
  });

  test('a rotated, stretched ellipse comes back, centred where it was', () {
    final VectorCircle ellipse =
        methods.createCircle(cx: 50, cy: 50, rx: 40, ry: 10);
    final Rect created = ellipse.cacheBbox;
    ellipse
      ..applyTrafo(rotation(30, const Offset(50, 50)))
      ..applyTrafo(const <double>[1.5, 0, 0, 1, 0, 0])
      ..applyTrafo(const <double>[1, 0, 0, 1, 25, 5]);
    final Offset centre = ellipse.cacheBbox.center;

    expect(methods.clearTransformations(ellipse), isTrue);
    expect(ellipse.cacheBbox.width, closeTo(created.width, 1e-6));
    expect(ellipse.cacheBbox.height, closeTo(created.height, 1e-6));
    expect((ellipse.cacheBbox.center - centre).distance, lessThan(1e-6));
  });

  test('a moved rectangle has nothing to clear; a rotated one does', () {
    final VectorRectangle rectangle =
        methods.createRectangle(x: 0, y: 0, width: 30, height: 10);
    // The box takes in half the outline on each side.
    final Size created = rectangle.cacheBbox.size;
    rectangle.applyTrafo(const <double>[1, 0, 0, 1, 7, 7]);
    expect(methods.clearTransformations(rectangle), isFalse);
    rectangle.applyTrafo(rotation(90, rectangle.cacheBbox.center));
    expect(rectangle.cacheBbox.height, closeTo(created.width, 1e-6));
    expect(methods.clearTransformations(rectangle), isTrue);
    expect(rectangle.cacheBbox.width, closeTo(created.width, 1e-6));
    expect(rectangle.cacheBbox.height, closeTo(created.height, 1e-6));
  });

  test('a group clears each member', () {
    final VectorRectangle a =
        methods.createRectangle(x: 0, y: 0, width: 20, height: 10);
    final VectorRectangle b =
        methods.createRectangle(x: 40, y: 0, width: 20, height: 10);
    final Size created = a.cacheBbox.size;
    final VectorGroup group = VectorGroup(children: <DocumentObject>[a, b])
      ..update();
    group.applyTrafo(rotation(90, group.cacheBbox.center));
    expect(methods.clearTransformations(group), isTrue);
    expect(a.cacheBbox.width, closeTo(created.width, 1e-6));
    expect(b.cacheBbox.height, closeTo(created.height, 1e-6));
  });
}
