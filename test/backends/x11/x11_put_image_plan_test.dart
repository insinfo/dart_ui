import 'package:dart_ui/src/backends/x11/x11_put_image_plan.dart';
import 'package:test/test.dart';

void main() {
  group('request limits', () {
    test('uses the exact 24-byte core overhead', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 4,
        pixelHeight: 1,
        bytesPerRow: 16,
        maximumRequestUnits: 10, // 40 bytes: 24 header + 16 payload.
      );

      expect(plan.requestOverheadBytes, 24);
      expect(plan.maximumPayloadBytes, 16);
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.byteLength, 16);
    });

    test('uses the extra four-byte BIG-REQUESTS header', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 1,
        pixelHeight: 1,
        bytesPerRow: 4,
        maximumRequestUnits: 0x10000,
      );

      expect(plan.requestOverheadBytes, 28);
      expect(plan.maximumPayloadBytes, 0x10000 * 4 - 28);
    });

    test('accepts exactly one pixel after the header', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 1,
        pixelHeight: 2,
        bytesPerRow: 4,
        maximumRequestUnits: 7,
      );

      expect(plan.maximumPayloadBytes, 4);
      expect(plan.segments, hasLength(2));
      expect(plan.segments.map((segment) => segment.byteLength), <int>[4, 4]);
    });

    test('rejects a limit with no room for one pixel', () {
      expect(
        () => X11PutImagePlan.create(
          pixelWidth: 1,
          pixelHeight: 1,
          bytesPerRow: 4,
          maximumRequestUnits: 6,
        ),
        throwsArgumentError,
      );
    });
  });

  group('vertical bands', () {
    test('splits tightly packed full rows and keeps the last partial band', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 5,
        pixelHeight: 5,
        bytesPerRow: 20,
        maximumRequestUnits: 16, // 64 bytes, 40-byte payload.
      );

      expect(plan.maximumPayloadBytes, 40);
      expect(plan.segments, hasLength(3));
      _expectSegment(
        plan.segments[0],
        sourceOffset: 0,
        x: 0,
        y: 0,
        width: 5,
        height: 2,
        byteLength: 40,
      );
      _expectSegment(
        plan.segments[1],
        sourceOffset: 40,
        x: 0,
        y: 2,
        width: 5,
        height: 2,
        byteLength: 40,
      );
      _expectSegment(
        plan.segments[2],
        sourceOffset: 80,
        x: 0,
        y: 4,
        width: 5,
        height: 1,
        byteLength: 20,
      );
      expect(plan.totalPayloadBytes, 100);
    });

    test('plans only the requested vertical region', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 8,
        pixelHeight: 10,
        bytesPerRow: 32,
        maximumRequestUnits: 22, // 88 bytes, 64-byte payload.
        top: 3,
        height: 4,
      );

      expect(plan.segments, hasLength(2));
      _expectSegment(
        plan.segments[0],
        sourceOffset: 96,
        x: 0,
        y: 3,
        width: 8,
        height: 2,
        byteLength: 64,
      );
      _expectSegment(
        plan.segments[1],
        sourceOffset: 160,
        x: 0,
        y: 5,
        width: 8,
        height: 2,
        byteLength: 64,
      );
    });
  });

  group('horizontal tiles', () {
    test('tiles every row when a complete row exceeds the payload', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 10,
        pixelHeight: 2,
        bytesPerRow: 40,
        maximumRequestUnits: 10, // 16 payload bytes, four pixels.
      );

      expect(plan.segments, hasLength(6));
      expect(
        plan.segments.map((segment) => segment.width),
        <int>[4, 4, 2, 4, 4, 2],
      );
      expect(
        plan.segments.map((segment) => segment.height),
        everyElement(1),
      );
      expect(
        plan.segments.map((segment) => segment.sourceOffset),
        <int>[0, 16, 32, 40, 56, 72],
      );
      expect(
        plan.segments.map((segment) => (segment.x, segment.y)),
        <(int, int)>[(0, 0), (4, 0), (8, 0), (0, 1), (4, 1), (8, 1)],
      );
      expect(plan.totalPayloadBytes, 80);
    });

    test('narrow regions never include bytes between source rows', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 8,
        pixelHeight: 4,
        bytesPerRow: 32,
        maximumRequestUnits: 100,
        left: 2,
        top: 1,
        width: 3,
        height: 2,
      );

      expect(plan.segments, hasLength(2));
      _expectSegment(
        plan.segments[0],
        sourceOffset: 40,
        x: 2,
        y: 1,
        width: 3,
        height: 1,
        byteLength: 12,
      );
      _expectSegment(
        plan.segments[1],
        sourceOffset: 72,
        x: 2,
        y: 2,
        width: 3,
        height: 1,
        byteLength: 12,
      );
    });

    test('padded framebuffers use independent contiguous rows', () {
      final plan = X11PutImagePlan.create(
        pixelWidth: 3,
        pixelHeight: 2,
        bytesPerRow: 16,
        maximumRequestUnits: 100,
      );

      expect(plan.segments, hasLength(2));
      expect(
          plan.segments.map((segment) => segment.sourceOffset), <int>[0, 16]);
      expect(plan.segments.map((segment) => segment.byteLength), <int>[12, 12]);
    });
  });

  test('segments cover the region once without gaps or overlaps', () {
    const width = 13;
    const height = 7;
    final plan = X11PutImagePlan.create(
      pixelWidth: width,
      pixelHeight: height,
      bytesPerRow: width * 4,
      maximumRequestUnits: 11, // 20 payload bytes: five pixels per tile.
    );
    final coverage = List<List<int>>.generate(
      height,
      (_) => List<int>.filled(width, 0),
    );

    for (final segment in plan.segments) {
      expect(segment.byteLength, lessThanOrEqualTo(plan.maximumPayloadBytes));
      expect(segment.byteLength, segment.width * segment.height * 4);
      for (var y = segment.y; y < segment.y + segment.height; y++) {
        for (var x = segment.x; x < segment.x + segment.width; x++) {
          coverage[y][x]++;
        }
      }
    }

    for (final row in coverage) {
      expect(row, everyElement(1));
    }
    expect(plan.totalPayloadBytes, width * height * 4);
  });

  group('invalid input', () {
    test('rejects invalid framebuffer dimensions and stride', () {
      for (final create in <X11PutImagePlan Function()>[
        () => X11PutImagePlan.create(
              pixelWidth: 0,
              pixelHeight: 1,
              bytesPerRow: 4,
              maximumRequestUnits: 100,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 1,
              pixelHeight: 0,
              bytesPerRow: 4,
              maximumRequestUnits: 100,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 0x10000,
              pixelHeight: 1,
              bytesPerRow: 0x10000 * 4,
              maximumRequestUnits: 100,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 2,
              pixelHeight: 1,
              bytesPerRow: 4,
              maximumRequestUnits: 100,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 2,
              pixelHeight: 1,
              bytesPerRow: 9,
              maximumRequestUnits: 100,
            ),
      ]) {
        expect(create, throwsArgumentError);
      }
    });

    test('rejects invalid maximum request units', () {
      for (final units in <int>[0, -1, 0x100000000]) {
        expect(
          () => X11PutImagePlan.create(
            pixelWidth: 1,
            pixelHeight: 1,
            bytesPerRow: 4,
            maximumRequestUnits: units,
          ),
          throwsArgumentError,
        );
      }
    });

    test('rejects empty, negative, or out-of-bounds regions', () {
      for (final create in <X11PutImagePlan Function()>[
        () => X11PutImagePlan.create(
              pixelWidth: 10,
              pixelHeight: 10,
              bytesPerRow: 40,
              maximumRequestUnits: 100,
              left: -1,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 10,
              pixelHeight: 10,
              bytesPerRow: 40,
              maximumRequestUnits: 100,
              top: -1,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 10,
              pixelHeight: 10,
              bytesPerRow: 40,
              maximumRequestUnits: 100,
              width: 0,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 10,
              pixelHeight: 10,
              bytesPerRow: 40,
              maximumRequestUnits: 100,
              left: 8,
              width: 3,
            ),
        () => X11PutImagePlan.create(
              pixelWidth: 10,
              pixelHeight: 10,
              bytesPerRow: 40,
              maximumRequestUnits: 100,
              top: 9,
              height: 2,
            ),
      ]) {
        expect(create, throwsArgumentError);
      }
    });
  });
}

void _expectSegment(
  X11PutImageSegment segment, {
  required int sourceOffset,
  required int x,
  required int y,
  required int width,
  required int height,
  required int byteLength,
}) {
  expect(segment.sourceOffset, sourceOffset);
  expect(segment.x, x);
  expect(segment.y, y);
  expect(segment.width, width);
  expect(segment.height, height);
  expect(segment.byteLength, byteLength);
}
