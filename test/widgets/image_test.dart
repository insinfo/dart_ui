/// The image widget: the fit rule as arithmetic, and then as pixels.
///
/// The fixtures are two by four pixels of four flat colours, which is what
/// makes every assertion below an equality rather than a tolerance. A larger
/// picture would prove the same things less clearly.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/image/decoded_image.dart';
import 'package:dart_ui/src/graphics/image/image_errors.dart';
import 'package:dart_ui/src/layout/alignment.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/image.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

import '../graphics/image/png_fixtures.dart';

const int red = 0xFFFF0000;
const int green = 0xFF00FF00;
const int blue = 0xFF0000FF;
const int white = 0xFFFFFFFF;

/// Four by two, in four flat quadrants:
///
///     red   red   blue  blue
///     green green white white
///
/// Wider than it is tall, on purpose: an aspect ratio of exactly 2 makes every
/// fit rule's arithmetic a whole number.
DecodedImage quadrants({ImageChannelOrder order = ImageChannelOrder.bgra}) {
  const List<List<int>> rows = <List<int>>[
    <int>[red, red, blue, blue],
    <int>[green, green, white, white],
  ];
  final Uint8List pixels = Uint8List(4 * 2 * 4);
  int at = 0;
  for (final List<int> row in rows) {
    for (final int argb in row) {
      pixels[at + order.redIndex] = argb >> 16 & 0xFF;
      pixels[at + 1] = argb >> 8 & 0xFF;
      pixels[at + order.blueIndex] = argb & 0xFF;
      pixels[at + 3] = 255;
      at += 4;
    }
  }
  return DecodedImage(
    width: 4,
    height: 2,
    order: order,
    pixels: pixels,
    hasAlpha: false,
  );
}

/// The same four colours as a real PNG, for the end-to-end path.
Uint8List quadrantsPng() => buildPng(
      width: 4,
      height: 2,
      colorType: 2,
      filteredRows: unfilteredRows(<List<int>>[
        <int>[255, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 255],
        <int>[0, 255, 0, 0, 255, 0, 255, 255, 255, 255, 255, 255],
      ]),
    );

(BuildOwner, PipelineOwner) _mounted(
  Widget root,
  Size viewport, {
  bool tight = true,
}) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints:
        tight ? BoxConstraints.tight(viewport) : BoxConstraints.loose(viewport),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(root);
  pipeline.flushLayout();
  return (owner, pipeline);
}

Framebuffer _render(
  Widget root,
  Size viewport, {
  PixelFormat format = PixelFormat.bgra8888Premultiplied,
}) {
  final (BuildOwner owner, PipelineOwner pipeline) = _mounted(root, viewport);
  addTearDown(owner.dispose);
  final DisplayList list = DisplayList();
  pipeline.flushPaint(list);
  final Framebuffer surface = Framebuffer.allocate(
    width: viewport.width.round(),
    height: viewport.height.round(),
    format: format,
  )..clear(0, 0, 0, 255);
  rasterizeDisplayList(list, surface);
  return surface;
}

/// The `0xAARRGGBB` of a surface pixel, read through the surface's own format
/// so that a test cannot accidentally assert byte order instead of colour.
int _argbAt(Framebuffer surface, int x, int y) {
  final int offset = surface.offsetOf(x, y);
  final bool bgra = surface.format == PixelFormat.bgra8888Premultiplied;
  return surface.pixels[offset + 3] << 24 |
      surface.pixels[offset + (bgra ? 2 : 0)] << 16 |
      surface.pixels[offset + 1] << 8 |
      surface.pixels[offset + (bgra ? 0 : 2)];
}

