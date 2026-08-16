/// The renderer contracts of section 9.5, plus the capability report of 9.7.
///
/// The rule these encode: **a control never asks Direct3D or Metal anything.**
/// It asks [RendererCapabilities], which every backend answers in the same
/// vocabulary. That is what lets the same widget code run over a CPU
/// rasteriser in a test and over Metal on a laptop without a single
/// conditional mentioning either.
///
/// The split between backend, device and target mirrors what the platform APIs
/// actually are, rather than flattening them:
///
///   RendererBackend   the API is available on this machine (a DLL loaded,
///                     a driver answered). One per process.
///   RenderDevice      an open connection to a GPU or a CPU raster context.
///                     Devices are lost - a GPU reset, a driver update - and
///                     recreating one must not mean recreating the window.
///   RenderTarget      the pixels for one surface. Bound to a window and dies
///                     with it, while the device outlives both.
library;

import 'dart:async';

import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/rect.dart';
import 'framebuffer.dart';

/// What the caller wants to draw into.
///
/// Deliberately abstract: a Win32 `HWND`, an `IOSurface` id and an X11 shm
/// segment have nothing in common except that a renderer can be asked whether
/// it knows how to present to one. Backends downcast to their own subtype;
/// common code never does.
abstract interface class NativeSurfaceDescriptor {
  /// For diagnostics only - never branch on this. Branching on a name is how
  /// backend-specific assumptions get into common code.
  String get kind;

  int get pixelWidth;
  int get pixelHeight;

  /// Physical pixels per logical unit.
  double get scale;
}

/// A surface that is just memory. The headless backend presents to one, and so
/// does every golden test.
final class MemorySurfaceDescriptor implements NativeSurfaceDescriptor {
  const MemorySurfaceDescriptor({
    required this.pixelWidth,
    required this.pixelHeight,
    this.scale = 1.0,
    this.format = PixelFormat.bgra8888Premultiplied,
  });

  @override
  String get kind => 'memory';

  @override
  final int pixelWidth;

  @override
  final int pixelHeight;

  @override
  final double scale;

  final PixelFormat format;
}

/// Identity of a renderer, for logs and for the capability report.
final class RendererInfo {
  const RendererInfo({
    required this.name,
    required this.deviceDescription,
    this.driverVersion,
  });

  /// Stable identifier - `cpu`, `direct2d`, `metal`. Selection policy may match
  /// on this; rendering code may not.
  final String name;

  /// What the machine reported: an adapter string, a GPU model, or just
  /// `software`. Goes straight into bug reports.
  final String deviceDescription;

  final String? driverVersion;

  @override
  String toString() => driverVersion == null
      ? '$name ($deviceDescription)'
      : '$name ($deviceDescription, driver $driverVersion)';
}

/// The abstract questions a control is allowed to ask, from section 9.7.
final class RendererCapabilities {
  const RendererCapabilities({
    required this.supportsPartialPresent,
    required this.supportsMsaa,
    required this.supportsCompute,
    required this.supportsExternalTextures,
    required this.supportsLinearColor,
    required this.maxTextureSize,
    required this.formats,
  });

  /// Whether presenting only the damaged region is honoured. When false, damage
  /// tracking is still worth doing - it saves rasterisation - but the present
  /// itself costs a whole surface.
  final bool supportsPartialPresent;

  final bool supportsMsaa;
  final bool supportsCompute;
  final bool supportsExternalTextures;
  final bool supportsLinearColor;
  final int maxTextureSize;
  final Set<PixelFormat> formats;

  bool supportsFormat(PixelFormat format) => formats.contains(format);
}

/// One frame in progress on a [RenderTarget].
///
/// Holding a [Framebuffer] rather than an opaque handle is what makes the CPU
/// path and the golden tests the same code. A GPU backend maps its staging
/// buffer here, or refuses CPU access and reports it through capabilities.
final class Frame {
  Frame({
    required this.target,
    Framebuffer? framebuffer,
    required this.damage,
    required this.generation,
  }) : _framebuffer = framebuffer;

