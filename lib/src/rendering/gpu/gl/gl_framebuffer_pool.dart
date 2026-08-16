/// The pool of offscreen framebuffer objects layers are rendered into.
///
/// A layer needs a colour target for the length of a frame and then gives it
/// back (see `gpu_layer_stack.dart`). Creating one costs a `glGenFramebuffers`,
/// a `glGenTextures`, a `glTexImage2D` that allocates and zeroes video memory,
/// and a completeness check - tens of microseconds on a good driver and
/// occasionally a stall on a bad one, per layer per frame. An interface that
/// fades a dialog in over sixty frames would pay all of it sixty times for the
/// same rectangle, which is why this file exists.
///
/// ## The size policy, and why "exactly what was asked for" is the wrong one
///
/// The obvious pool - keep a list of framebuffers, hand back one whose size
/// matches - never hits. A fading panel is 300x180 on one frame and 301x181 on
/// the next because a layout animation moved a fraction of a pixel and the
/// bounds were snapped outward; a list is one pixel taller after each item is
/// added. Matching on the exact size means allocating a new target and
/// destroying an old one every single frame, which is worse than not pooling
/// at all: it adds the bookkeeping *and* the driver churn.
///
/// So a request is rounded up to a **size class**, and the class is the pool's
/// unit of reuse:
///
///   * up to 256 px, the next power of two, with a floor of 32;
///   * above 256 px, the next multiple of 256.
///
/// Per axis, independently. The two halves are chosen against two different
/// costs. Below 256 the absolute waste of a power of two is bounded by a few
/// hundred kilobytes and the *number of classes* is what matters: five classes
/// per axis means a screen full of chips, badges and buttons of assorted sizes
/// shares a handful of targets. Above 256 the relative waste is what matters:
/// rounding 1920 up to 2048 wastes 7%, while the next power of two after 1080
/// is 2048 and wastes 90% - a full-screen layer on a 1080p display would cost
/// four times its own memory. Blocks of 256 keep the waste under 25% at
/// 1024 px and under 7% at 4096 px while still giving only eight classes for a
/// 2048 px axis.
///
/// The cost of any rounding is stated rather than hidden: a layer renders into
/// the *top-left* corner of its target and samples only that much of it (see
/// [GpuLayer.u1]), so the rest is allocated, cleared and never read. That is
/// the price of a pool that hits.
///
/// ## The memory budget is declared, and exceeding it is an error by name
///
/// Two numbers, because "how much may sit idle" and "how much may exist" are
/// different questions:
///
///   * [maxIdleBytes] bounds what the pool *keeps*. Idle targets over the
///     budget are deleted oldest-first, so a frame that opened a dozen layers
///     once does not hold their memory forever.
///   * [maxTotalBytes] bounds what the pool has *created and not deleted* -
///     idle plus in flight. A frame that keeps asking is a frame with a
///     `saveLayer` in a loop, and the honest answer to it is
///     [GlFramebufferBudgetError] naming the budget, not an allocation that
///     eventually returns `GL_OUT_OF_MEMORY` and marks the device lost three
///     layers of abstraction from the cause.
///
/// Both are counted in *allocated* bytes - the rounded size, four bytes a
/// texel - because that is what the driver reserved, not what the layer used.
///
/// ## What this does not do, said plainly
///
///   * **No depth or stencil attachment.** This renderer has neither; a
///     future clip-by-path mask would need one, and adding it here means
///     adding it to the size class as well, because two targets of the same
///     size with different attachments are not interchangeable.
///   * **No multisampling.** Same answer `gl_backend.dart` gives for the
///     surface: the antialiasing is analytic.
///   * **No eviction by age.** An idle target costs memory and nothing else,
///     and a target that has not been used for a hundred frames is exactly as
///     likely to be the right size for the next layer as one used last frame.
///     Only the budget evicts.
library;

import 'dart:ffi';

import '../gpu_layer_stack.dart';
import 'gl_bindings.dart';

