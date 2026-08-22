/// The gallery, mounted through `runApp` instead of by hand.
///
/// `test/gallery/gallery_test.dart` drives the gallery with a hand-built
/// `BuildOwner`, which is what the Win32 example used to do too. This file
/// asserts that the *shell* gets the same result: same controls, same semantic
/// tree, same pixels, on a real window from a real backend with the real frame
/// loop. If those two ever diverge, the shell has grown a behaviour of its own
/// and "the gallery runs unchanged on every backend" has quietly stopped being
/// true.
///
/// The font is a fixture rather than the machine's UI font, for the same
/// reason the older suite uses one: a golden that depended on Segoe UI would
/// mean nothing on the Linux container this has to pass in.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
      reason: 'the gallery goldens are taken against a fixture font',
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  Future<Application> start({double renderScale = 1}) => Application.start(
        rootWidget: Gallery(model: GalleryModel()),
        backends: <WindowingBackendEntry>[
          WindowingBackendEntry(
            name: 'headless',
            create: () => HeadlessWindowingBackend(renderScale: renderScale),
          ),
        ],
        options: const ApplicationOptions(
          title: 'gallery',
          size: galleryDesignSize,
        clearColor: Color(0xFF000000),
        ),
      );

  test('the shell mounts the same gallery the hand-built owner does', () async {
    final application = await start();
    final result = await application.drawFrame();

    expect(result.isSuccess, isTrue, reason: result.diagnostic?.toString());
    // The numbers `example/gallery_win32.dart` prints, asserted here so a
    // regression shows up in the suite rather than in a smoke run's stdout.
    expect(application.controlCount, 20);
    expect(application.semanticNodeCount, 21);
    expect(application.errors, isEmpty);

    final framebuffer = _framebufferOf(application);
    expect(framebuffer.width, galleryDesignSize.width.toInt());
    expect(framebuffer.height, galleryDesignSize.height.toInt());

    // Not a blank frame: a gallery that painted only its background would
    // pass a weaker check. Sampled on a coarse grid, as the older suite does.
    final colours = <int>{};
    for (var y = 0; y < framebuffer.height; y += 7) {
      for (var x = 0; x < framebuffer.width; x += 7) {
        colours.add(_pixelAt(framebuffer, x, y));
      }
    }
    expect(colours.length, greaterThan(3));

    application.dispose();
    await application.closed;
  });

  test('the same gallery is byte-identical through two applications', () async {
    final first = await start();
    await first.drawFrame();
    final a = HeadlessScreenshot.fromFramebuffer(_framebufferOf(first));

    final second = await start();
    await second.drawFrame();
    final b = HeadlessScreenshot.fromFramebuffer(_framebufferOf(second));

    final comparison = compareGolden(a, b);
    expect(comparison.match, isTrue);
    expect(comparison.differingPixels, 0);
    expect(a.checksum, b.checksum);

    first.dispose();
    second.dispose();
    await first.closed;
    await second.closed;
  });

  test('a frame settles despite the virtualized list rebuilding once',
      () async {
    // The list realizes items against an estimated viewport, then rebuilds
    // with the measured one. `drawFrame` must present the *second* result;
    // presenting the first would put the wrong layout on screen for a frame.
    final application = await start();
    await application.drawFrame();

    expect(application.buildOwner.hasScheduledBuilds, isFalse);
    expect(application.pipelineOwner.needsLayout, isFalse);
    expect(application.needsFrame, isFalse);
    expect(application.framesPresented, 1);

    application.dispose();
    await application.closed;
  });

  test('a click on the default button reaches it and rebuilds the label',
      () async {
    final model = GalleryModel();
    final application = await Application.start(
      rootWidget: Gallery(model: model),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'headless',
          create: HeadlessWindowingBackend.new,
        ),
      ],
      options: const ApplicationOptions(
        title: 'gallery',
        size: galleryDesignSize,
      ),
    );
    await application.drawFrame();

    final button = _find<RenderButton>(application.buildOwner.renderRoot!);
    final centre = button.localToGlobal(
      Offset(button.size.width / 2, button.size.height / 2),
    );
    final window = application.window as HeadlessWindow;
    for (final event in <PointerEvent>[
      PointerDownEvent(
        windowId: window.id,
        generation: window.generation,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: centre,
        button: PointerButton.primary,
      ),
      PointerUpEvent(
        windowId: window.id,
        generation: window.generation,
        timestamp: Duration.zero,
        pointerId: 0,
        kind: PointerKind.mouse,
        logicalPosition: centre,
        button: PointerButton.primary,
      ),
    ]) {
      expect(window.dispatchInput(event), isTrue);
    }
    application.backend.pumpEvents();

    expect(model.pressCount, 1);
    expect(application.needsFrame, isTrue,
        reason: 'a setState from a callback dirties the next frame, and does '
            'not paint inline');

    await application.drawFrame();
    expect(application.framesPresented, 2);

    application.dispose();
    await application.closed;
  });
}

Framebuffer _framebufferOf(Application application) =>
    ((application.host.presenter as RenderTargetPresenter).target
            as MemoryRenderTarget)
        .framebuffer;

int _pixelAt(Framebuffer framebuffer, int x, int y) {
  final index = framebuffer.offsetOf(x, y);
  return (framebuffer.pixels[index + 3] << 24) |
      (framebuffer.pixels[index + 2] << 16) |
      (framebuffer.pixels[index + 1] << 8) |
      framebuffer.pixels[index];
}

T _find<T extends RenderBox>(RenderBox root) {
  T? found;
  void walk(RenderBox node) {
    if (found != null) return;
    if (node is T) {
      found = node;
      return;
    }
    node.visitChildren(walk);
  }

  walk(root);
  if (found == null) throw StateError('no $T in the render tree');
  return found!;
}
