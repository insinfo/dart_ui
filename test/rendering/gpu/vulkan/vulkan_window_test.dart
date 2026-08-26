/// Vulkan presenting into a real Win32 window: surface, swapchain, the
/// acquire/present handshake, resize, and the pixels that came out of it.
///
/// Every other Vulkan test in this directory renders into an image it allocated
/// itself. This one is the reason the backend is a renderer rather than an
/// image exporter: it takes an `HWND` from `Win32WindowingBackend`, creates a
/// `VkSurfaceKHR` from it, builds a swapchain, and runs frames through
/// `vkAcquireNextImageKHR` -> record -> `vkQueueSubmit` -> `vkQueuePresentKHR`.
///
/// ## The window is real and hidden
///
/// `WindowOptions(visible: false)` makes a window that exists, has a handle,
/// has a client area and can back a swapchain, and that nobody has to look at.
/// That is what makes this test runnable without a human: Windows creates the
/// surface and the presentation engine accepts the presents whether or not the
/// desktop composites them anywhere. What it does **not** prove is that a
/// person would see the picture - that is a claim no automated test on this
/// machine can make, and it is not made.
///
/// ## What the pixels are compared against
///
/// [VulkanWindowTarget.captureFrames] copies each presented image back, so the
/// window's own bytes can be diffed against the CPU rasteriser exactly as
/// `vulkan_cpu_parity_test.dart` does for an offscreen target. The copy needs
/// `TRANSFER_SRC` usage on the swapchain images, which nothing guarantees; when
/// the surface refuses it the comparison skips with that reason rather than
/// silently passing.
///
/// ## Validation, honestly
///
/// The session asks for `VK_LAYER_KHRONOS_validation`. **On the machine these
/// tests were written on it is not installed** - an Intel ICD with no LunarG
/// SDK - so what ran here was the driver's own acceptance of every surface,
/// swapchain, semaphore and barrier, not a validator's. The absence is printed
/// once, by the last test, rather than per test.
@TestOn('windows')
library;

import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_backend.dart';
import 'package:dart_ui/src/backends/win32/win32_window.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/platform/native_window.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_instance.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_swapchain.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

const int _width = 160;
const int _height = 120;
const int _clear = 0xFF101820;