/// One offscreen colour target: a framebuffer object and its colour texture.
///
/// Implements [GpuLayerTarget] so the device-independent layer stack can hold
/// it without knowing that `id` is a GL framebuffer name and `textureId` is a
/// GL texture name.
final class GlFramebuffer implements GpuLayerTarget {
  GlFramebuffer({
    required this.id,
    required this.textureId,
    required this.width,
    required this.height,
  });

  /// The GL framebuffer object name. Never 0: 0 is the window's back buffer,
  /// and handing it out as a layer target would draw the layer straight onto
  /// the screen and then composite the screen onto itself.
  @override
  final int id;

  @override
  final int textureId;

  /// The allocated size, which is the size class - not what the layer asked
  /// for. See the library comment.
  @override
  final int width;

  @override
  final int height;

  /// Bytes the driver reserved for the colour texture, the unit both budgets
  /// are counted in.
  int get byteSize => width * height * 4;

  @override
  String toString() =>
      'GlFramebuffer(fbo $id, texture $textureId, ${width}x$height)';
}

/// Creates and destroys the GL objects behind a [GlFramebuffer].
///
/// An interface for one reason, and it is the same reason [GlyphMaskSource] is
/// one in `gpu_glyph_atlas.dart`: a test has to be able to *count*
/// allocations. "A pool reuses its buffers" is a claim about how many times
/// this interface was called, and there is no way to observe that through a
/// real driver without a GL debugger. A fake implementation in a test returns
/// three integers and counts.
abstract interface class GlFramebufferFactory {
  /// A complete framebuffer of exactly [width] by [height] texels, or null if
  /// the driver refused. Null rather than an exception because the pool turns
  /// it into a diagnostic that names the size that failed.
  GlFramebuffer? createFramebuffer(int width, int height);

  /// Deletes both GL objects. Called once per created framebuffer.
  void deleteFramebuffer(GlFramebuffer framebuffer);
}

/// Raised when the pool would exceed [GlFramebufferPool.maxTotalBytes].
///
/// Named, per section 6.6, and carrying the numbers rather than a sentence: a
/// caller looking at this wants to know whether it asked for one absurd layer
/// or a thousand reasonable ones, and the two are told apart by comparing the
/// requested size against the live total.
final class GlFramebufferBudgetError extends Error {
  GlFramebufferBudgetError({
    required this.requestedWidth,
    required this.requestedHeight,
    required this.liveBytes,
    required this.maxTotalBytes,
  });

  final int requestedWidth;
  final int requestedHeight;
  final int liveBytes;
  final int maxTotalBytes;

  @override
  String toString() =>
      'GlFramebufferBudgetError: opengl refuses a ${requestedWidth}x'
      '$requestedHeight layer target; the pool already holds '
      '${(liveBytes / (1024 * 1024)).toStringAsFixed(1)} MiB of a '
      '${(maxTotalBytes / (1024 * 1024)).toStringAsFixed(1)} MiB budget. '
      'Layer targets live until the end of the frame that used them, so this '
      'is a frame opening more layers than it can pay for rather than one '
      'impossible layer.';
}

/// Keeps offscreen colour targets alive between layers and between frames.
final class GlFramebufferPool implements GpuLayerTargetAllocator {
  GlFramebufferPool({
    required this.factory,
    this.maxIdleBytes = kDefaultMaxIdleBytes,
    this.maxTotalBytes = kDefaultMaxTotalBytes,
  }) : assert(maxIdleBytes <= maxTotalBytes);

  /// 32 MiB idle: two full-screen 1080p targets, or a couple of dozen of the
  /// panel-sized ones an interface actually opens. Enough that a steady-state
  /// animation never reallocates, small enough that a screen that stopped
  /// using layers gives the memory back within a frame.
  static const int kDefaultMaxIdleBytes = 32 * 1024 * 1024;

  /// 256 MiB total. Not a hardware limit - it is deliberately far below one -
  /// but the point at which "this frame is opening layers in a loop" is a
  /// safer conclusion than "this frame legitimately needs a quarter of a
  /// gigabyte of intermediate surfaces".
  static const int kDefaultMaxTotalBytes = 256 * 1024 * 1024;

  final GlFramebufferFactory factory;

  final int maxIdleBytes;
  final int maxTotalBytes;

