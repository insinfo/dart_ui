import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/svg/svg_picture.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/svg.dart';
import 'package:test/test.dart';

Framebuffer _render(Svg widget, Size viewport) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(viewport),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(widget);
  addTearDown(owner.dispose);
  pipeline.flushLayout();
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
  return surface.pixels[offset + 3] << 24 |
      surface.pixels[offset + 2] << 16 |
      surface.pixels[offset + 1] << 8 |
      surface.pixels[offset];
}

void main() {
  test('draws SVG paths through the ordinary renderer', () {
    final Framebuffer surface = _render(
      Svg.string('''
        <svg width="10" height="10" viewBox="0 0 10 10">
          <rect width="10" height="10" fill="#ff0000"/>
        </svg>
      '''),
      const Size(20, 20),
    );

    expect(_argbAt(surface, 10, 10), 0xFFFF0000);
    expect(_argbAt(surface, 1, 1), 0xFFFF0000);
  });

  test('contain preserves aspect ratio and leaves the remaining area alone',
      () {
    final Framebuffer surface = _render(
      Svg.string('''
        <svg viewBox="0 0 20 10">
          <rect width="20" height="10" fill="lime"/>
        </svg>
      '''),
      const Size(20, 20),
    );

    expect(_argbAt(surface, 10, 10), 0xFF00FF00);
    expect(_argbAt(surface, 10, 1), 0xFF000000);
    expect(_argbAt(surface, 10, 18), 0xFF000000);
  });

  test('natural layout size comes from the SVG viewport', () {
    final SvgPicture picture = SvgPicture.parse(
      '<svg width="40" height="25"><path d="M0 0L1 1"/></svg>',
    );
    final RenderSvg render = RenderSvg(picture)
      ..layout(BoxConstraints.loose(const Size(100, 100)));
    expect(render.size, const Size(40, 25));
  });

  test('even-odd fill rule preserves holes in compound paths', () {
    final Framebuffer surface = _render(
      Svg.string('''
        <svg viewBox="0 0 10 10">
          <path fill="red" fill-rule="evenodd"
            d="M0 0H10V10H0Z M2 2H8V8H2Z"/>
        </svg>
      '''),
      const Size(10, 10),
    );

    expect(_argbAt(surface, 1, 1), 0xFFFF0000);
    expect(_argbAt(surface, 5, 5), 0xFF000000);
  });
}