  final RenderTarget target;

  final Framebuffer? _framebuffer;

  /// The CPU-visible pixels of this frame, or null when there are none.
  ///
  /// ## Why this is nullable and [framebuffer] is not
  ///
  /// [Frame] was designed around the CPU rasteriser, where the framebuffer
  /// *is* the surface, and the field was non-nullable because on that path it
  /// always exists. A windowed GPU target has no such thing: the pixels are in
  /// a back buffer the driver owns and reading them back per frame is exactly
  /// what section 23 of the roadmap forbids. Both `GlWindowTarget` and
  /// `D3d11WindowTarget` therefore used to carry a 1x1 placeholder framebuffer
  /// that nothing ever read - a lie in the type that only their library
  /// comments corrected.
  ///
  /// The honest shape is this one: a target that has CPU pixels reports them,
  /// a target that does not reports null, and [framebuffer] stays as the
  /// non-null accessor for the callers that legitimately require them. A
  /// caller that reaches for [framebuffer] on a windowed GPU frame now gets a
  /// named [StateError] instead of one meaningless pixel.
  ///
  /// Valid for THIS frame only, whichever accessor is used. A backend that
  /// locks a shared surface gets a base address back from the lock, and there
  /// is no promise it is the same address as last time - a resize, a
  /// compositor decision, or a driver moving the buffer all change it.
  /// Anything that caches the pixel list or the stride (the CPU rasteriser
  /// does, on purpose, to keep it out of the inner loop) must therefore be
  /// built per frame, not once per target.
  Framebuffer? get cpuPixels => _framebuffer;

  /// Whether this frame has CPU-visible pixels at all.
  bool get hasCpuPixels => _framebuffer != null;

  /// The CPU-visible pixels, or a named failure when the target has none.
  ///
  /// Kept non-null so every existing CPU caller compiles and behaves exactly as
  /// before. Use [cpuPixels] when "this target draws straight to a screen" is a
  /// case you handle rather than a bug.
  Framebuffer get framebuffer {
    final Framebuffer? pixels = _framebuffer;
    if (pixels != null) return pixels;
    throw StateError(
      'this frame has no CPU-visible pixels: ${target.runtimeType} presents to '
      '${target.surface.kind} and its pixels never leave the GPU. Read '
      'Frame.cpuPixels and handle null, or render into a '
      'MemorySurfaceDescriptor target if the pixels are what you are after',
    );
  }

  /// The region the caller promised to redraw. A backend without partial
  /// present ignores it; one with it presents exactly this.
  final Rect damage;

  /// The target's lifetime this frame belongs to. A frame presented after its
  /// target was resized or lost must be rejected, not drawn.
  final int generation;
}

/// What the caller wants from [RenderTarget.beginFrame].
final class FrameRequest {
  const FrameRequest({
    this.damage,
    this.clearColor,
  });

  /// Null means "the whole surface is dirty".
  final Rect? damage;

  /// Premultiplied BGRA packed into a 32-bit int, or null to leave the
  /// previous contents. Leaving them is only safe when the backend preserves
  /// them, which [RendererCapabilities.supportsPartialPresent] implies.
  final int? clearColor;
}

enum PresentStatus {
  presented,

  /// The frame was dropped because it belonged to a previous generation. Not
  /// an error: it is what a resize during a frame looks like.
  stale,

  /// The device is gone - GPU reset, driver update, surface destroyed. The
  /// caller must recreate the device, not retry the frame.
  deviceLost,

  failed,
}

final class PresentResult {
  const PresentResult({required this.status, this.diagnostic});

  final PresentStatus status;

  /// Present when [status] is not [PresentStatus.presented]. Names what
  /// happened, per section 6.6 - a failed present that logs nothing is the
  /// hardest kind of rendering bug to chase.
  final BackendDiagnostic? diagnostic;

  bool get isSuccess => status == PresentStatus.presented;
}

/// The pixels of one surface.
abstract interface class RenderTarget implements Disposable {
  NativeSurfaceDescriptor get surface;

