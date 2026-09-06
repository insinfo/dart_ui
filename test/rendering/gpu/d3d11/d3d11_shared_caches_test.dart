/// The caches a Direct3D 11 device shares with every target on it.
///
/// `doc/PLANO_POPUPS_EM_JANELAS_NATIVAS.md` section 3.7 promises that a menu's
/// text is already rasterised because the window behind it drew the same face
/// at the same size. A popup is a second *window* in this framework, so that
/// promise is a claim about two render targets on one device - and until the
/// glyph atlas, the font resolver and the image cache moved up to the device it
/// was false: every target built its own, and a menu re-rasterised, from
/// outlines, every glyph already sitting in the atlas next door.
///
/// ## What is measured and what is merely asserted
///
/// The payoff is measured on the atlas's own counters -
/// [GpuGlyphAtlas.missCount] and [GpuGlyphAtlas.entryCount] - and never on
/// elapsed time. A timing assertion on a shared machine is a flake generator,
/// and a miss count is the thing the design actually promises: a second target
/// asking for a glyph the first one rasterised must not rasterise it again.
/// [D3d11RenderDevice.glyphUploadCount] carries the same argument one level
/// down, for the texture.
///
/// ## Why the mask atlas is checked for *not* being shared
///
/// It is the one cache that stayed per target. It repacks above a waste
/// threshold and it evicts, so two windows sharing one would move each other's
/// live slots at whatever interleaving their frame loops produced - a shape
/// drawn from a slot its neighbour has since taken, intermittent, invisible to
/// a headless test and blamed on the geometry. Asserting that two targets hold
/// two different mask atlases is how that decision stays a decision instead of
/// quietly eroding into "share everything".
///
/// ## Real driver, real device loss, stubbed window
///
/// The offscreen cases run on whatever D3D11 device this machine has, WARP
/// included, and read the pixels back. The window cases build a
/// [D3d11WindowTarget] over a swap chain that reports no back buffer, because
/// creating a real window here would need the Win32 surface code and the
/// message loop that goes with it. That stub is enough for what the window
/// cases are about - which caches the target wires itself to, and what
/// disposing it takes with it - and it is honest about what it is not: no pixel
/// on a screen is proved by this file. `tool/popup_window_smoke.dart` is where
/// a real window looks at real text.
///
/// The loss itself is injected with [D3d11RenderDevice.markLost], for the
/// reason `d3d11_recovery_test.dart` sets out at length: there is no supported
/// way for a test process to cause a genuine `DXGI_ERROR_DEVICE_REMOVED`.
/// Everything downstream of the injection - releasing every COM object,
/// `D3D11CreateDevice`, a fresh HLSL compile, fresh textures, fresh uploads -
/// is real.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_window_target.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_glyph_atlas.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