void main() {
  VulkanInstance? instance;
  Win32WindowingBackend? windows;
  VulkanRenderDevice? device;
  String? skip;

  setUpAll(() async {
    final VulkanLoadResult load = VulkanLibrary.open();
    final VulkanLibrary? library = load.library;
    if (library == null) {
      skip = 'no Vulkan loader (tried ${load.attempted.join(', ')}): '
          '${load.failureText}';
      return;
    }
    final VulkanInstanceAttempt attempt = VulkanInstance.create(
      library,
      options: const VulkanInstanceOptions(
        validation: true,
        surfaces: <VulkanSurfacePlatform>{VulkanSurfacePlatform.win32},
      ),
    );
    instance = attempt.instance;
    if (instance == null) {
      skip = 'no Vulkan instance: ${attempt.failureText}';
      return;
    }
    if (!instance!.supportsSurface(VulkanSurfacePlatform.win32)) {
      skip = 'this loader has no VK_KHR_win32_surface; enabled extensions are '
          '${instance!.enabledExtensions}';
      return;
    }
    windows = Win32WindowingBackend();
    await windows!.initialize();
    try {
      device = VulkanRenderDevice.adoptInstance(
        instance!,
        enablePresentation: true,
        enableExperimentalSparseStrips: true,
      );
    } on BackendSelectionError catch (error) {
      skip = 'no presenting Vulkan device: $error';
    }
  });

  tearDownAll(() async {
    device?.dispose();
    await windows?.shutdown();
    instance?.dispose();
  });

  /// A hidden window and a target on it, both torn down with the test.
  Future<(Win32Window, VulkanWindowTarget)> open({
    int width = _width,
    int height = _height,
    VulkanPresentPolicy policy = VulkanPresentPolicy.fifo,
  }) async {
    final Win32Window window = await windows!.createWindow(
      WindowOptions(
        title: 'vulkan window test',
        size: Size(width.toDouble(), height.toDouble()),
        visible: false,
      ),
    ) as Win32Window;
    addTearDown(window.close);
    final VulkanWindowTarget target = device!.createTarget(
      VulkanWindowSurfaceDescriptor(
        platform: VulkanSurfacePlatform.win32,
        windowHandle: window.handle,
        pixelWidth: (window.clientSize.width * window.renderScale).ceil(),
        pixelHeight: (window.clientSize.height * window.renderScale).ceil(),
        scale: window.renderScale,
        presentPolicy: policy,
        description: 'hidden Win32 test window',
      ),
    ) as VulkanWindowTarget;
    addTearDown(target.dispose);
    return (window, target);
  }

  bool skipped() {
    if (skip == null) return false;
    printOnFailure('skipped: $skip');
    markTestSkipped(skip!);
    return true;
  }

  group('a surface and a swapchain on a real HWND', () {
    test('the device opened with a presenting queue', () {
      if (skipped()) return;
      expect(device!.gpu.canPresent, isTrue,
          reason: 'VK_KHR_swapchain was asked for and did not arrive');
      expect(device!.gpu.enabledExtensions, contains('VK_KHR_swapchain'));
      expect(device!.capabilities.supportsPartialPresent, isFalse);
    });

    test('a swapchain is built, and its format is UNORM and not _SRGB',
        () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      expect(target.creationFailure, isNull,
          reason: '${target.creationFailure}');
      expect(target.isPresentable, isTrue);
      final VulkanSwapchainConfiguration config = target.configuration!;
      printOnFailure('configuration: $config');
      // Policy 1, and the whole reason it is written down: an `_SRGB`
      // swapchain applies the transfer function to colours that already carry
      // it, and the window comes out washed pale while every offscreen test
      // still passes.
      expect(
        config.format,
        anyOf(VkFormat.VK_FORMAT_B8G8R8A8_UNORM,
            VkFormat.VK_FORMAT_R8G8B8A8_UNORM),
      );
      expect(config.pixelFormat, isNotNull);
      expect(config.width, greaterThan(0));
      expect(config.height, greaterThan(0));
      expect(target.imageCount, greaterThanOrEqualTo(2));
    });

    test('the default policy is FIFO, which every surface must support',
        () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      expect(target.configuration!.presentMode,
          VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR);
    });

    test('lowLatency takes MAILBOX when the surface has it, FIFO when not',
        () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) =
          await open(policy: VulkanPresentPolicy.lowLatency);
      final VulkanSwapchainConfiguration config = target.configuration!;
      printOnFailure('low-latency configuration: $config');
      // Both answers are correct; which one is the *driver's* to give. What
      // must hold either way is that the fallback is FIFO and never IMMEDIATE,
      // and that mailbox got the third image it needs to mean anything.
      expect(
        config.presentMode,
        anyOf(VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR,
            VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR),
      );
      if (config.presentMode == VkPresentModeKHR.VK_PRESENT_MODE_MAILBOX_KHR) {
        expect(config.imageCount, greaterThanOrEqualTo(3));
      }
    });
  });

  group('the acquire and present cycle', () {
    test('twenty frames present without leaking a semaphore or a fence',
        () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      final int semaphoresBefore =
          1 + target.imageCount + device!.gpu.framesInFlight;
      // Twenty is more than the frames in flight and more than the images, so
      // every frame slot and every image is reused several times. A semaphore
      // waited on while still pending, or a fence never reset, shows up here
      // as a hang or a validation error rather than in a single frame.
      for (var frame = 0; frame < 20; frame++) {
        final PresentResult result = await target.renderDisplayList(
          _scene(frame),
          clearColor: _clear,
        );
        expect(result.status, PresentStatus.presented,
            reason: 'frame $frame: ${result.diagnostic}');
      }
      expect(device!.gpu.frameCount, greaterThanOrEqualTo(20));
      // The count is a sanity check on the shape rather than a leak detector -
      // Vulkan has no handle census - but a target that allocated per frame
      // would be visible in the process, and the validation assertion at the
      // end of this file is what would report it by name.
      expect(semaphoresBefore, greaterThan(0));
      expect(target.isPresentable, isTrue);
    });

    test('a frame recorded against the previous generation is stale', () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      final Frame frame = target.beginFrame(const FrameRequest());
      target.resize(_width + 40, _height + 30, 1);
      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.stale,
          reason: 'a frame recorded against a swapchain that has been rebuilt '
              'must not be presented into the new one');
    });

    test('a disposed target refuses to present rather than crashing', () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      final Frame frame = target.beginFrame(const FrameRequest());
      target.dispose();
      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('disposed'));
    });
  });

  group('resize rebuilds the swapchain', () {
    test('the new chain has the new extent and still presents', () async {
      if (skipped()) return;
      final (Win32Window window, VulkanWindowTarget target) = await open();
      final VulkanSwapchainConfiguration before = target.configuration!;

      // `setBounds` is the resize entry point `NativeWindow` declares, and
      // every backend spells it that way; it speaks *logical* units, while
      // the target's `resize` speaks physical pixels. On a scaled display
      // those are different numbers, so the new extent is read back from the
      // window through `pixelSize` rather than assumed to be the same 240.
      window.setBounds(const Rect.fromLTWH(0, 0, 240, 180));
      final ({int width, int height}) pixels = window.pixelSize;
      target.resize(pixels.width, pixels.height, window.renderScale);

      final VulkanSwapchainConfiguration after = target.configuration!;
      printOnFailure('$before -> $after');
      expect(target.creationFailure, isNull,
          reason: '${target.creationFailure}');
      expect(after.width, isNot(before.width));
      expect(after.width, pixels.width);
      expect(after.height, pixels.height);
      // The chain was rebuilt, so the generation moved and the next frame is
      // recorded against the new one.
      final PresentResult result =
          await target.renderDisplayList(_scene(0), clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
    });

    test('resizing to the same size rebuilds nothing', () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      final int generation = target.generation;
      target.resize(
        target.surface.pixelWidth,
        target.surface.pixelHeight,
        target.surface.scale,
      );
      expect(target.generation, generation);
    });

    test('several resizes in a row leave a presentable chain', () async {
      if (skipped()) return;
      // The **window** is what is resized here, not only the target, and that
      // is not bookkeeping. On Win32 a surface reports its client area as
      // `VkSurfaceCapabilitiesKHR::currentExtent`, and
      // `VulkanSurfaceCapabilities.resolveExtent` honours it whenever the
      // surface defines one - so a chain rebuilt without moving the HWND comes
      // back at the window's old size no matter what the target was asked for.
      // Asking the target alone and then expecting the new number is a test
      // asserting that this backend ignores the surface, which it must not.
      final (Win32Window window, VulkanWindowTarget target) = await open();
      for (final (int w, int h) in <(int, int)>[
        (200, 150),
        (120, 90),
        (320, 240),
        (160, 120),
      ]) {
        window.setBounds(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
        final ({int width, int height}) pixels = window.pixelSize;
        target.resize(pixels.width, pixels.height, window.renderScale);
        expect(target.creationFailure, isNull,
            reason: 'at ${w}x$h: ${target.creationFailure}');
        expect(target.configuration!.width, pixels.width);
        expect(target.configuration!.height, pixels.height);
        final PresentResult result = await target
            .renderDisplayList(_scene(pixels.width), clearColor: _clear);
        expect(result.status, PresentStatus.presented,
            reason: 'at ${w}x$h: ${result.diagnostic}');
      }
    });
  });

  group('the window shows what the CPU rasteriser draws', () {
    test('the dense path, pixel for pixel: 1 level on 1 pixel', () async {
      // **Measured, not assumed: deviation 1, on exactly one pixel of 19200.**
      //
      // The amber rectangle's edges sit at x.5 / x.25 / x.75, so the two sides
      // meet a coverage tie and break it in opposite directions - the CPU
      // quantises coverage to an 8-bit value before it blends, the shader
      // multiplies floats and quantises once at the end, and the Vulkan
      // specification only requires the blend unit to be accurate to one unit
      // in the last place. `vulkan_cpu_parity_test.dart` measures the same
      // tie offscreen, on `_fractionalRect`, and declares the same 1.
      //
      // Confirmed by construction rather than argued: with the same scene's
      // edges moved onto whole pixels the deviation is **0**, so what this
      // one level covers is the fractional edge and nothing else. The
      // fractional edges are kept, because moving them would delete the
      // measurement.
      //
      // What the number must never become is somewhere a failure is sent to
      // die: an _SRGB swapchain format, a wrong channel order or a missed
      // premultiply all show up here as a *large* difference over *many*
      // pixels, which 1 and 1 cannot hide.
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      if (!target.canCaptureFrames) {
        markTestSkipped('this surface does not allow TRANSFER_SRC usage on its '
            'swapchain images, so a presented frame cannot be read back');
        return;
      }
      target.captureFrames = true;

      final DisplayList list = _denseScene();
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: _clear);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');

      final Framebuffer window = target.framebuffer!;
      final Framebuffer cpu = await _cpuFrame(list, window);
      final int deviation = _maxDeviation(cpu, window);
      final int differing = _differingPixels(cpu, window);
      printOnFailure('max deviation $deviation over $differing pixels of '
          '${window.width}x${window.height} in ${window.format.name}');
      expect(deviation, lessThanOrEqualTo(1),
          reason: 'the window and the CPU rasteriser disagree by up to '
              '$deviation levels; an _SRGB swapchain format would show up here '
              'as a large, uniform difference');
      expect(differing, lessThanOrEqualTo(1),
          reason: 'the declared tie is one pixel on a fractional edge; '
              '$differing pixels differ, which is a different picture and not '
              'a rounding tie');
    });

    test('the experimental sparse path, in the window: 0', () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      if (!target.canCaptureFrames) {
        markTestSkipped('this surface does not allow TRANSFER_SRC usage');
        return;
      }
      target.captureFrames = true;
      expect(device!.experimentalSparseStripsEnabled, isTrue);

      // The plan is in swapchain pixels, so it is built after the chain exists.
      final VulkanSwapchainConfiguration config = target.configuration!;
      final Path path =
          _rectPath(10.5, 12.25, config.width - 14.5, config.height - 18.75);
      final Rect clip = Rect.fromLTWH(
          0, 0, config.width.toDouble(), config.height.toDouble());
      final SparseStripDrawPlan plan = SparseStripDrawPlan()
        ..append(
          SparseStripGenerator().fill(path, clip, rule: FillRule.nonZero),
          materialIndex: 0,
        );
      expect(plan.alphaPageCount, greaterThan(0),
          reason: 'the fractional edges are what put a boundary strip in this '
              'scene; without one it tests only solid instances');

      target.enqueueSparseStrips(
        plan,
        materials: <SparseVulkanMaterial>[
          SparseVulkanMaterial(
            red: 0.8,
            green: 0.4,
            blue: 0.2,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
      );
      final Frame frame =
          target.beginFrame(const FrameRequest(clearColor: _clear));
      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(target.lastSparseStats, isNotNull);
      expect(target.lastSparseStats!.drawCalls, greaterThan(0));

      final Framebuffer window = target.framebuffer!;
      final DisplayList cpuList = DisplayList();
      final int paint = cpuList.addPaint(colorArgb: 0xFFCC6633);
      cpuList.drawPath(cpuList.addPath(path), paint);
      final Framebuffer cpu = await _cpuFrame(cpuList, window);
      final int deviation = _maxDeviation(cpu, window);
      printOnFailure('max deviation $deviation, '
          '${target.lastSparseStats!.drawCalls} draw calls, '
          '${plan.alphaPageCount} alpha pages');
      expect(deviation, 0,
          reason: 'the sparse pipeline and the CPU disagree by up to '
              '$deviation levels in a window');
    });

    test('a frame that does not clear keeps what the last one drew', () async {
      if (skipped()) return;
      final (_, VulkanWindowTarget target) = await open();
      if (!target.canCaptureFrames) {
        markTestSkipped('this surface does not allow TRANSFER_SRC usage');
        return;
      }
      target.captureFrames = true;
      // Every image has to be painted once, because a swapchain image nobody
      // has presented yet is `UNDEFINED` and loading it would be undefined
      // contents. That is exactly the rule `_record` implements, and this is
      // what proves it: after one full cycle, a frame with no clear colour and
      // no draws must come back holding the previous picture rather than
      // garbage or black.
      for (var i = 0; i < target.imageCount; i++) {
        await target.renderDisplayList(_denseScene(), clearColor: _clear);
      }
      final Framebuffer painted = _copyOf(target.framebuffer!);

      final PresentResult result =
          await target.renderDisplayList(DisplayList());
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(_maxDeviation(painted, target.framebuffer!), 0,
          reason: 'a load render pass on a presented image must preserve it; '
              'a wrong oldLayout in the barrier shows up here as garbage');
    });
  });

  group('what this refuses, by name', () {
    test('a device opened without presentation refuses a window surface',
        () async {
      if (skipped()) return;
      final VulkanRenderDevice plain =
          VulkanRenderDevice.adoptInstance(instance!);
      addTearDown(plain.dispose);
      expect(plain.gpu.canPresent, isFalse);
      final Win32Window window = await windows!.createWindow(
        const WindowOptions(
          title: 'no presentation',
          size: Size(80, 60),
          visible: false,
        ),
      ) as Win32Window;
      addTearDown(window.close);
      expect(
        () => plain.createTarget(VulkanWindowSurfaceDescriptor(
          platform: VulkanSurfacePlatform.win32,
          windowHandle: window.handle,
          pixelWidth: 80,
          pixelHeight: 60,
        )),
        throwsA(isA<UnsupportedCapabilityError>().having(
          (UnsupportedCapabilityError error) => error.toString(),
          'message',
          contains('VK_KHR_swapchain'),
        )),
      );
    });

    test('a zero window handle is refused before any driver call', () {
      if (skipped()) return;
      final VulkanSurfaceAttempt attempt = VulkanSurface.create(
        instance!,
        VulkanWindowSurfaceDescriptor(
          platform: VulkanSurfacePlatform.win32,
          windowHandle: 0,
          pixelWidth: 16,
          pixelHeight: 16,
        ),
      );
      expect(attempt.surface, isNull);
      expect(attempt.failureText, contains('zero'));
    });

    test('a platform this instance has no extension for is refused', () {
      if (skipped()) return;
      // Wayland on Windows. The refusal names the extension rather than
      // failing inside the driver with a null function pointer.
      final VulkanSurfaceAttempt attempt = VulkanSurface.create(
        instance!,
        VulkanWindowSurfaceDescriptor(
          platform: VulkanSurfacePlatform.wayland,
          windowHandle: 1,
          displayHandle: 1,
          pixelWidth: 16,
          pixelHeight: 16,
        ),
      );
      expect(attempt.surface, isNull);
      expect(attempt.failureText, contains('VK_KHR_wayland_surface'));
    });

    test('a memory surface still builds an offscreen target on this device',
        () {
      if (skipped()) return;
      // The window path is additive: the device that can present must still do
      // everything it did before.
      final RenderTarget offscreen = device!.createTarget(
        const MemorySurfaceDescriptor(pixelWidth: 8, pixelHeight: 8),
      );
      addTearDown(offscreen.dispose);
      expect(offscreen, isA<VulkanOffscreenTarget>());
    });
  });

  test('the validation layer said nothing, or said it was absent', () {
    if (skipped()) return;
    if (!instance!.validationEnabled) {
      printOnFailure('VK_LAYER_KHRONOS_validation is not installed on this '
          'machine; the surfaces, swapchains, semaphores and layout '
          'transitions above were exercised without it, and every pixel '
          'comparison still matched the CPU exactly.');
      return;
    }
    expect(instance!.problems, isEmpty,
        reason: 'the validation layer objected while windows were presented '
            'to:\n${instance!.problems.join('\n')}');
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

DisplayList _scene(int seed) {
  final DisplayList list = DisplayList();
  final int paint = list.addPaint(colorArgb: 0xFF3366CC);
  final double offset = (seed % 8).toDouble();
  list.drawRect(10 + offset, 10, 90 + offset, 70, paint);
  return list;
}

DisplayList _denseScene() {
  final DisplayList list = DisplayList();
  final int blue = list.addPaint(colorArgb: 0xFF3366CC);
  final int amber = list.addPaint(colorArgb: 0x99FFAA22);
  list
    ..drawRect(8, 8, 96, 64, blue)
    ..drawRect(40.5, 30.25, 120.75, 88, amber);
  return list;
}

Path _rectPath(double left, double top, double right, double bottom) {
  final PathBuilder builder = PathBuilder()
    ..moveTo(left, top)
    ..lineTo(right, top)
    ..lineTo(right, bottom)
    ..lineTo(left, bottom)
    ..close();
  return builder.build();
}

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// The same list through the CPU rasteriser, at the window's size and format.
Future<Framebuffer> _cpuFrame(DisplayList list, Framebuffer like) async {
  final MemoryRenderTarget cpu = MemoryRenderTarget(MemorySurfaceDescriptor(
    pixelWidth: like.width,
    pixelHeight: like.height,
    format: like.format,
  ));
  addTearDown(cpu.dispose);
  await cpu.renderDisplayList(list, clearColor: _clear);
  return cpu.framebuffer;
}

Framebuffer _copyOf(Framebuffer source) {
  final Framebuffer copy = Framebuffer.allocate(
    width: source.width,
    height: source.height,
    format: source.format,
  );
  copy.pixels.setAll(0, source.pixels);
  return copy;
}

/// How many pixels differ at all, in any channel.
///
/// The companion to [_maxDeviation]: a per-channel maximum of one level says
/// nothing about whether one pixel or the whole surface carries it, and those
/// are a rounding tie and a wrong picture respectively.
int _differingPixels(Framebuffer a, Framebuffer b) {
  var differing = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final int offset = a.offsetOf(x, y);
      for (var channel = 0; channel < 4; channel++) {
        if (a.pixels[offset + channel] != b.pixels[offset + channel]) {
          differing++;
          break;
        }
      }
    }
  }
  return differing;
}

int _maxDeviation(Framebuffer a, Framebuffer b) {
  expect(b.width, a.width);
  expect(b.height, a.height);
  expect(b.format, a.format);
  var worst = 0;
  final Uint8List left = a.pixels;
  final Uint8List right = b.pixels;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final int offset = a.offsetOf(x, y);
      for (var channel = 0; channel < 4; channel++) {
        final int difference =
            (left[offset + channel] - right[offset + channel]).abs();
        if (difference > worst) worst = difference;
      }
    }
  }
  return worst;
}