  /// Incremented by [resize] and by device loss. Frames carry it so a late
  /// present can be rejected instead of drawn into a buffer that moved.
  int get generation;

  Frame beginFrame(FrameRequest request);
  Future<PresentResult> present(Frame frame);

  void resize(int pixelWidth, int pixelHeight, double scale);
}

/// An open connection to whatever draws.
abstract interface class RenderDevice implements Disposable {
  RendererInfo get info;
  RendererCapabilities get capabilities;

  /// Whether the device is still usable. False after a GPU reset; the owner
  /// must build a new device, and the window survives.
  bool get isLost;

  RenderTarget createTarget(NativeSurfaceDescriptor surface);
}

// ---------------------------------------------------------------------------
// Renderer events - section 23.12
// ---------------------------------------------------------------------------

/// Something the renderer's owner has to know about, which is not an error.
///
/// ## Why these are events and not exceptions
///
/// Every member of this hierarchy describes a condition that a *correct*
/// program meets in normal operation: a driver update or a GPU reset produces
/// [DeviceLost], a window resize that has not been reconciled produces
/// [SurfaceOutOfDate], a machine under memory pressure produces [OutOfMemory].
/// None of them is a bug in the caller, and none of them is unrecoverable.
///
/// Throwing them would push the handling into a `try`/`catch` at every call
/// site, which is a promise the caller cannot keep: it will be written for the
/// present that is obviously fallible and forgotten for the texture upload
/// three layers down, and the day the GPU actually resets, the frame loop dies
/// with a stack trace instead of rebuilding a device. That is the exact failure
/// `gpu_device_state.dart` was written to prevent, and this hierarchy is the
/// same argument applied to the *reporting* side: the renderer says what
/// happened, on a channel, and the owner decides.
///
/// Sealed on purpose. A `switch` over these is exhaustive, so adding a member
/// later is a compile error at every handler rather than a case that silently
/// falls through to "ignore it".
sealed class RendererEvent {
  const RendererEvent({
    required this.backendName,
    required this.diagnostic,
  });

  /// Which backend is reporting. Named per section 6.6: an event that does not
  /// say who raised it is unactionable on a machine with two GPUs.
  final String backendName;

  /// What happened, in the vocabulary the probe and the present already use.
  final BackendDiagnostic diagnostic;

  /// A one-line form for a log. Subclasses add their own numbers.
  @override
  String toString() => '$runtimeType($backendName): $diagnostic';
}

/// The device is gone and every driver object it owned is invalid.
///
/// Emitted the moment the loss is *observed*, before any recovery is
/// attempted, so a log shows the cause and the time even when the recovery
/// then fails. [DeviceRecovered] or [DeviceRecoveryFailed] follows.
final class DeviceLost extends RendererEvent {
  const DeviceLost({
    required super.backendName,
    required super.diagnostic,
    required this.lossCount,
  });

  /// [GpuDeviceState.lossCount] at the moment of the loss - 1 for the first.
  /// A number that climbs on every frame is the signature of a device that is
  /// resetting in a loop, which is what the CPU fallback exists for.
  final int lossCount;

  @override
  String toString() => 'DeviceLost($backendName, loss #$lossCount): '
      '$diagnostic';
}

/// The device came back and every recreatable resource is in place again.
///
/// [needsFullRepaint] is always true and is a field rather than an implication
/// because forgetting it is invisible: the recovered surface holds whatever
/// the driver put in a freshly allocated buffer, and a caller that redraws
/// only its damage rectangle shows garbage everywhere else.
final class DeviceRecovered extends RendererEvent {
  const DeviceRecovered({
    required super.backendName,
    required super.diagnostic,
    required this.lossCount,
    required this.elapsed,
    this.unrecoverableResources = const <String>[],
  });

  final int lossCount;

  /// How long steps 1-5 of section 23.12 took. Recorded because a recovery
  /// that takes two seconds and one that takes eighty milliseconds are
  /// different products, and neither is visible from the pixels.
  final Duration elapsed;