  /// Idle targets, most recently released last. Deletion for the budget takes
  /// from the front, which is the least recently released - the one least
  /// likely to match the next request's size class.
  final List<GlFramebuffer> _idle = <GlFramebuffer>[];

  int _idleBytes = 0;
  int _liveBytes = 0;
  int _createCount = 0;
  int _reuseCount = 0;
  int _deleteCount = 0;

  /// Targets created since construction. The number a pooling test asserts:
  /// drawing the same layer on ten frames must leave this at one.
  int get createCount => _createCount;

  /// Acquisitions answered from the idle list.
  int get reuseCount => _reuseCount;

  /// Targets destroyed, by the budget or by [dispose].
  int get deleteCount => _deleteCount;

  /// Targets sitting idle right now.
  int get idleCount => _idle.length;

  /// Bytes held by idle targets, and by everything the pool has created and
  /// not deleted.
  int get idleBytes => _idleBytes;
  int get liveBytes => _liveBytes;

  /// The size class [size] falls into. See the library comment for the policy;
  /// exposed because a test that asserts reuse has to be able to say *why* two
  /// requests were expected to share a target.
  static int sizeClass(int size) {
    if (size <= 32) return 32;
    if (size <= 256) {
      var rounded = 32;
      while (rounded < size) {
        rounded *= 2;
      }
      return rounded;
    }
    return ((size + 255) ~/ 256) * 256;
  }

  @override
  GpuLayerTarget acquireLayerTarget(int width, int height) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('a layer target must have a positive size, got '
          '${width}x$height; an empty layer never reaches the allocator');
    }
    final int classWidth = sizeClass(width);
    final int classHeight = sizeClass(height);

    for (var i = _idle.length - 1; i >= 0; i--) {
      final GlFramebuffer candidate = _idle[i];
      if (candidate.width != classWidth || candidate.height != classHeight) {
        continue;
      }
      _idle.removeAt(i);
      _idleBytes -= candidate.byteSize;
      _reuseCount++;
      return candidate;
    }

    final int bytes = classWidth * classHeight * 4;
    if (_liveBytes + bytes > maxTotalBytes) {
      // Idle memory counts against the total, so the budget is given every
      // chance before it refuses: a pool holding the wrong size classes must
      // not stop a frame that is otherwise within its means.
      _trimTo(0);
    }
    if (_liveBytes + bytes > maxTotalBytes) {
      throw GlFramebufferBudgetError(
        requestedWidth: classWidth,
        requestedHeight: classHeight,
        liveBytes: _liveBytes,
        maxTotalBytes: maxTotalBytes,
      );
    }

    final GlFramebuffer? created =
        factory.createFramebuffer(classWidth, classHeight);
    if (created == null) {
      throw StateError('the GL driver refused a ${classWidth}x$classHeight '
          'layer target; a layer cannot be drawn correctly without one, and '
          'drawing it flattened would apply its opacity to nothing');
    }
    _createCount++;
    _liveBytes += created.byteSize;
    return created;
  }

  @override
  void releaseLayerTarget(GpuLayerTarget target) {
    if (target is! GlFramebuffer) {
      throw ArgumentError.value(
        target,
        'target',
        'this pool only takes back the GlFramebuffer objects it handed out; a '
            'foreign target means two allocators are wired to one layer stack',
      );
    }
    _idle.add(target);
    _idleBytes += target.byteSize;
    _trimTo(maxIdleBytes);
  }

  /// Deletes every idle target. The next layer of that size pays a creation.
  ///
  /// For a caller that knows the screen has stopped using layers - a window
  /// that lost focus, an app going to the background - and would rather have
  /// the memory back than the next frame's microseconds.
  void trim() => _trimTo(0);

  /// Deletes everything the pool holds. Targets still in flight are *not*
  /// tracked here, so this must run after the layer stack's `endFrame`.
  void dispose() => _trimTo(0);

  void _trimTo(int budget) {
    while (_idleBytes > budget && _idle.isNotEmpty) {
      final GlFramebuffer victim = _idle.removeAt(0);
      _idleBytes -= victim.byteSize;
      _liveBytes -= victim.byteSize;
      _deleteCount++;
      factory.deleteFramebuffer(victim);
    }
  }
}

