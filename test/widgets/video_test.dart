library;

import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/video/video_frame.dart';
import 'package:dart_ui/src/layout/alignment.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/image.dart' show BoxFit;
import 'package:dart_ui/src/widgets/video.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

const int _red = 0xFFFF0000;
const int _green = 0xFF00FF00;
const int _blue = 0xFF0000FF;
const int _white = 0xFFFFFFFF;

VideoFrame _frame({
  int width = 4,
  int height = 2,
  int sequence = 0,
}) {
  final VideoFrame frame = VideoFrame.allocate(
    VideoFrameFormat(
      pixelFormat: VideoPixelFormat.rgba8888,
      width: width,
      height: height,
      range: VideoColorRange.full,
    ),
    streamId: 17,
    sequence: sequence,
  );
  final VideoPlane plane = frame.plane(0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final int color = y < height / 2
          ? (x < width / 2 ? _red : _blue)
          : (x < width / 2 ? _green : _white);
      final int offset = y * plane.bytesPerRow + x * 4;
      plane.bytes[offset] = color >> 16 & 0xFF;
      plane.bytes[offset + 1] = color >> 8 & 0xFF;
      plane.bytes[offset + 2] = color & 0xFF;
      plane.bytes[offset + 3] = 0xFF;
    }
  }
  return frame;
}

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

Framebuffer _render(VideoFrameView view, Size viewport) {
  final (BuildOwner owner, PipelineOwner pipeline) = _mounted(view, viewport);
  addTearDown(owner.dispose);
  final DisplayList list = DisplayList();
  pipeline.flushPaint(list);
  final Framebuffer surface = Framebuffer.allocate(
    width: viewport.width.round(),
    height: viewport.height.round(),
  )..clear(0, 0, 0, 255);
  rasterizeDisplayList(list, surface);
  return surface;
}

int _argbAt(Framebuffer surface, int x, int y) {
  final int offset = surface.offsetOf(x, y);
  final bool bgra = surface.format == PixelFormat.bgra8888Premultiplied;
  return surface.pixels[offset + 3] << 24 |
      surface.pixels[offset + (bgra ? 2 : 0)] << 16 |
      surface.pixels[offset + 1] << 8 |
      surface.pixels[offset + (bgra ? 0 : 2)];
}

void main() {
  group('VideoFrameView layout', () {
    test('uses the frame size and exposes matching intrinsics', () {
      final (BuildOwner owner, _) = _mounted(
        VideoFrameView(_frame()),
        const Size(100, 100),
        tight: false,
      );
      addTearDown(owner.dispose);
      final RenderVideoFrame render = owner.renderRoot! as RenderVideoFrame;
      expect(render.size, const Size(4, 2));
      expect(render.getMaxIntrinsicWidth(double.infinity), 4);
      expect(render.getMaxIntrinsicHeight(double.infinity), 2);
    });

    test('explicit dimensions participate in layout and intrinsics', () {
      final RenderVideoFrame render = RenderVideoFrame(
        _frame(),
        width: 60,
        height: 30,
      );
      render.layout(BoxConstraints.loose(const Size(100, 100)));
      expect(render.size, const Size(60, 30));
      expect(render.getMinIntrinsicWidth(double.infinity), 60);
      expect(render.getMinIntrinsicHeight(double.infinity), 30);
    });

    test('frame changes invalidate paint or layout according to dimensions',
        () {
      final (BuildOwner owner, PipelineOwner pipeline) = _mounted(
        VideoFrameView(_frame()),
        const Size(20, 20),
      );
      addTearDown(owner.dispose);
      final RenderVideoFrame render = owner.renderRoot! as RenderVideoFrame;
      pipeline.flushPaint(DisplayList());

      owner.updateRoot(VideoFrameView(_frame(sequence: 1)));
      expect(render.needsLayout, isFalse);
      expect(render.needsPaint, isTrue);
      pipeline.flushPaint(DisplayList());

      owner.updateRoot(VideoFrameView(_frame(width: 6, sequence: 2)));
      expect(render.needsLayout, isTrue);
    });
  });

  group('fit and pixels', () {
    test('contain centres and scales the frame without filling the bars', () {
      final Framebuffer surface = _render(
        VideoFrameView(_frame()),
        const Size(8, 8),
      );
      expect(_argbAt(surface, 0, 0), 0xFF000000);
      expect(_argbAt(surface, 0, 2), _red);
      expect(_argbAt(surface, 7, 2), _blue);
      expect(_argbAt(surface, 0, 5), _green);
      expect(_argbAt(surface, 7, 5), _white);
      expect(_argbAt(surface, 0, 7), 0xFF000000);
    });

    test('cover crops the source and alignment chooses the retained side', () {
      final RenderVideoFrame centered = RenderVideoFrame(
        _frame(),
        fit: BoxFit.cover,
      )..layout(BoxConstraints.tight(const Size(8, 8)));
      expect(centered.sourceRect, const Rect.fromLTRB(1, 0, 3, 2));
      expect(centered.destinationRect, const Rect.fromLTRB(0, 0, 8, 8));

      final RenderVideoFrame left = RenderVideoFrame(
        _frame(),
        fit: BoxFit.cover,
        alignment: Alignment.centerLeft,
      )..layout(BoxConstraints.tight(const Size(8, 8)));
      expect(left.sourceRect, const Rect.fromLTRB(0, 0, 2, 2));
    });

    test('none preserves the frame size inside a larger box', () {
      final Framebuffer surface = _render(
        VideoFrameView(_frame(), fit: BoxFit.none),
        const Size(8, 8),
      );
      expect(_argbAt(surface, 2, 3), _red);
      expect(_argbAt(surface, 5, 4), _white);
      expect(_argbAt(surface, 1, 3), 0xFF000000);
      expect(_argbAt(surface, 6, 4), 0xFF000000);
    });
  });
}