  /// Resources that could not be put back, by name, because their Dart-side
  /// source no longer exists. Empty on a clean recovery.
  ///
  /// Non-empty does not mean the recovery failed: the device draws again. It
  /// means anything asking for one of these gets a named refusal instead of a
  /// wrong picture.
  final List<String> unrecoverableResources;

  bool get needsFullRepaint => true;

  @override
  String toString() => 'DeviceRecovered($backendName, loss #$lossCount, '
      '${elapsed.inMilliseconds}ms'
      '${unrecoverableResources.isEmpty ? '' : ', lost '
          '${unrecoverableResources.length} resource(s): '
          '${unrecoverableResources.join(', ')}'})';
}

/// A recovery attempt did not produce a usable device.
///
/// The device is still lost. The owner may try again - the coordinator will,
/// up to its policy's limit - or accept [RendererFellBackToCpu].
final class DeviceRecoveryFailed extends RendererEvent {
  const DeviceRecoveryFailed({
    required super.backendName,
    required super.diagnostic,
    required this.attempt,
    required this.step,
  });

  /// Which attempt this was, counting from 1.
  final int attempt;

  /// Which of the eight steps of section 23.12 refused, by name.
  final String step;

  @override
  String toString() =>
      'DeviceRecoveryFailed($backendName, attempt $attempt, at $step): '
      '$diagnostic';
}

/// The surface a target draws into no longer matches the window.
///
/// Distinct from [DeviceLost] because the fix is completely different and the
/// two produce the same [PresentStatus.stale] frames: this one is repaired by
/// calling [RenderTarget.resize] with the window's current size, and no device
/// is recreated. Reported so an owner can tell "my frames are being dropped
/// because I have not reconciled the resize" from "my frames are being dropped
/// because the device is gone".
final class SurfaceOutOfDate extends RendererEvent {
  const SurfaceOutOfDate({
    required super.backendName,
    required super.diagnostic,
    required this.generation,
    this.pixelWidth,
    this.pixelHeight,
  });

  /// The target generation that invalidated the frames.
  final int generation;

  /// The size the surface believes it is now, when the reporter knows it.
  /// Null when only the invalidation was observed, which is the usual case:
  /// the window system tells the platform layer, not the renderer.
  final int? pixelWidth;
  final int? pixelHeight;
}

/// An allocation the renderer needed was refused.
///
/// Separate from [DeviceLost] even though `GL_OUT_OF_MEMORY` also marks a GL
/// device lost: the *cause* is the caller's memory budget and the fix is to
/// draw less, which is a different action from recreating a device. The
/// resource is named because "out of memory" with no subject is the least
/// useful line a renderer can log.
final class OutOfMemory extends RendererEvent {
  const OutOfMemory({
    required super.backendName,
    required super.diagnostic,
    required this.resourceName,
    this.requestedBytes,
  });

  /// What could not be allocated - `layer target 512x512`, `image cache entry
  /// #7`. Names the instance, not the class.
  final String resourceName;

  /// How many bytes were asked for, when the caller knew. Null when the
  /// refusal came from the driver rather than from a budget this side counted.
  final int? requestedBytes;

  @override
  String toString() => 'OutOfMemory($backendName, $resourceName'
      '${requestedBytes == null ? '' : ', $requestedBytes bytes'}): '
      '$diagnostic';
}

/// The renderer stopped trying to recover the GPU and handed the frame loop
/// back to the CPU rasteriser.
///
/// Terminal for this device: nothing recreates it afterwards. See
/// `gpu_recovery.dart` for the policy, the count and what happens to the
/// content that was already drawn.
final class RendererFellBackToCpu extends RendererEvent {
  const RendererFellBackToCpu({
    required super.backendName,
    required super.diagnostic,
    required this.attempts,
    required this.window,
  });

  /// How many recovery attempts were made before giving up.
  final int attempts;

  /// The sliding window those attempts fell inside.
  final Duration window;

  @override
  String toString() => 'RendererFellBackToCpu($backendName, $attempts '
      'attempts in ${window.inSeconds}s): $diagnostic';
}

