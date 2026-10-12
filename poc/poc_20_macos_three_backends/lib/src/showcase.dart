import 'dart:typed_data';

import 'pixel_witness.dart';

// ---------------------------------------------------------------------------
// Showcase - the three backends side by side, each one saying who it is.
//
// The conformance suite proves each backend in isolation; nothing there is
// meant for a person to look at. Run all three at once and the windows are
// indistinguishable: SkyLight's has no title bar at all, the signal backend's
// title was empty, and SkyLight and the native host painted the same blue.
//
// So every backend gets one identity here - number, colour, position, title -
// and the label is painted INTO the frame. That is the only place all three
// can show text: a SkyLight window has no frame to put a title on.
// ---------------------------------------------------------------------------

const int showcaseFrameWidth = 480;
const int showcaseFrameHeight = 320;

class ShowcaseSpec {
  const ShowcaseSpec({
    required this.number,
    required this.name,
    required this.title,
    required this.details,
    required this.fill,
    required this.ink,
    this.closeButton = false,
  });

  final int number;
  final String name;

  /// Title-bar text, for the two backends that have a title bar.
  final String title;
  final List<String> details;

  /// The same fill each backend uses in the conformance suite.
  final PixelSample fill;
  final PixelSample ink;

  /// Paint [showcaseCloseBox] into the frame. Only for a window that has no
  /// frame of its own to put a close button on.
  final bool closeButton;

  /// Content top-left in global top-left coordinates: one column per backend,
  /// left to right in backend order, below the menu bar and a title bar.
  int get left => 40 + (number - 1) * 520;
  int get top => 120;
}

const ShowcaseSpec showcaseSkylight = ShowcaseSpec(
  number: 1,
  name: 'SKYLIGHT / CGS',
  title: 'Backend 1 - SkyLight/CGS (Dart puro)',
  details: <String>[
    'DART PURO + API PRIVADA SKYLIGHT',
    'JANELA CRUA DO WINDOWSERVER:',
    'SEM MOLDURA, NAO ARRASTA.',
    'FECHE NO X (OU CTRL+C).',
  ],
  fill: PixelSample(20, 120, 220),
  ink: PixelSample(255, 255, 255),
  closeButton: true,
);

/// The painted close button, in frame (= window content) coordinates.
const ({int left, int top, int size}) showcaseCloseBox =
    (left: 436, top: 12, size: 32);

/// Whether a point in window content coordinates falls on [showcaseCloseBox].
bool showcaseCloseBoxHit(double x, double y) =>
    x >= showcaseCloseBox.left &&
    x < showcaseCloseBox.left + showcaseCloseBox.size &&
    y >= showcaseCloseBox.top &&
    y < showcaseCloseBox.top + showcaseCloseBox.size;

const ShowcaseSpec showcaseAppKitSignal = ShowcaseSpec(
  number: 2,
  name: 'APPKIT SIGNAL HIJACK',
  title: 'Backend 2 - AppKit via signal hijack (Dart puro)',
  details: <String>[
    'DART PURO, THREAD 0 TOMADA',
    'POR SIGUSR2. EXPERIMENTAL:',
    'NUNCA E O PADRAO.',
    'O BOTAO VERMELHO FECHA.',
  ],
  fill: PixelSample(120, 220, 20),
  ink: PixelSample(16, 40, 0),
);

const ShowcaseSpec showcaseAppKitNativeHost = ShowcaseSpec(
  number: 3,
  name: 'APPKIT NATIVE HOST',
  title: 'Backend 3 - AppKit host nativo (Objective-C)',
  details: <String>[
    'EXECUTAVEL .M DONO DA THREAD 0.',
    'ESTE FRAME VEIO DO DART',
    'PELO PROTOCOLO STDIN.',
    'CAMINHO RECOMENDADO.',
  ],
  fill: PixelSample(220, 120, 20),
  ink: PixelSample(255, 255, 255),
);