void main() {
  group('applyBoxFit', () {
    const Size wide = Size(40, 20); // 2:1
    const Size tall = Size(20, 40); // 1:2
    const Size square = Size(40, 40);

    test('fill takes both sizes as they are', () {
      final FittedSizes fitted = applyBoxFit(BoxFit.fill, wide, square);
      expect(fitted.source, wide);
      expect(fitted.destination, square);
    });

    test('contain keeps the ratio and leaves the box partly empty', () {
      expect(
        applyBoxFit(BoxFit.contain, wide, square).destination,
        const Size(40, 20),
      );
      expect(
        applyBoxFit(BoxFit.contain, tall, square).destination,
        const Size(20, 40),
      );
      // Nothing is cropped: contain reads the whole image.
      expect(applyBoxFit(BoxFit.contain, wide, square).source, wide);
    });

    test('cover keeps the ratio and crops the image instead', () {
      final FittedSizes fitted = applyBoxFit(BoxFit.cover, wide, square);
      expect(fitted.destination, square);
      expect(fitted.source, const Size(20, 20), reason: 'a square crop');

      final FittedSizes upright = applyBoxFit(BoxFit.cover, tall, square);
      expect(upright.destination, square);
      expect(upright.source, const Size(20, 20));
    });

    test('fitWidth fills the width, whichever way the ratio goes', () {
      // Image wider than the box: the height follows and nothing is cropped.
      final FittedSizes wideCase = applyBoxFit(BoxFit.fitWidth, wide, square);
      expect(wideCase.destination.width, 40);
      expect(wideCase.destination, const Size(40, 20));
      expect(wideCase.source, wide);

      // Image taller than the box: filling the width would overflow the
      // height, so the source is cropped rather than the result spilling.
      final FittedSizes tallCase = applyBoxFit(BoxFit.fitWidth, tall, square);
      expect(tallCase.destination, square);
      expect(tallCase.source, const Size(20, 20));
    });

    test('fitHeight fills the height, whichever way the ratio goes', () {
      final FittedSizes tallCase = applyBoxFit(BoxFit.fitHeight, tall, square);
      expect(tallCase.destination.height, 40);
      expect(tallCase.destination, const Size(20, 40));
      expect(tallCase.source, tall);

      final FittedSizes wideCase = applyBoxFit(BoxFit.fitHeight, wide, square);
      expect(wideCase.destination, square);
      expect(wideCase.source, const Size(20, 20));
    });

    test('none draws at the image\'s own size, cropped to the box', () {
      expect(
        applyBoxFit(BoxFit.none, wide, square).destination,
        const Size(40, 20),
      );
      // A box smaller than the image crops on both axes and scales on neither.
      final FittedSizes cropped =
          applyBoxFit(BoxFit.none, const Size(100, 100), const Size(30, 10));
      expect(cropped.source, const Size(30, 10));
      expect(cropped.destination, const Size(30, 10));
    });

    test('an empty box or an empty image yields nothing to draw', () {
      expect(
        applyBoxFit(BoxFit.contain, wide, Size.zero).destination,
        Size.zero,
      );
      expect(
        applyBoxFit(BoxFit.cover, Size.zero, square).source,
        Size.zero,
      );
    });

    test('the ratio boundary is decided once, so the modes agree there', () {
      // A box with exactly the image's ratio: every rule that keeps the ratio
      // has to produce the same answer, and a comparison done twice with
      // different roundings is how they stop doing so.
      const Size box = Size(80, 40);
      for (final BoxFit fit in <BoxFit>[
        BoxFit.contain,
        BoxFit.cover,
        BoxFit.fitWidth,
        BoxFit.fitHeight,
        BoxFit.fill,
      ]) {
        expect(applyBoxFit(fit, wide, box).destination, box, reason: '$fit');
      }
    });
  });

  group('RenderImage layout', () {
    test('an image asks for its own size', () {
      final (BuildOwner owner, _) = _mounted(
        Image(quadrants()),
        const Size(100, 100),
        tight: false,
      );
      addTearDown(owner.dispose);
      expect((owner.renderRoot! as RenderImage).size, const Size(4, 2));
    });

    test('width and height override the natural size', () {
      final (BuildOwner owner, _) = _mounted(
        Image(quadrants(), width: 40, height: 10),
        const Size(100, 100),
        tight: false,
      );
      addTearDown(owner.dispose);
      expect((owner.renderRoot! as RenderImage).size, const Size(40, 10));
    });

    test('a tight parent wins over both', () {
      final (BuildOwner owner, _) = _mounted(
        Image(quadrants(), width: 40, height: 10),
        const Size(25, 25),
      );
      addTearDown(owner.dispose);
      expect((owner.renderRoot! as RenderImage).size, const Size(25, 25));
    });

    test('intrinsics are the natural size', () {
      final RenderImage render = RenderImage(quadrants(), width: 60);
      expect(render.getMaxIntrinsicWidth(double.infinity), 60);
      expect(render.getMaxIntrinsicHeight(double.infinity), 2);
    });

    test('an image is opaque to hit testing', () {
      final (BuildOwner owner, _) =
          _mounted(Image(quadrants()), const Size(40, 40));
      addTearDown(owner.dispose);
      expect(
        (owner.renderRoot! as RenderImage).hitTestSelf(const Rect.fromLTRB(
          0,
          0,
          1,
          1,
        ).topLeft),
        isTrue,
      );
    });
  });

  group('the rectangles a fit produces', () {
    RenderImage laidOut(BoxFit fit, Size box, {Alignment? alignment}) {
      final RenderImage render = RenderImage(
        quadrants(),
        fit: fit,
        alignment: alignment ?? Alignment.center,
      );
      render.layout(BoxConstraints.tight(box));
      return render;
    }

    test('contain centres the fitted rectangle in the box', () {
      final RenderImage render = laidOut(BoxFit.contain, const Size(40, 40));
      expect(render.destinationRect, const Rect.fromLTRB(0, 10, 40, 30));
      expect(render.sourceRect, const Rect.fromLTRB(0, 0, 4, 2));
    });

    test('alignment moves the fitted rectangle, not its size', () {
      final RenderImage top = laidOut(
        BoxFit.contain,
        const Size(40, 40),
        alignment: Alignment.topLeft,
      );
      expect(top.destinationRect, const Rect.fromLTRB(0, 0, 40, 20));

      final RenderImage bottom = laidOut(
        BoxFit.contain,
        const Size(40, 40),
        alignment: Alignment.bottomRight,
      );
      expect(bottom.destinationRect, const Rect.fromLTRB(0, 20, 40, 40));
    });

    test('cover crops the source, and alignment chooses which part', () {
      final RenderImage centred = laidOut(BoxFit.cover, const Size(40, 40));
      expect(centred.destinationRect, const Rect.fromLTRB(0, 0, 40, 40));
      expect(centred.sourceRect, const Rect.fromLTRB(1, 0, 3, 2));

      final RenderImage left = laidOut(
        BoxFit.cover,
        const Size(40, 40),
        alignment: Alignment.centerLeft,
      );
      expect(left.sourceRect, const Rect.fromLTRB(0, 0, 2, 2));
    });

    test('none neither scales nor moves the image\'s own pixels', () {
      final RenderImage render = laidOut(BoxFit.none, const Size(40, 40));
      expect(render.destinationRect, const Rect.fromLTRB(18, 19, 22, 21));
      expect(render.sourceRect, const Rect.fromLTRB(0, 0, 4, 2));
    });
  });

  group('pixels', () {
    test('fill stretches each source pixel by a whole factor', () {
      final Framebuffer surface =
          _render(Image(quadrants(), fit: BoxFit.fill), const Size(8, 4));

      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 3, 1), red);
      expect(_argbAt(surface, 4, 0), blue);
      expect(_argbAt(surface, 7, 1), blue);
      expect(_argbAt(surface, 0, 2), green);
      expect(_argbAt(surface, 7, 3), white);
    });

    test('contain leaves the rest of the box untouched', () {
      // 4:2 into 8:8 gives an 8x4 rectangle centred vertically: rows 2..6.
      final Framebuffer surface = _render(Image(quadrants()), const Size(8, 8));

      expect(_argbAt(surface, 0, 0), 0xFF000000, reason: 'above the image');
      expect(_argbAt(surface, 0, 2), red);
      expect(_argbAt(surface, 7, 2), blue);
      expect(_argbAt(surface, 0, 5), green);
      expect(_argbAt(surface, 7, 5), white);
      expect(_argbAt(surface, 0, 7), 0xFF000000, reason: 'below the image');
    });

    test('cover fills the box and drops the cropped columns', () {
      // The centre 2x2 of the image scaled to 8x8: red and blue only, since
      // the crop keeps one column of each pair.
      final Framebuffer surface = _render(
        Image(quadrants(), fit: BoxFit.cover),
        const Size(8, 8),
      );

      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(
            _argbAt(surface, x, y),
            isNot(0xFF000000),
            reason: 'cover leaves no gap at ($x, $y)',
          );
        }
      }
      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 7, 0), blue);
      expect(_argbAt(surface, 0, 7), green);
      expect(_argbAt(surface, 7, 7), white);
    });

    test('none draws at the image\'s own size, wherever it is aligned', () {
      final Framebuffer surface = _render(
        Image(
          quadrants(),
          fit: BoxFit.none,
          alignment: Alignment.topLeft,
        ),
        const Size(8, 8),
      );
      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 3, 1), white);
      expect(_argbAt(surface, 4, 0), 0xFF000000, reason: 'not scaled');
    });

    test('an image larger than its box is cropped, not squashed', () {
      final DecodedImage big = quadrants().resample(width: 40, height: 20);
      final Framebuffer surface = _render(
        Image(big, fit: BoxFit.none, alignment: Alignment.topLeft),
        const Size(8, 8),
      );
      // The top-left 8x8 of a 40x20 image is entirely inside the red quadrant.
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(_argbAt(surface, x, y), red, reason: '($x, $y)');
        }
      }
    });
  });

  group('channel order, all the way through', () {
    test('a bgra image draws the right colour into a bgra surface', () {
      final Framebuffer surface = _render(
        Image(quadrants(order: ImageChannelOrder.bgra), fit: BoxFit.fill),
        const Size(4, 2),
      );
      expect(surface.pixels.sublist(0, 4), <int>[0, 0, 255, 255]);
      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 2, 0), blue);
    });

    test('an rgba image draws the right colour into a bgra surface', () {
      // The swizzle the rasteriser does on the way in. Getting this wrong
      // swaps red and blue, which is invisible in any grey test image - which
      // is exactly how it went unnoticed in `Framebuffer.clear`.
      final Framebuffer surface = _render(
        Image(quadrants(order: ImageChannelOrder.rgba), fit: BoxFit.fill),
        const Size(4, 2),
      );
      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 2, 0), blue);
      expect(_argbAt(surface, 0, 1), green);
    });

    test('and into an rgba surface, both ways round', () {
      for (final ImageChannelOrder order in ImageChannelOrder.values) {
        final Framebuffer surface = _render(
          Image(quadrants(order: order), fit: BoxFit.fill),
          const Size(4, 2),
          format: PixelFormat.rgba8888Premultiplied,
        );
        expect(surface.pixels.sublist(0, 4), <int>[255, 0, 0, 255],
            reason: '${order.name} into rgba');
        expect(_argbAt(surface, 2, 0), blue, reason: order.name);
      }
    });

    test('framebufferFromImage maps each order to its own pixel format', () {
      expect(
        framebufferFromImage(quadrants(order: ImageChannelOrder.bgra)).format,
        PixelFormat.bgra8888Premultiplied,
      );
      expect(
        framebufferFromImage(quadrants(order: ImageChannelOrder.rgba)).format,
        PixelFormat.rgba8888Premultiplied,
      );
      // No copy: the framebuffer views the image's own bytes.
      final DecodedImage image = quadrants();
      expect(
        identical(framebufferFromImage(image).pixels, image.pixels),
        isTrue,
      );
      expect(framebufferFromImage(image).bytesPerRow, 16);
    });
  });

  group('transparency', () {
    test('a half-transparent image composites over what is behind it', () {
      final DecodedImage half = DecodedImage.filled(
        width: 2,
        height: 2,
        argb: 0x80FFFFFF,
      );
      final Framebuffer surface =
          _render(Image(half, fit: BoxFit.fill), const Size(4, 4));
      // Premultiplied white at alpha 128 over black: 128 + mul255(0, 127).
      expect(surface.pixels[0], 128);
      expect(surface.pixels[3], 255, reason: 'the surface stays opaque');
    });
  });

  group('the resample cache', () {
    test('a repeated paint at the same size resamples once', () {
      final RenderImage render = RenderImage(quadrants(), fit: BoxFit.fill)
        ..layout(BoxConstraints.tight(const Size(40, 20)));
      for (int i = 0; i < 5; i++) {
        render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      }
      expect(render.resampleCount, 1);
    });

    test('drawing at the image\'s own size does not resample at all', () {
      final RenderImage render = RenderImage(quadrants(), fit: BoxFit.fill)
        ..layout(BoxConstraints.tight(const Size(4, 2)));
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      expect(render.resampleCount, 0);
    });

    test('a resize resamples once more, not once a frame', () {
      final RenderImage render = RenderImage(quadrants(), fit: BoxFit.fill)
        ..layout(BoxConstraints.tight(const Size(40, 20)));
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      render.layout(BoxConstraints.tight(const Size(80, 40)));
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      expect(render.resampleCount, 2);
    });

    test('changing the fit drops the cache', () {
      final RenderImage render = RenderImage(quadrants(), fit: BoxFit.fill)
        ..layout(BoxConstraints.tight(const Size(40, 40)));
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      render.fit = BoxFit.cover;
      render.paint(DisplayList(), const Rect.fromLTRB(0, 0, 0, 0).topLeft);
      expect(render.resampleCount, 2);
    });
  });

  group('Image.png, end to end', () {
    test('decodes and draws bytes that were never a file', () {
      final Framebuffer surface = _render(
        Image.png(quadrantsPng(), fit: BoxFit.fill),
        const Size(8, 4),
      );
      expect(_argbAt(surface, 0, 0), red);
      expect(_argbAt(surface, 7, 0), blue);
      expect(_argbAt(surface, 0, 3), green);
      expect(_argbAt(surface, 7, 3), white);
    });

    test('the decoder\'s refusal reaches the caller rather than a blank box',
        () {
      expect(
        () => Image.png(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<PngSignatureException>()),
      );
    });

    test('the requested channel order reaches the decoder', () {
      final Image image = Image.png(
        quadrantsPng(),
        order: ImageChannelOrder.rgba,
      );
      expect(image.image.order, ImageChannelOrder.rgba);
      expect(image.image.argbAt(0, 0), red);
    });
  });

  group('the widget updates its render node', () {
    test('a new image re-lays the box out', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(Image(quadrants()));
      addTearDown(owner.dispose);
      pipeline.flushLayout();
      expect((owner.renderRoot! as RenderImage).size, const Size(4, 2));

      owner.updateRoot(Image(quadrants().resample(width: 20, height: 30)));
      pipeline.flushLayout();
      expect((owner.renderRoot! as RenderImage).size, const Size(20, 30));
    });

    test('a new fit and alignment reach the node', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(40, 40)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(Image(quadrants()));
      addTearDown(owner.dispose);
      pipeline.flushLayout();

      owner.updateRoot(
        Image(quadrants(), fit: BoxFit.cover, alignment: Alignment.topLeft),
      );
      pipeline.flushLayout();
      final RenderImage render = owner.renderRoot! as RenderImage;
      expect(render.fit, BoxFit.cover);
      expect(render.alignment, Alignment.topLeft);
      expect(render.sourceRect, const Rect.fromLTRB(0, 0, 2, 2));
    });
  });
}
