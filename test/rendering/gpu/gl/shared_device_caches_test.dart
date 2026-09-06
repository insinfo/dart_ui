/// The caches a GL device owns, and the ones its targets still own.
///
/// `doc/PLANO_POPUPS_EM_JANELAS_NATIVAS.md` section 3.7 promises that a menu's
/// text is already rasterised because the same font at the same size was
/// already drawn in the window behind it. Before this file that was false on
/// every backend: each target built a [GpuGlyphAtlas], a `GlFontResolver` and a
/// `GlImageCache` in its constructor, so every window and every popup started
/// from an empty atlas and re-rasterised its glyphs from outlines. The caches
/// now belong to [GlRenderDevice], and these tests are what says so.
///
/// ## What this file can and cannot prove on OpenGL, said first
///
/// It proves the *structure*: two targets on one device share one atlas, one
/// resolver and one image cache; a glyph rasterised for one is resident for the
/// other; disposing one leaves the other drawing; and a device loss rebuilds
/// the shared texture once, before either target rebuilds the sink that
/// captured its id.
///
/// It cannot prove a *speed-up for two windows*, and no test here pretends to.
/// GL texture names live in a context rather than in a process, and this
/// backend creates every context without a share group - `win32_gl_surface.dart`
/// builds one from the window's own `HDC` and passes nothing to share lists
/// with, and the X11 path does the same. `default_platform_resolver.dart` then
/// builds one [GlRenderDevice] per window from that context, so today one
/// device is one context is one window. Two windows therefore have two atlases,
/// and the last group below asserts exactly that as *correct*: sharing a
/// texture name across unshared contexts would be a use of a name that either
/// resolves to nothing or resolves to somebody else's object. The win the plan
/// describes is real on D3D11, where one device does serve several swap chains;
/// here the move is structural, and it is what turns "share the caches" into a
/// change of which device a window is handed rather than a refactor of who owns
/// an atlas, on the day the platform layer creates a context with
/// `wglShareLists`.
///
/// Every test skips rather than fails where no driver answers: "this machine
/// has no GPU" is not a defect in the renderer.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_window_target.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_recovery.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// Opaque black, so a scene that got its alpha wrong shows as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final _GlSession session = _GlSession.open();
  tearDownAll(session.close);

  final Typeface dejaVu = Typeface.parse(_fontBytes('DejaVuSans.ttf'));

  group('two targets on one GL device', () {
    test('share the glyph atlas, the font resolver and the image cache',
        () async {
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget a = session.target(64, 32);
      final GlOffscreenTarget b = session.target(64, 32);

      // Identity, not equality: the whole claim is that there is one object,
      // because one object is what makes a glyph rasterised for `a` resident
      // for `b`. Two equal-but-distinct atlases would pass an `==` and
      // re-rasterise every letter.
      expect(identical(a.glyphAtlas, b.glyphAtlas), isTrue);
      expect(identical(a.glyphAtlas, device.glyphAtlas), isTrue);
      expect(identical(a.images, b.images), isTrue);
      expect(identical(a.images, device.images), isTrue);

      a.dispose();
      b.dispose();
    }, skip: session.skipReason);

    test('do not share the coverage atlas, and that is the deliberate half',
        () async {
      final GlOffscreenTarget a = session.target(64, 32);
      final GlOffscreenTarget b = session.target(64, 32);

      // `GpuMaskAtlas.beginFrame` repacks above a waste threshold and evicts,
      // so its contents are scoped to the frame being recorded rather than to
      // the device. Two targets sharing one would throw away coverage the
      // other had already emitted quads for, and the frame that lost it would
      // render *almost* correctly - the failure that does not reproduce on
      // demand and is invisible in a headless test. So this is asserted as a
      // decision rather than left as an accident.
      expect(identical(a.maskAtlas, b.maskAtlas), isFalse);

      a.dispose();
      b.dispose();
    }, skip: session.skipReason);

    test('a window target shares with an offscreen target on the same device',
        () async {
      // The shape the plan is about, as close as GL gets to it: a window and a
      // second target on the one context. A popup is the second target on
      // D3D11; here it would be a second *device*, which the last group
      // covers.
      final _WindowSession windows = _WindowSession.open();
      addTearDown(windows.close);
      if (windows.skipReason != null) {
        markTestSkipped(windows.skipReason!);
        return;
      }
      final GlWindowTarget window = windows.target(64, 32);
      final GlOffscreenTarget offscreen =
          windows.device!.createTarget(const MemorySurfaceDescriptor(
        pixelWidth: 64,
        pixelHeight: 32,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

      expect(identical(window.glyphAtlas, offscreen.glyphAtlas), isTrue);
      expect(identical(window.images, offscreen.images), isTrue);
      expect(identical(window.maskAtlas, offscreen.maskAtlas), isFalse);

      offscreen.dispose();
      window.dispose();
    }, skip: session.skipReason);
  });

  group('a glyph rasterised for one target', () {
    test('is already resident when the next target asks for it', () async {
      // The section 3.7 claim, asserted on the atlas's own bookkeeping rather
      // than on a clock: a timing test on a warm cache measures the driver.
      //
      // A size nothing else in this file uses, so the first target's frame is
      // a genuine set of misses on a device-wide atlas rather than a hit on
      // some earlier test's leftovers - which would make this pass while
      // measuring nothing at all.
      final GlOffscreenTarget first = session.target(96, 32);
      final ScaledTypeface font = dejaVu.atSize(23);
      final DisplayList list = _text(dejaVu, font, 'menu');

      final int missesBefore = first.glyphAtlas.missCount;
      await first.renderDisplayList(list, clearColor: _clear);
      final int rasterised = first.glyphAtlas.missCount - missesBefore;
      expect(rasterised, greaterThan(0),
          reason: 'the first target has to have rasterised this run, or the '
              'second target is not being asked anything');

      // Residency checked without going through `acquire`, which would touch
      // the plot it is asking about and change the answer.
      for (final int glyph in _glyphsFor(dejaVu, 'menu')) {
        expect(first.glyphAtlas.isResident(font, glyph), isTrue);
      }

      final GlOffscreenTarget second = session.target(96, 32);
      final int missesAtHandover = second.glyphAtlas.missCount;
      final int hitsAtHandover = second.glyphAtlas.hitCount;
      await second.renderDisplayList(list, clearColor: _clear);

      expect(second.glyphAtlas.missCount, missesAtHandover,
          reason: 'the second target must not rasterise a glyph the first one '
              'already put in the shared atlas - that is the whole promise');
      expect(second.glyphAtlas.hitCount - hitsAtHandover,
          greaterThanOrEqualTo(rasterised),
          reason: 'and every one of them has to come back as a hit');
      expect(_isUniform(second.framebuffer), isFalse,
          reason: 'a cache hit still has to draw the letters');

      first.dispose();
      second.dispose();
    }, skip: session.skipReason);

    test('costs no second upload, because there is one texture', () async {
      // The other half of "one atlas implies one texture": if each target
      // staged a shared atlas into a texture of its own, the first to present
      // would consume the dirty plots through `markUploaded` and the second
      // would sample texels its texture never received. One texture means the
      // second target's frame sends nothing.
      final GlOffscreenTarget first = session.target(96, 32);
      final ScaledTypeface font = dejaVu.atSize(24);
      final DisplayList list = _text(dejaVu, font, 'once');

      final int uploadsBefore = first.glyphUploadCount;
      await first.renderDisplayList(list, clearColor: _clear);
      final int uploaded = first.glyphUploadCount - uploadsBefore;
      expect(uploaded, greaterThan(0));

      final GlOffscreenTarget second = session.target(96, 32);
      final int uploadsAtHandover = second.glyphUploadCount;
      await second.renderDisplayList(list, clearColor: _clear);
      expect(second.glyphUploadCount, uploadsAtHandover,
          reason: 'nothing was written, so nothing is dirty, so nothing is '
              'sent - and the texture the second target samples is the one '
              'the first uploaded into');

      first.dispose();
      second.dispose();
    }, skip: session.skipReason);
  });

  group('disposing one target', () {
    test('leaves the other drawing the same text', () async {
      // The failure this change invites, asserted directly. A target that
      // cleared the glyph atlas, released the glyph texture or unbound the
      // font resolver on its way out would blank its neighbour's text - which
      // on screen is closing a menu and watching the window behind it lose
      // every label.
      final GlOffscreenTarget survivor = session.target(96, 32);
      final GlOffscreenTarget doomed = session.target(96, 32);
      final ScaledTypeface font = dejaVu.atSize(25);
      final DisplayList list = _text(dejaVu, font, 'stay');

      await doomed.renderDisplayList(list, clearColor: _clear);
      await survivor.renderDisplayList(list, clearColor: _clear);
      final Uint8List before = Uint8List.fromList(survivor.framebuffer.pixels);
      expect(_isUniform(survivor.framebuffer), isFalse);

      final int missesBefore = survivor.glyphAtlas.missCount;
      doomed.dispose();

      // Still resident: the atlas was not cleared by the target that left.
      for (final int glyph in _glyphsFor(dejaVu, 'stay')) {
        expect(survivor.glyphAtlas.isResident(font, glyph), isTrue,
            reason: 'disposing a target must not evict the device\'s glyphs');
      }

      await survivor.renderDisplayList(list, clearColor: _clear);
      expect(survivor.framebuffer.pixels, orderedEquals(before),
          reason: 'the same text, pixel for pixel, after the neighbour closed');
      expect(survivor.glyphAtlas.missCount, missesBefore,
          reason: 'and drawn from the atlas rather than rasterised again, '
              'which is what a released glyph texture would have forced');

      survivor.dispose();
    }, skip: session.skipReason);

    test('leaves the other target\'s uploaded image drawable', () async {
      // The image cache moved for the same reason and has the same failure:
      // `GlImageCache.clear` releases every texture, so a target calling it on
      // dispose would strand every other target's images.
      final GlOffscreenTarget survivor = session.target(16, 16);
      final GlOffscreenTarget doomed = session.target(16, 16);

      final Framebuffer image = _checkerboard();
      final DisplayList list = DisplayList();
      final int paint = list.addPaint(colorArgb: 0xFFFFFFFF, antiAlias: false);
      final int id = list.addImage(image);
      list.drawImage(id, 0, 0, 4, 4, 0, 0, 16, 16, paint);

      await doomed.renderDisplayList(list, clearColor: _clear);
      await survivor.renderDisplayList(list, clearColor: _clear);
      final Uint8List before = Uint8List.fromList(survivor.framebuffer.pixels);

      doomed.dispose();

      await survivor.renderDisplayList(list, clearColor: _clear);
      expect(survivor.framebuffer.pixels, orderedEquals(before),
          reason: 'the texture the disposed target uploaded is the device\'s, '
              'and the survivor is still drawing out of it');

      survivor.dispose();
    }, skip: session.skipReason);
  });

  group('a device loss', () {
    test('rebuilds the shared glyph texture once, and both targets recover',
        () async {
      // The sequencing this move made load-bearing. Every target's sink holds
      // the glyph texture *id* as a final field, so the device's entry has to
      // repopulate before any target rebuilds its sink; a target rebuilt first
      // would come back wired to the previous context's texture, which is a
      // use-after-loss that draws nothing on a device reporting itself healthy
      // and reproduces on nobody's machine.
      final GlRenderDevice device = session.device!;
      final GlOffscreenTarget a = session.target(96, 32);
      final GlOffscreenTarget b = session.target(96, 32);
      final coordinator = GpuRecoveryCoordinator(host: device);
      final ScaledTypeface font = dejaVu.atSize(26);
      final DisplayList list = _text(dejaVu, font, 'lost');

      await a.renderDisplayList(list, clearColor: _clear);
      await b.renderDisplayList(list, clearColor: _clear);
      final Uint8List beforeA = Uint8List.fromList(a.framebuffer.pixels);
      final Uint8List beforeB = Uint8List.fromList(b.framebuffer.pixels);
      expect(_isUniform(a.framebuffer), isFalse);

      // Named once in the inventory, however many targets are live: a second
      // entry would discard the texture the first one had just recreated.
      final List<String> glyphEntries = device
          .recoverableResources()
          .map((GpuRecoverableResource r) => r.resourceName)
          .where((String name) => name.contains('shared glyph atlas'))
          .toList();
      expect(glyphEntries, hasLength(1), reason: '$glyphEntries');

      device.state.markLost(const BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'a test asked for the loss path',
      ));
      final GpuRecoveryReport report = coordinator.recover();
      expect(report.status, GpuRecoveryStatus.recovered, reason: '$report');

      // Cleared with the texture, so nothing claims to be resident in a name
      // the driver freed.
      expect(a.glyphAtlas.entryCount, 0);

      await a.renderDisplayList(list, clearColor: _clear);
      await b.renderDisplayList(list, clearColor: _clear);
      expect(a.framebuffer.pixels, orderedEquals(beforeA),
          reason: 'the first target draws the same text through the rebuilt '
              'shared texture');
      expect(b.framebuffer.pixels, orderedEquals(beforeB),
          reason: 'and so does the second, which is the target that would '
              'have been left holding the old texture name');

      a.dispose();
      b.dispose();
    }, skip: session.skipReason);
  });

  group('two GL devices', () {
    test('do not share an atlas, because their contexts do not share names',
        () async {
      // The negative assertion, and it is correct rather than a shortfall. A
      // GL texture name is meaningful only inside the context that generated
      // it, and this backend creates every context without a share group, so a
      // second device sharing the first's atlas would be batching quads
      // against a name that resolves to nothing or to another context's
      // object. Avalonia draws the same distinction with two booleans - GLX
      // answers "can share objects: yes, uses one shared context: no" - so a
      // context per window is the normal answer here.
      //
      // What would have to change for the sharing to become a win on GL is
      // named in `win32_gl_surface.dart`'s `createContext`, which passes no
      // context to share lists with; that file is not this layer's to edit.
      final _GlSession other = _GlSession.open();
      addTearDown(other.close);
      if (other.skipReason != null) {
        markTestSkipped(other.skipReason!);
        return;
      }
      expect(identical(session.device!.glyphAtlas, other.device!.glyphAtlas),
          isFalse);
      expect(identical(session.device!.images, other.device!.images), isFalse);
    }, skip: session.skipReason);
  });
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

DisplayList _text(Typeface face, ScaledTypeface font, String text) {
  final list = DisplayList();
  final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
  final List<int> glyphs = _glyphsFor(face, text);
  final offsets = Float32List(glyphs.length * 2);
  for (var i = 0; i < glyphs.length; i++) {
    offsets[i * 2] = i * 14.0;
  }
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    4,
    24,
    Int32List.fromList(glyphs),
    offsets,
    glyphs.length,
  );
  return list;
}

