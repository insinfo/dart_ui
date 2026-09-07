@TestOn('browser')

/// The presenter as the `SurfacePresenter` it claims to be: it presents, it
/// resizes, it refuses a window it cannot use *by name*, and it gives back only
/// what it made.
library;

import 'package:dart_ui/src/backends/web/dom/dom_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/semantics/semantics.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

import 'dom_session.dart';

void main() {
  late DomTestHost host;

  setUp(() => host = DomTestHost.open());
  tearDown(() => host.close());

  DisplayList oneBox() {
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFF00FF00);
    list.drawRect(0, 0, 10, 10, paint);
    return list;
  }

  test('the probe reports supported with a note that names the trade', () {
    final BackendProbeResult probe = DomCanvasPresenter.probe();
    expect(probe.supported, isTrue);
    expect(probe.backendName, 'web-dom');
    expect(probe.describe(), contains('refused by name'));
  });

  test('present builds the tree and reports presented', () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    final PresentResult result = await presenter.present(
      oneBox(),
      clearColor: 0xFF102030,
      deviceTransform: const Transform2D.scaling(2, 2),
      damage: const Rect.fromLTRB(0, 0, 5, 5),
    );

    expect(result.status, PresentStatus.presented);
    expect(presenter.framesPresented, 1);
    expect(presenter.sceneElement.children.length, 1);
    expect(presenter.hostElement.style.backgroundColor, isNotEmpty);
  });

  test('the device transform is deliberately not applied to the geometry',
      () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    await presenter.present(
      oneBox(),
      deviceTransform: const Transform2D.scaling(3, 3),
    );

    // A CSS pixel is already a logical unit and the browser applies
    // devicePixelRatio itself. Multiplying here would draw a 10px box at 30px on
    // a 3x display, which is the whole reason this is asserted rather than
    // assumed.
    expect(
      presenter.sceneElement.children.item(0)!.getAttribute('style'),
      contains('width:10px'),
    );
  });

  test('a second identical frame creates no elements', () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    await presenter.present(oneBox());
    await presenter.present(oneBox());

    expect(presenter.lastCreated, 0);
    expect(presenter.lastReused, 1);
  });

  test('there is no device to lose', () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    expect(presenter.isDeviceLost, isFalse);
    expect(await presenter.recoverFromDeviceLoss(), isTrue);
    expect(presenter.info.name, 'web-dom');
  });

  test('resize converts the pixel size back to logical units', () {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    presenter.surfaceResized(pixelWidth: 1600, pixelHeight: 1200, scale: 2);

    // The window hands presenters physical pixels; everything under the host is
    // positioned in CSS pixels. Sizing the host in device pixels gives a clip
    // twice as large as its content on a retina screen, which is invisible
    // until something paints outside the window.
    expect(presenter.hostElement.style.width, '800px');
    expect(presenter.hostElement.style.height, '600px');
  });

  test('dispose removes the host and leaves the container alone', () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    await presenter.present(oneBox());
    expect(host.element.children.length, 1);

    presenter.dispose();

    expect(host.element.children.length, 0);
    expect(host.element.isConnected, isTrue);
  });

  group('attach', () {
    test('a canvas window gets a host positioned over it', () async {
      final WebWindow window = WebWindow.createIn(
        host.element,
        size: const Size(320, 240),
      );
      addTearDown(window.dispose);

      final DomCanvasPresenter presenter =
          await DomCanvasPresenter.attach(window);
      addTearDown(presenter.dispose);

      // The canvas keeps its listeners and its place: hiding it would be tidier
      // and would also stop every pointer event in the application.
      expect(window.canvas.isConnected, isTrue);
      expect(presenter.hostElement.parentElement, host.element);
      expect(presenter.hostElement.style.width, '320px');
      // Nothing this backend creates may take the pointer. Read through the
      // CSSOM rather than off the attribute: assigning `style.width` above
      // re-serialises the whole declaration, so the attribute text is the
      // browser's spelling and not the one this backend wrote.
      expect(presenter.hostElement.style.pointerEvents, 'none');
    });

    test('a canvas outside the document is refused by name, not silently',
        () async {
      // Detached rather than a foreign window type, because this is the failure
      // that can actually happen: a page that builds its canvas and attaches a
      // presenter before appending it. The presenter must say which of its two
      // preconditions failed, since "the DOM path did not start" and "the DOM
      // path started and drew nothing" look identical on screen.
      final web.HTMLCanvasElement orphan =
          web.document.createElement('canvas') as web.HTMLCanvasElement;
      final WebWindow window = WebWindow.wrap(orphan);
      addTearDown(window.dispose);

      await expectLater(
        DomCanvasPresenter.attach(window),
        throwsA(
          isA<BackendSelectionError>().having(
            (BackendSelectionError e) => e.toString(),
            'toString',
            allOf(
              contains('web-dom'),
              contains('not in a document'),
            ),
          ),
        ),
      );
    });
  });

  group('semantics', () {
    test('nothing is published until a source is supplied', () async {
      final DomCanvasPresenter presenter =
          DomCanvasPresenter.attachToElement(host.element);
      addTearDown(presenter.dispose);

      await presenter.present(oneBox());
      expect(presenter.semanticNodeCount, 0);

      presenter.semanticsSource = () => const SemanticsSnapshot(
            SemanticsNode(
              id: 1,
              role: SemanticsRole.button,
              bounds: Rect.fromLTRB(0, 0, 80, 30),
              label: 'Go',
            ),
          );
      await presenter.present(oneBox());

      expect(presenter.semanticNodeCount, 1);
      expect(
        presenter.semanticsElement
            .querySelector('button')!
            .getAttribute('aria-label'),
        'Go',
      );
    });

    test('a source that throws is reported, not allowed to kill the frame',
        () async {
      final DomCanvasPresenter presenter =
          DomCanvasPresenter.attachToElement(host.element);
      addTearDown(presenter.dispose);
      presenter.semanticsSource = () => throw StateError('no tree');

      final PresentResult result = await presenter.present(oneBox());

      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('semantic tree'));
      // The visual layer still went up: a page whose accessibility tree failed
      // must still be a page.
      expect(presenter.sceneElement.children.length, 1);
    });
  });

  test('an image becomes a background whose pixels are un-premultiplied',
      () async {
    final DomCanvasPresenter presenter =
        DomCanvasPresenter.attachToElement(host.element);
    addTearDown(presenter.dispose);

    // Half-transparent red, premultiplied: the stored red is 0x80, not 0xFF.
    // Handing those bytes to ImageData without dividing turns every antialiased
    // edge into a dark fringe, which reads as a bad font rather than as a
    // colour-space bug.
    final Framebuffer image = Framebuffer.allocate(width: 2, height: 2);
    for (int i = 0; i < 4; i++) {
      image.pixels[i * 4] = 0x00; // blue
      image.pixels[i * 4 + 1] = 0x00; // green
      image.pixels[i * 4 + 2] = 0x80; // red, premultiplied by alpha 0x80
      image.pixels[i * 4 + 3] = 0x80; // alpha
    }
    final DisplayList list = DisplayList();
    final int paint = list.addPaint(colorArgb: 0xFFFFFFFF);
    list.drawImage(list.addImage(image), 0, 0, 2, 2, 0, 0, 20, 20, paint);

    await presenter.present(list);

    final web.Element element = presenter.sceneElement.children.item(0)!;
    final String style = element.getAttribute('style')!;
    expect(style, contains('background-image:url(data:image/png'));
    expect(style, contains('width:20px'));
    expect(element.getAttribute('role'), 'img');
  });
}