void main() {
  final session = _D3d11Session.open();
  tearDownAll(session.close);

  final Typeface dejaVu = Typeface.parse(
    File('test/fonts/DejaVuSans.ttf').readAsBytesSync(),
  );

  group('two Direct3D 11 targets on one device', () {
    test(
        'share the glyph atlas, the fonts and the images, and never the mask '
        'atlas', () {
      final D3d11RenderDevice device = session.device!;
      final D3d11OffscreenTarget a = session.offscreen(64, 32);
      final D3d11OffscreenTarget b = session.offscreen(64, 32);
      final D3d11WindowTarget window = session.window(64, 32);

      // One object, not two equal ones: `identical` and not `same`, because a
      // second atlas holding the same glyphs would still be a second
      // rasterisation and a second megabyte.
      expect(identical(a.glyphAtlas, b.glyphAtlas), isTrue);
      expect(identical(a.glyphAtlas, window.glyphAtlas), isTrue);
      expect(identical(a.glyphAtlas, device.glyphAtlas), isTrue);

      expect(identical(a.fontResolver, b.fontResolver), isTrue);
      expect(identical(a.fontResolver, window.fontResolver), isTrue);
      expect(identical(a.fontResolver, device.fontResolver), isTrue);

      expect(identical(a.images, b.images), isTrue);
      expect(identical(a.images, window.images), isTrue);
      expect(identical(a.images, device.imageCache), isTrue);

      // And the one that stayed. See this file's library comment.
      expect(identical(a.maskAtlas, b.maskAtlas), isFalse);
      expect(identical(a.maskAtlas, window.maskAtlas), isFalse);
      expect(identical(b.maskAtlas, window.maskAtlas), isFalse);

      // A layer pool is per target too, and for a plainer reason: its targets
      // are sized to the surface, and two surfaces are two sizes.
      expect(identical(a.layerPool, b.layerPool), isFalse);
    }, skip: session.skipReason);

    test('the second one finds the first one\'s glyphs already rasterised',
        () async {
      final D3d11RenderDevice device = session.device!;
      // A size of its own, so the keys cannot collide with another case's and
      // turn a genuine miss into a hit.
      final ScaledTypeface font = dejaVu.atSize(21);
      final DisplayList text = _run(font, _glyphsFor(dejaVu, 'popup'));

      final D3d11OffscreenTarget a = session.offscreen(160, 48);
      final int missesBefore = device.glyphAtlas.missCount;
      final int entriesBefore = device.glyphAtlas.entryCount;
      expect(
        (await a.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      final int rasterised = device.glyphAtlas.missCount - missesBefore;
      expect(rasterised, greaterThan(0),
          reason: 'a run that rasterised nothing would make the rest of this '
              'test vacuous');
      expect(device.glyphAtlas.entryCount, entriesBefore + rasterised);
      final int uploadsAfterFirst = device.glyphUploadCount;
      expect(uploadsAfterFirst, greaterThan(0));

      // The second target is the popup. It has never drawn anything.
      final D3d11OffscreenTarget b = session.offscreen(160, 48);
      final int missesAfterFirst = device.glyphAtlas.missCount;
      final int hitsAfterFirst = device.glyphAtlas.hitCount;
      expect(
        (await b.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );

      // The claim, stated three ways because each one fails differently: no
      // glyph was rasterised again, every lookup was answered from the atlas,
      // and no texel was sent to the GPU a second time.
      expect(device.glyphAtlas.missCount, missesAfterFirst,
          reason: 'the popup re-rasterised a glyph the window behind it had '
              'already rasterised, which is exactly the cost this change '
              'removed');
      expect(device.glyphAtlas.hitCount, greaterThan(hitsAfterFirst));
      expect(device.glyphUploadCount, uploadsAfterFirst,
          reason: 'the coverage was already in the shared texture');

      // And it drew the same picture, which is what makes the counters mean
      // something: an atlas hit that produced a blank quad would satisfy every
      // assertion above.
      expect(b.framebuffer.pixels, orderedEquals(a.framebuffer.pixels));
      expect(_isAllOneColour(b.framebuffer.pixels), isFalse,
          reason: 'two identical blank frames would prove nothing');
    }, skip: session.skipReason);

    test('a window target draws from the coverage an offscreen target packed',
        () async {
      final D3d11RenderDevice device = session.device!;
      final ScaledTypeface font = dejaVu.atSize(23);
      final DisplayList text = _run(font, _glyphsFor(dejaVu, 'menu'));

      final D3d11OffscreenTarget behind = session.offscreen(160, 48);
      expect(
        (await behind.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      final int misses = device.glyphAtlas.missCount;
      expect(misses, greaterThan(0));

      // The window target's present fails - the stub chain has no back buffer -
      // and that is deliberate: everything the atlas is asked for happens in
      // the replay, before a single pixel is presented, so the counters below
      // are about the *rasterisation* and not about the driver.
      final D3d11WindowTarget popup = session.window(160, 48);
      final PresentResult result =
          await popup.renderDisplayList(text, clearColor: _clear);
      expect(result.status, PresentStatus.failed,
          reason: 'the stub swap chain has no back-buffer view, and the target '
              'is supposed to say so by name rather than draw nowhere');
      expect(device.glyphAtlas.missCount, misses,
          reason: 'the popup window rasterised glyphs the target behind it had '
              'already packed');
    }, skip: session.skipReason);

    test('disposing one leaves the other able to draw the same text', () async {
      final D3d11RenderDevice device = session.device!;
      final ScaledTypeface font = dejaVu.atSize(19);
      final DisplayList text = _run(font, _glyphsFor(dejaVu, 'stays'));

      final D3d11OffscreenTarget a = session.offscreen(160, 48);
      final D3d11OffscreenTarget b = session.offscreen(160, 48);
      expect(
        (await a.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      final Uint8List expected = Uint8List.fromList(a.framebuffer.pixels);
      expect(_isAllOneColour(expected), isFalse);
      final int entries = device.glyphAtlas.entryCount;
      final int misses = device.glyphAtlas.missCount;

      // The window closes. Under the old arrangement this released the atlas
      // texture and cleared the entries; here it must take nothing but its own
      // mask texture and layer pool with it.
      a.dispose();
      expect(device.glyphAtlas.entryCount, entries,
          reason: 'closing a window threw away coverage another window is '
              'still drawing from');

      expect(
        (await b.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      expect(device.glyphAtlas.missCount, misses,
          reason: 'the surviving target had to rasterise again, so the closed '
              'one did take the atlas with it');
      // The proof that matters: the same pixels, not merely the same counters.
      // A cleared atlas texture would leave the counters alone and blank the
      // text.
      expect(b.framebuffer.pixels, orderedEquals(expected));
    }, skip: session.skipReason);

    test('disposing one leaves the other able to draw the same image',
        () async {
      final D3d11RenderDevice device = session.device!;
      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      final D3d11OffscreenTarget a = session.offscreen(16, 16);
      final D3d11OffscreenTarget b = session.offscreen(16, 16);
      await a.renderDisplayList(list, clearColor: _clear);
      final Uint8List expected = Uint8List.fromList(a.framebuffer.pixels);
      final int uploaded = device.imageCache.length;
      expect(uploaded, greaterThan(0));

      a.dispose();
      expect(device.imageCache.length, uploaded,
          reason: 'closing a window released a texture the other one still '
              'draws with');

      expect(
        (await b.renderDisplayList(list, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      expect(device.imageCache.length, uploaded,
          reason: 'the image was uploaded a second time, so the cache was not '
              'shared after all');
      expect(b.framebuffer.pixels, orderedEquals(expected));
    }, skip: session.skipReason);
  });

  group('a device loss with two targets on the device', () {
    test('names the shared glyph atlas once, not once per target', () {
      final D3d11RenderDevice device = D3d11RendererBackend.openDevice();
      addTearDown(device.dispose);
      _offscreenOn(device, 32, 32);
      _offscreenOn(device, 32, 32);
      _windowOn(device, 32, 32);

      final List<String> names = device
          .recoverableResources()
          .map((GpuRecoverableResource r) => r.resourceName)
          .toList(growable: false);
      printOnFailure(names.join('\n'));

      expect(
        names.where((String n) => n.contains('shared glyph atlas')).length,
        1,
        reason: 'the glyph atlas is the device\'s, so a three-target device '
            'must rebuild it once; naming it three times would also mean '
            'discarding it three times, and the third discard would release a '
            'texture the second rebuild had just created',
      );
      // Every target still names its own mask atlas, because every target
      // still has one.
      expect(names.where((String n) => n.contains('mask atlas')).length, 3);

      // Order is the contract: the shared texture has to exist before any
      // target's sink reads its id into a final field.
      expect(names.first, contains('shared glyph atlas'));
    }, skip: session.skipReason);

    test('rebuilds the shared caches once and both targets come back',
        () async {
      final D3d11RenderDevice device = D3d11RendererBackend.openDevice();
      addTearDown(device.dispose);
      final ScaledTypeface font = dejaVu.atSize(18);
      final DisplayList text = _run(font, _glyphsFor(dejaVu, 'both'));

      final D3d11OffscreenTarget a = _offscreenOn(device, 160, 48);
      final D3d11OffscreenTarget b = _offscreenOn(device, 160, 48);
      final coordinator = GpuRecoveryCoordinator(host: device);

      expect((await a.renderDisplayList(text, clearColor: _clear)).status,
          PresentStatus.presented);
      expect((await b.renderDisplayList(text, clearColor: _clear)).status,
          PresentStatus.presented);
      final Uint8List expectedA = Uint8List.fromList(a.framebuffer.pixels);
      final Uint8List expectedB = Uint8List.fromList(b.framebuffer.pixels);
      expect(_isAllOneColour(expectedA), isFalse);
      expect(device.glyphAtlas.entryCount, greaterThan(0));

      final int textureBefore = device.glyphTexture.id;

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();
      printOnFailure('$report');
      expect(report.isRecovered, isTrue, reason: '$report');
      expect(report.unrecoverableResources, isEmpty, reason: '$report');

      // A genuinely new texture, and the old one genuinely dead. A target left
      // holding the previous generation's id is the failure this ordering
      // exists to prevent, and it does not reproduce on demand.
      expect(device.glyphTexture.id, isNot(textureBefore));
      expect(device.glyphAtlas.entryCount, 0,
          reason: 'coverage that survived the loss would name texels in a '
              'texture the driver has freed');

      // Both targets draw the pre-loss picture, from coverage rasterised again
      // into the new shared texture.
      expect((await a.renderDisplayList(text, clearColor: _clear)).status,
          PresentStatus.presented);
      expect(a.framebuffer.pixels, orderedEquals(expectedA));
      final int missesAfterA = device.glyphAtlas.missCount;
      expect((await b.renderDisplayList(text, clearColor: _clear)).status,
          PresentStatus.presented);
      expect(b.framebuffer.pixels, orderedEquals(expectedB));
      // And the sharing survived the recovery: the second target rasterised
      // nothing, which it could only do by reading the atlas the first one
      // refilled.
      expect(device.glyphAtlas.missCount, missesAfterA);
    }, skip: session.skipReason);

    test('a window target on the recovered device holds the new texture id',
        () async {
      final D3d11RenderDevice device = D3d11RendererBackend.openDevice();
      addTearDown(device.dispose);
      final ScaledTypeface font = dejaVu.atSize(16);
      final DisplayList text = _run(font, _glyphsFor(dejaVu, 'win'));

      final D3d11OffscreenTarget offscreen = _offscreenOn(device, 96, 32);
      final D3d11WindowTarget window = _windowOn(device, 96, 32);
      final coordinator = GpuRecoveryCoordinator(host: device);

      await offscreen.renderDisplayList(text, clearColor: _clear);
      final Uint8List expected =
          Uint8List.fromList(offscreen.framebuffer.pixels);

      device.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();
      printOnFailure('$report');
      // The swap chain is the one thing that cannot come back, and the window
      // target says so by name rather than presenting into a released device.
      expect(report.status, GpuRecoveryStatus.recoveredWithLosses);
      expect(
        report.unrecoverableResources.single,
        contains('swap chain'),
      );
      expect(device.isLost, isFalse);

      // The offscreen target draws again, through a sink rebuilt against the
      // new shared texture. If step 5 had repopulated the targets before the
      // device's own caches, this is where the old id would show up - as a
      // frame drawn from a texture that no longer exists.
      expect(
        (await offscreen.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.presented,
      );
      expect(offscreen.framebuffer.pixels, orderedEquals(expected));

      // The window target survived the recovery as an object; only its chain
      // is gone, and it still refuses by name.
      expect(window.isDisposed, isFalse);
      expect(
        (await window.renderDisplayList(text, clearColor: _clear)).status,
        PresentStatus.failed,
      );
    }, skip: session.skipReason);
  });
}

/// Opaque black, so a scene that got its alpha wrong shows as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

D3d11OffscreenTarget _offscreenOn(
  D3d11RenderDevice device,
  int width,
  int height,
) =>
    device.createTarget(MemorySurfaceDescriptor(
      pixelWidth: width,
      pixelHeight: height,
      format: PixelFormat.rgba8888Premultiplied,
    )) as D3d11OffscreenTarget;

D3d11WindowTarget _windowOn(
  D3d11RenderDevice device,
  int width,
  int height,
) =>
    D3d11WindowTarget(
      device,
      D3d11WindowSurfaceDescriptor(
        nativeHandle: 0xD3D11,
        pixelWidth: width,
        pixelHeight: height,
        swapChain: _StubSwapChain(),
        generation: GenerationToken(),
      ),
    );

/// A swap chain that is presentable and has no back buffer.
///
/// Deliberately not a mock of a working chain. A real one needs
/// `IDXGIFactory2::CreateSwapChainForHwnd` and therefore an `HWND`, a window
/// class and a message loop; what these cases need from it is that
/// [D3d11WindowTarget] can be constructed, can replay a display list, and
/// refuses the present by name. `backBufferView` answering `nullptr` is the
/// state a real chain is in after a failed `ResizeBuffers`, so the target's
/// handling of it is a path that exists for production and not for this file.
final class _StubSwapChain implements D3d11SwapChain {
  @override
  Pointer<Void> get backBufferView => nullptr;

  @override
  bool get isPresentable => true;

  @override
  int present() => 0;

  @override
  bool setSyncInterval(int interval) => true;

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      null;
}

/// One device for the whole file where a case does not need its own.
///
/// A device costs a `D3D11CreateDevice` and a full HLSL compile, and sharing
/// one is also closer to what this file is about: the caches only matter
/// because targets share a device.
final class _D3d11Session {
  _D3d11Session._(this.device, this.skipReason);

  final D3d11RenderDevice? device;

  /// Null when the device opened. A string - which `skip:` accepts - when it
  /// did not, so a run on Linux names what was missing rather than passing
  /// quietly.
  final String? skipReason;

  static _D3d11Session open() {
    if (!Platform.isWindows) {
      return _D3d11Session._(
        null,
        'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}',
      );
    }
    try {
      return _D3d11Session._(D3d11RendererBackend.openDevice(), null);
    } on BackendSelectionError catch (error) {
      return _D3d11Session._(null, 'no D3D11 device: $error');
    } on Object catch (error) {
      return _D3d11Session._(null, 'opening a D3D11 device threw: $error');
    }
  }

  D3d11OffscreenTarget offscreen(int width, int height) =>
      _offscreenOn(device!, width, height);

  D3d11WindowTarget window(int width, int height) =>
      _windowOn(device!, width, height);

  void close() => device?.dispose();
}

/// One glyph run at a fixed origin, laid out here rather than shaped: what is
/// on trial is the cache and not the shaper.
DisplayList _run(ScaledTypeface font, List<int> glyphs) {
  final list = DisplayList();
  final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  final offsets = Float32List(glyphs.length * 2);
  for (var i = 0; i < glyphs.length; i++) {
    offsets[i * 2] = i * font.pixelSize * 0.62;
  }
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    4,
    font.pixelSize + 4,
    Int32List.fromList(glyphs),
    offsets,
    glyphs.length,
  );
  return list;
}

List<int> _glyphsFor(Typeface face, String text) => <int>[
      for (final int rune in text.runes) face.glyphForCodePoint(rune),
    ];

Framebuffer _checkerboard() {
  final image = Framebuffer.allocate(
    width: 4,
    height: 4,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final int offset = y * image.bytesPerRow + x * 4;
      final int value = (x + y).isEven ? 0xFF : 0x20;
      image.pixels[offset] = value;
      image.pixels[offset + 1] = value ~/ 2;
      image.pixels[offset + 2] = 0xFF - value;
      image.pixels[offset + 3] = 0xFF;
    }
  }
  return image;
}

bool _isAllOneColour(Uint8List pixels) {
  for (var i = 4; i < pixels.length; i += 4) {
    if (pixels[i] != pixels[0] ||
        pixels[i + 1] != pixels[1] ||
        pixels[i + 2] != pixels[2] ||
        pixels[i + 3] != pixels[3]) {
      return false;
    }
  }
  return true;
}