List<int> _glyphsFor(Typeface face, String text) => <int>[
      for (final int rune in text.runes) face.glyphForCodePoint(rune),
    ];

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

/// A 4x4 checkerboard, small enough that its bytes are worth asserting on.
Framebuffer _checkerboard() {
  final Framebuffer image = Framebuffer.allocate(
    width: 4,
    height: 4,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      final int offset = y * image.bytesPerRow + x * 4;
      image.pixels[offset] = (x & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 1] = (y & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 2] = ((x + y) & 1) == 0 ? 0xFF : 0x20;
      image.pixels[offset + 3] = 0xFF;
    }
  }
  return image;
}

/// Whether every pixel is the first one. A frame that drew nothing at all is
/// uniform, and so is one that cleared and then refused every draw.
bool _isUniform(Framebuffer image) {
  final Uint8List pixels = image.pixels;
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

/// A device on a real driver, with offscreen targets, or the reason there is
/// none.
final class _GlSession {
  _GlSession._(this.device, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      if (!Platform.isWindows) {
        final load = GlLibrary.open();
        if (!load.isLoaded) {
          return _GlSession._(
              null, 'no GL library: ${load.attempted.join(', ')}', null);
        }
        final attempt = const GlContextFactory()
            .create(width: 16, height: 16, glLibrary: load.library!);
        final GlContext? context = attempt.context;
        if (context == null) {
          return _GlSession._(
              null, 'no EGL context: ${attempt.diagnostics.join('; ')}', null);
        }
        return _GlSession._(
          GlRendererBackend.adoptContext(context, load.library!),
          null,
          null,
        );
      }
      final attempt = Win32GlSurface.hidden(className: 'DartUiGlSharedCaches');
      final Win32GlSurface? surface = attempt.surface;
      if (surface == null) {
        return _GlSession._(
            null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
      }
      final contextAttempt = surface.createContext();
      final GlContext? context = contextAttempt.context;
      if (context == null) {
        surface.dispose();
        return _GlSession._(null,
            'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
      }
      try {
        return _GlSession._(
          GlRendererBackend.adoptContext(context, surface.glLibrary),
          null,
          surface,
        );
      } on BackendSelectionError catch (error) {
        surface.dispose();
        return _GlSession._(null, 'no GL device: $error', null);
      }
    } on Object catch (error) {
      return _GlSession._(null, 'opening a GL device threw: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}

/// A device over a real, hidden `HWND`, for the one test that needs a window
/// target rather than a framebuffer object.
final class _WindowSession {
  _WindowSession._(this.device, this._surface, this.skipReason);

  final GlRenderDevice? device;
  final Win32GlSurface? _surface;
  final String? skipReason;

  static _WindowSession open() {
    if (!Platform.isWindows) {
      return _WindowSession._(
          null,
          null,
          'the windowed GL target is exercised through WGL, which needs '
          'Windows');
    }
    try {
      final attempt =
          Win32GlSurface.hidden(className: 'DartUiGlSharedCachesWindow');
      final Win32GlSurface? surface = attempt.surface;
      if (surface == null) {
        return _WindowSession._(
            null, null, 'no GL surface: ${attempt.diagnostics.join('; ')}');
      }
      final contextAttempt = surface.createContext();
      final GlContext? context = contextAttempt.context;
      if (context == null) {
        surface.dispose();
        return _WindowSession._(null, null,
            'no GL context: ${contextAttempt.diagnostics.join('; ')}');
      }
      try {
        return _WindowSession._(
          GlRendererBackend.adoptContext(context, surface.glLibrary),
          surface,
          null,
        );
      } on BackendSelectionError catch (error) {
        surface.dispose();
        return _WindowSession._(null, null, 'no GL device: $error');
      }
    } on Object catch (error) {
      return _WindowSession._(
          null, null, 'opening a windowed GL device threw: $error');
    }
  }

  GlWindowTarget target(int width, int height) =>
      device!.createTarget(GlWindowSurfaceDescriptor(
        nativeHandle: _surface!.windowHandle,
        pixelWidth: width,
        pixelHeight: height,
        swapChain: _surface,
        generation: GenerationToken(),
      )) as GlWindowTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}