/// Where a renderer posts its [RendererEvent]s.
///
/// An interface with one method so a caller can pass a closure-backed sink, a
/// list that records everything for a test, or the fan-out
/// [RendererEventChannel] below, without any of them knowing about the others.
abstract interface class RendererEventSink {
  void emit(RendererEvent event);
}

/// A sink that hands each event to every listener, synchronously.
///
/// ## Why not a `Stream`
///
/// A broadcast `Stream` delivers on a microtask. The frame loop would have
/// already decided what to do with the present result - and, for a device
/// loss, already begun or skipped a recovery - by the time the listener ran,
/// so the event would arrive as history rather than as a decision point.
/// Recovery is the case this exists for, so delivery is synchronous and the
/// emitter blocks until every listener has seen it.
///
/// The cost of that choice is stated: a listener that blocks, blocks the
/// frame. Listeners are expected to log, set a flag, or schedule work - not to
/// do it inline. A listener that *throws* is contained rather than allowed to
/// abort a recovery half way through; the error is counted and kept in
/// [lastListenerError], because silently swallowing it would make a broken
/// handler invisible.
final class RendererEventChannel implements RendererEventSink {
  final List<void Function(RendererEvent)> _listeners =
      <void Function(RendererEvent)>[];

  /// Errors thrown by listeners, which are contained rather than propagated.
  int get listenerErrorCount => _listenerErrorCount;
  int _listenerErrorCount = 0;

  Object? get lastListenerError => _lastListenerError;
  Object? _lastListenerError;

  int get listenerCount => _listeners.length;

  /// Registers [onEvent] and returns the handle that removes it again.
  RendererEventSubscription listen(void Function(RendererEvent) onEvent) {
    _listeners.add(onEvent);
    return RendererEventSubscription._(this, onEvent);
  }

  @override
  void emit(RendererEvent event) {
    if (_listeners.isEmpty) return;
    // Over a copy: a listener that cancels itself - which a one-shot
    // "recreate my device" handler does - would otherwise mutate the list
    // being walked.
    for (final listener in List<void Function(RendererEvent)>.of(_listeners)) {
      try {
        listener(event);
      } on Object catch (error) {
        _listenerErrorCount++;
        _lastListenerError = error;
      }
    }
  }
}

/// The handle that undoes a [RendererEventChannel.listen].
final class RendererEventSubscription {
  RendererEventSubscription._(this._channel, this._listener);

  final RendererEventChannel _channel;
  final void Function(RendererEvent) _listener;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _channel._listeners.remove(_listener);
  }
}

/// A sink that keeps everything, for tests and for a crash report.
///
/// Bounded on purpose: a device resetting in a loop would otherwise grow this
/// without limit, which turns a rendering problem into an out-of-memory one.
final class RecordingRendererEventSink implements RendererEventSink {
  RecordingRendererEventSink({this.capacity = 256});

  final int capacity;
  final List<RendererEvent> _events = <RendererEvent>[];

  List<RendererEvent> get events => List<RendererEvent>.unmodifiable(_events);

  /// Every event of type [T], in order. The shape a test wants.
  List<T> ofType<T extends RendererEvent>() => _events.whereType<T>().toList();

  /// How many events were dropped because [capacity] was reached.
  int get droppedCount => _droppedCount;
  int _droppedCount = 0;

  @override
  void emit(RendererEvent event) {
    if (_events.length >= capacity) {
      _events.removeAt(0);
      _droppedCount++;
    }
    _events.add(event);
  }

  void clear() {
    _events.clear();
    _droppedCount = 0;
  }
}

/// The renderer API as a whole, on this machine.
abstract interface class RendererBackend {
  RendererInfo get info;

  /// Whether this backend can run here, and if not, exactly why. Never a bare
  /// bool: section 6.6 forbids choosing another backend without saying what
  /// was wrong with this one.
  BackendProbeResult probe();

  bool supportsSurface(NativeSurfaceDescriptor surface);

  Future<RenderDevice> createDevice();
}