/// A BGRA (premultiplied, opaque) frame: the backend's fill, its number and
/// name, the [ShowcaseSpec.details] lines, and a [footer] strip for whatever
/// only exists at run time - pid and window id.
Uint8List showcaseBgraFrame(ShowcaseSpec spec, {String footer = ''}) {
  final canvas = _Canvas(showcaseFrameWidth, showcaseFrameHeight)
    ..fill(0, 0, showcaseFrameWidth, showcaseFrameHeight, spec.fill);

  canvas.text('${spec.number}', 28, 24, scale: 12, colour: spec.ink);
  canvas.text('BACKEND', 112, 34, scale: 3, colour: spec.ink);
  canvas.text(spec.name, 112, 74, scale: 3, colour: spec.ink);

  var y = 132;
  for (final line in spec.details) {
    canvas.text(line, 28, y, scale: 2, colour: spec.ink);
    y += 26;
  }

  if (spec.closeButton) {
    const box = showcaseCloseBox;
    canvas
      ..fill(
          box.left, box.top, box.size, box.size, const PixelSample(230, 60, 50))
      // The 15x21 glyph centred in the box.
      ..text(
          'X', box.left + (box.size - 15) ~/ 2, box.top + (box.size - 21) ~/ 2,
          scale: 3, colour: const PixelSample(255, 255, 255));
  }

  if (footer.isNotEmpty) {
    final band = PixelSample(
        spec.fill.red ~/ 2, spec.fill.green ~/ 2, spec.fill.blue ~/ 2);
    canvas
      ..fill(0, 276, showcaseFrameWidth, 44, band)
      ..text(footer, 28, 291,
          scale: 2, colour: const PixelSample(255, 255, 255));
  }
  return canvas.bytes;
}

class _Canvas {
  _Canvas(this.width, this.height) : bytes = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Uint8List bytes;

  void fill(int x, int y, int w, int h, PixelSample colour) {
    final right = (x + w).clamp(0, width);
    final bottom = (y + h).clamp(0, height);
    for (var row = y.clamp(0, height); row < bottom; row++) {
      for (var column = x.clamp(0, width); column < right; column++) {
        final i = (row * width + column) * 4;
        bytes[i] = colour.blue;
        bytes[i + 1] = colour.green;
        bytes[i + 2] = colour.red;
        bytes[i + 3] = 255;
      }
    }
  }

  /// One glyph cell is 5x7 pixels plus one column of spacing, times [scale].
  void text(String value, int x, int y,
      {required int scale, required PixelSample colour}) {
    var penX = x;
    for (final rune in value.toUpperCase().runes) {
      final glyph = _font[String.fromCharCode(rune)] ?? _font[' ']!;
      for (var row = 0; row < 7; row++) {
        for (var column = 0; column < 5; column++) {
          if (glyph[row] & (0x10 >> column) != 0) {
            fill(penX + column * scale, y + row * scale, scale, scale, colour);
          }
        }
      }
      penX += 6 * scale;
    }
  }
}

/// 5x7 bitmap font, one int per row, bit 4 = leftmost column. Only what the
/// labels use: A-Z, 0-9 and a little punctuation. Labels are written without
/// accents for the same reason.
const Map<String, List<int>> _font = <String, List<int>>{
  ' ': [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  'A': [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
  'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
  'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
  'D': [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
  'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
  'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
  'G': [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
  'H': [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
  'I': [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
  'J': [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
  'K': [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
  'L': [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
  'M': [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
  'N': [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
  'O': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
  'P': [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
  'Q': [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
  'R': [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
  'S': [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
  'T': [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
  'U': [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
  'V': [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
  'W': [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
  'X': [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
  'Y': [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
  'Z': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
  '0': [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
  '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
  '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
  '3': [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
  '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
  '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
  '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
  '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
  '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
  '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
  '-': [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
  '/': [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
  '.': [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
  ',': [0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08],
  ':': [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
  '+': [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
  '(': [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02],
  ')': [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08],
};