/// The real factory: framebuffer objects on a live GL context.
///
/// Separate from [GlFramebufferPool] so the pool's arithmetic - size classes,
/// budgets, reuse - is testable without a driver, which is the same split
/// every other file in this directory makes.
///
/// It deliberately does **not** hold a `GlRenderDevice`: it needs four entry
/// points and a scratch pointer, and taking the device would make the pool
/// reachable from anything that can reach a device. The colour texture is
/// created here rather than through `GlRenderDevice.createTexture` because a
/// layer target's texture is not a [GpuTextureHandle] anybody outside this
/// file ever holds, and routing it through the device's allocator would make
/// the device's texture bookkeeping disagree with the pool's.
final class GlDeviceFramebufferFactory implements GlFramebufferFactory {
  GlDeviceFramebufferFactory({
    required this.gl,
    required this.scratchNames,
    this.makeCurrent,
    this.onError,
  });

  final GlApi gl;

  /// Makes the owning device's context current, because a target is created
  /// in the *middle* of a frame's walk - the first layer of a frame - and a GL
  /// call issued through a context that is not current does not fail, it
  /// creates the object in whichever context is. Null skips the check, which
  /// is only safe in a process with one context.
  final bool Function()? makeCurrent;

  /// Scratch native memory for `GLuint*` out-parameters, borrowed from the
  /// device so that creating a target performs no native allocation.
  final Pointer<Uint32> scratchNames;

  /// Called with a description when the driver refuses something, so the
  /// device can fold it into its own diagnostic. Null swallows it, which is
  /// only correct for a caller that checks the return value.
  final void Function(String what)? onError;

  @override
  GlFramebuffer? createFramebuffer(int width, int height) {
    if (makeCurrent != null && !makeCurrent!()) return null;
    gl.genTextures(1, scratchNames);
    final int texture = scratchNames[0];
    gl
      ..bindTexture(glTexture2D, texture)
      // Nearest, not linear. The composite draws the layer at exactly one
      // texel per pixel - the bounds were snapped to whole pixels precisely so
      // that would hold - and linear filtering there would resample the layer
      // through a half-texel offset and soften everything inside it.
      ..texParameteri(glTexture2D, glTextureMinFilter, glNearest)
      ..texParameteri(glTexture2D, glTextureMagFilter, glNearest)
      // Clamp, so the fringe of a quad that lands a hair past the edge repeats
      // the edge texel instead of wrapping the opposite side of the layer in.
      ..texParameteri(glTexture2D, glTextureWrapS, glClampToEdge)
      ..texParameteri(glTexture2D, glTextureWrapT, glClampToEdge)
      ..texImage2D(glTexture2D, 0, glRgba8, width, height, 0, glRgba,
          glUnsignedByte, nullptr);

    gl.genFramebuffers(1, scratchNames);
    final int framebuffer = scratchNames[0];
    gl
      ..bindFramebuffer(glFramebuffer, framebuffer)
      ..framebufferTexture2D(
          glFramebuffer, glColorAttachment0, glTexture2D, texture, 0);
    final int status = gl.checkFramebufferStatus(glFramebuffer);
    if (status != glFramebufferComplete) {
      onError?.call('a ${width}x$height layer framebuffer is incomplete: '
          'glCheckFramebufferStatus returned 0x${status.toRadixString(16)}');
      scratchNames[0] = framebuffer;
      gl.deleteFramebuffers(1, scratchNames);
      scratchNames[0] = texture;
      gl.deleteTextures(1, scratchNames);
      return null;
    }
    return GlFramebuffer(
      id: framebuffer,
      textureId: texture,
      width: width,
      height: height,
    );
  }

  @override
  void deleteFramebuffer(GlFramebuffer framebuffer) {
    // Deleting through a context that is not current deletes another
    // context's objects, which is worse than leaking these.
    if (makeCurrent != null && !makeCurrent!()) return;
    scratchNames[0] = framebuffer.id;
    gl.deleteFramebuffers(1, scratchNames);
    scratchNames[0] = framebuffer.textureId;
    gl.deleteTextures(1, scratchNames);
  }
}
