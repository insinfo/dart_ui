import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/svg/svg_picture.dart';
import 'package:test/test.dart';

void main() {
  test('parses viewBox, shapes, inherited style, and transforms', () {
    final SvgPicture picture = SvgPicture.parse('''
      <svg width="200" height="100" viewBox="0 0 20 10">
        <g fill="#ff0000" opacity="0.5" transform="translate(2, 1)">
          <rect x="0" y="0" width="4" height="2"/>
          <circle cx="10" cy="5" r="2" fill="none" stroke="blue"/>
        </g>
      </svg>
    ''');

    expect(picture.size.width, 200);
    expect(picture.size.height, 100);
    expect(picture.viewBox.width, 20);
    expect(picture.paths, hasLength(2));
    expect(picture.paths[0].fillColor, 0x80FF0000);
    expect(picture.paths[0].path.bounds.left, 0);
    expect(picture.paths[0].path.bounds.top, 0);
    expect(
      picture.paths[0].transform.transformRect(picture.paths[0].path.bounds),
      picture.paths[0].path.bounds.translate(2, 1),
    );
    expect(picture.paths[1].fillColor, isNull);
    expect(picture.paths[1].strokeColor, 0x800000FF);
  });

  test('supports inline style, currentColor, and the basic shape set', () {
    final SvgPicture picture = SvgPicture.parse(
      '''<svg viewBox="0 0 30 30" color="#123456">
        <path d="M0 0L1 1" style="fill:none;stroke:currentColor"/>
        <ellipse cx="5" cy="5" rx="2" ry="3"/>
        <line x1="0" y1="0" x2="4" y2="4"/>
        <polyline points="0,0 1,2 3,4"/>
        <polygon points="10,10 20,10 15,20"/>
      </svg>''',
    );
    expect(picture.paths, hasLength(5));
    expect(picture.paths.first.strokeColor, 0xFF123456);
  });

  test('transform lists have the SVG nested-group order', () {
    final SvgPicture picture = SvgPicture.parse('''
      <svg><rect x="1" y="1" width="1" height="1"
        transform="translate(2 0) scale(2)"/></svg>
    ''');
    // T * S maps x=1 to 4. S * T would incorrectly map it to 6.
    final Rect transformed = picture.paths.single.transform
        .transformRect(picture.paths.single.path.bounds);
    expect(transformed.left, 4);
    expect(transformed.right, 6);
  });

  test('cache reuses a parsed picture and obeys maximumSize', () {
    svgPictureCache
      ..clear()
      ..maximumSize = 1;
    addTearDown(() {
      svgPictureCache
        ..clear()
        ..maximumSize = 100;
    });
    const String source = '<svg viewBox="0 0 1 1"><path d="M0 0L1 1"/></svg>';
    final SvgPicture first = parseSvgCached('one', source);
    final SvgPicture again = parseSvgCached('one', source);
    expect(identical(first, again), isTrue);
    parseSvgCached('two', source);
    expect(svgPictureCache.count, 1);
    expect(svgPictureCache['one'], isNull);
  });

  test('rejects non-SVG XML and declared resource excess', () {
    expect(
      () => SvgPicture.parse('<html/>'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => SvgPicture.parse(
        '<svg><g><path d="M0 0"/></g></svg>',
        limits: const SvgLimits(maxElements: 2),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
