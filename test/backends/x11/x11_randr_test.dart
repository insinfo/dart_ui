/// RandR 1.5 monitors: the reply decoder and the screens built from it.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/x11/x11_backend.dart';
import 'package:dart_ui/src/backends/x11/x11_randr.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:test/test.dart';

/// An `RRGetMonitors` reply: header, then each monitor and its outputs.
Uint8List _reply(List<(int, bool, int, int, int, int, int)> monitors,
    {int outputsEach = 1, bool truncate = false}) {
  final BytesBuilder bytes = BytesBuilder();
  final ByteData header = ByteData(32)
    ..setUint8(0, 1)
    ..setUint32(12, monitors.length, Endian.host);
  bytes.add(header.buffer.asUint8List());
  for (final (int atom, bool primary, int x, int y, int w, int h, int mm)
      in monitors) {
    final ByteData info = ByteData(24 + outputsEach * 4)
      ..setUint32(0, atom, Endian.host)
      ..setUint8(4, primary ? 1 : 0)
      ..setUint8(5, 1)
      ..setUint16(6, outputsEach, Endian.host)
      ..setInt16(8, x, Endian.host)
      ..setInt16(10, y, Endian.host)
      ..setUint16(12, w, Endian.host)
      ..setUint16(14, h, Endian.host)
      ..setUint32(16, mm, Endian.host)
      ..setUint32(20, mm ~/ 2, Endian.host);
    bytes.add(info.buffer.asUint8List());
  }
  final Uint8List all = bytes.toBytes();
  return truncate ? Uint8List.sublistView(all, 0, all.length - 10) : all;
}

void main() {
  group('decodeRandrMonitors', () {
    test('reads each monitor and skips its output ids', () {
      final List<X11Monitor> monitors = decodeRandrMonitors(_reply(
        <(int, bool, int, int, int, int, int)>[
          (300, false, 0, 0, 1920, 1080, 520),
          (301, true, 1920, -200, 2560, 1440, 600),
        ],
        outputsEach: 3,
      ));
      expect(monitors, hasLength(2));
      expect(monitors[0].width, 1920);
      expect(monitors[0].primary, isFalse);
      expect(monitors[1].nameAtom, 301);
      expect(monitors[1].primary, isTrue);
      expect(monitors[1].x, 1920);
      expect(monitors[1].y, -200, reason: 'positions are signed');
      expect(monitors[1].height, 1440);
      expect(monitors[1].widthInMillimetres, 600);
    });

    test('a short reply stops at the last whole monitor', () {
      final List<X11Monitor> monitors = decodeRandrMonitors(_reply(
        <(int, bool, int, int, int, int, int)>[
          (300, false, 0, 0, 1920, 1080, 520),
          (301, true, 1920, 0, 1920, 1080, 520),
        ],
        outputsEach: 0,
        truncate: true,
      ));
      expect(monitors, hasLength(1));
      expect(decodeRandrMonitors(Uint8List(8)), isEmpty);
    });
  });

  group('monitorScreens', () {
    const List<X11Monitor> twoSideBySide = <X11Monitor>[
      X11Monitor(
        nameAtom: 1,
        primary: false,
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        widthInMillimetres: 520,
        heightInMillimetres: 290,
      ),
      X11Monitor(
        nameAtom: 2,
        primary: true,
        x: 1920,
        y: 0,
        width: 1920,
        height: 1080,
        widthInMillimetres: 520,
        heightInMillimetres: 290,
      ),
    ];

    test('one screen per monitor, at the display scale, named by atom', () {
      final screens = X11WindowingBackend.monitorScreens(
        twoSideBySide,
        scale: 2,
        desktopWorkArea: const Rect.fromLTWH(0, 0, 1920, 520),
        nameOf: (int atom) => atom == 1 ? 'DP-1' : 'HDMI-1',
      );
      expect(screens.map((s) => s.name), <String>['DP-1', 'HDMI-1']);
      expect(screens[1].bounds, const Rect.fromLTWH(960, 0, 960, 540));
      expect(screens.map((s) => s.isPrimary), <bool>[false, true]);
      expect(screens.every((s) => s.scale == 2), isTrue);
      // The desktop's work area clipped to each monitor: a 20 px panel at
      // the bottom shortens both.
      expect(screens[0].workArea, const Rect.fromLTWH(0, 0, 960, 520));
      expect(screens[1].workArea, const Rect.fromLTWH(960, 0, 960, 520));
    });

    test(
        'with nothing flagged primary the first monitor is, and unnamed '
        'monitors are numbered', () {
      final screens = X11WindowingBackend.monitorScreens(
        <X11Monitor>[
          for (final m in twoSideBySide)
            X11Monitor(
              nameAtom: m.nameAtom,
              primary: false,
              x: m.x,
              y: m.y,
              width: m.width,
              height: m.height,
              widthInMillimetres: 0,
              heightInMillimetres: 0,
            ),
        ],
        scale: 1,
        desktopWorkArea: const Rect.fromLTWH(-5000, -5000, 1, 1),
      );
      expect(screens.map((s) => s.isPrimary), <bool>[true, false]);
      expect(screens.map((s) => s.name), <String>['monitor 1', 'monitor 2']);
      // A work area that misses the monitor entirely falls back to it.
      expect(screens[0].workArea, screens[0].bounds);
    });
  });
}
