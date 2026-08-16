/// Device-loss recovery: the eight steps of section 23.12, orchestrated.
///
/// `gpu_device_state.dart` models loss as a *state* and gives it a
/// [GpuDeviceState.recover] that, until this file existed, nothing ever called.
/// This is the thing that calls it, and the reason calling it is not a
/// one-liner: `recover()` only flips a boolean, and flipping it before every
/// driver object has been rebuilt produces the worst outcome available - a
/// device that reports itself healthy and draws with texture names the driver
/// freed, which is undefined rather than an error.
///
/// ## The eight steps, and where each one lives
///
/// Section 23.12 lists them; this file's job is that they happen in that order
/// and that a failure at any of them is named rather than swallowed.
///
///   1. **stop submissions** - [GpuRecoveryHost.stopSubmissions]. Nothing may
///      be handed to a dead driver, including the tidy-up.
///   2. **preserve the logical scene** - nothing to do, and that is a property
///      of this framework rather than luck: the scene is a `DisplayList`, it
///      lives in Dart, and no step below touches it. It is listed anyway
///      because a renderer that kept its scene on the GPU would have to copy it
///      out here, and a reader has to be able to tell that this one does not.
///   3. **discard native resources** - [GpuRecoveryHost.discardNativeResources]
///      plus [GpuRecoverableResource.discardOnDeviceLoss] for every entry in
///      the inventory. Handles only: no driver call may be made.
///   4. **recreate device/surface** - [GpuRecoveryHost.recreateDevice].
///   5. **rebuild resources from Dart sources** -
///      [GpuRecoverableResource.repopulate], for the resources whose source
///      still exists. The ones whose source is gone are named, not guessed.
///   6. **repaint in full** - the coordinator does not draw; it reports
///      [DeviceRecovered.needsFullRepaint] and the owner redraws. A recovered
///      surface holds whatever the driver put in a fresh allocation, so a
///      damage-rectangle redraw would show garbage around it.
///   7. **record cause and time** - [GpuRecoveryReport] and the events.
///   8. **fall back to the CPU after repeated failure** - [GpuRecoveryPolicy],
///      and see "The loop" below.
///
/// ## The inventory: what can come back and what cannot
///
/// This is the part that has to be right, because getting it wrong is silent.
/// A GPU resource can only be recreated if its content still exists on the
/// Dart side, and the three answers are genuinely different:
///
///   * **Caches** ([GpuResourceRecovery.rebuilt]). The mask atlas is written
///     from scratch every frame; the glyph atlas is re-rasterised from font
///     outlines that live in Dart; a layer target holds one frame's
///     intermediate pixels. Throwing all three away and letting the next frame
///     refill them is not a compromise, it is the correct answer - the content
///     was derived, and the deriving inputs never left Dart.
///   * **Uploads whose bytes are still held**
///     ([GpuResourceRecovery.reuploaded]). An image texture whose source
///     `Framebuffer` the cache still references. Re-upload and the pixels are
///     identical by construction.
///   * **Uploads whose bytes are gone** ([GpuResourceRecovery.orphaned]). An
///     image whose source was dropped to save memory. There is no honest way
///     to bring it back, and the two dishonest ways are both worse than
///     failing: drawing the stale texture name is undefined output, and
///     drawing nothing is a picture missing an element with no error anywhere.
///     So the resource is named in [GpuRecoveryReport.unrecoverableResources]
///     and in [DeviceRecovered.unrecoverableResources], and the resolver that
///     owns it refuses it afterwards - which the raster sink turns into an
///     `UnsupportedCapabilityError` naming the backend and the image.
///
/// ## The loop
///
/// A GPU that resets once is a driver update. A GPU that resets on every
/// frame - a hardware fault, an overheating laptop, a driver that TDRs on this
/// particular shader - would put the frame loop in a recreate/lose cycle that
/// burns a core and never draws. [GpuRecoveryPolicy] bounds it: after
/// [GpuRecoveryPolicy.maxAttempts] attempts inside
/// [GpuRecoveryPolicy.window], the coordinator stops recreating, emits
/// [RendererFellBackToCpu] and refuses every later attempt. The decision is
/// terminal for that device on purpose - a coordinator that reset its own
/// counter would be back in the loop it just escaped.
library;

import '../../foundation/diagnostics.dart';
import '../renderer.dart';
import 'gpu_device_state.dart';

/// Where a GPU resource's content comes from after the device that held it
/// died.
enum GpuResourceRecovery {
  /// A cache. Discard it and let the next frame refill it from the Dart-side
  /// inputs that produced it in the first place.
  rebuilt,

  /// An upload whose source bytes are still held in Dart. Re-upload.
  reuploaded,

  /// A device object with no content of its own - a render target view, a
  /// framebuffer object, a swap chain. Recreated from its parameters.
  recreated,

  /// The source is gone. Nothing can bring this back, and the resource must
  /// refuse by name rather than draw.
  orphaned,
}

/// One thing the recovery has to put back.
///
/// Deliberately narrow: a resource is asked what kind of recovery it needs,
/// told to drop its handles, and told to come back. It is never asked to do
/// both at once, because step 3 must complete for *every* resource before
/// step 4 recreates the device - a resource that rebuilt itself eagerly would
/// be creating objects on a device that is still gone.
abstract interface class GpuRecoverableResource {
  /// Names this resource in diagnostics and in the failure when it cannot come
  /// back. Must identify the *instance* - `image cache entry 3 (64x64)`, not
  /// `image cache` - because "an image could not be restored" with no subject
  /// leaves the reader nothing to look for.
  String get resourceName;

  /// Which of the four answers this resource gives, asked at the moment
  /// recovery runs rather than fixed at construction: an image cache entry is
  /// [GpuResourceRecovery.reuploaded] until its source is dropped and
  /// [GpuResourceRecovery.orphaned] afterwards.
  GpuResourceRecovery get recovery;

  /// Forgets the driver objects, without calling the driver.
  ///
  /// Step 3. The names are integers pointing at memory the driver has already
  /// freed; deleting them is undefined, and on some drivers it is a second
  /// crash on top of the first.
  void discardOnDeviceLoss();

  /// Puts it back on the new device. Null on success; a diagnostic naming what
  /// refused on failure.
  ///
  /// Never called when [recovery] is [GpuResourceRecovery.orphaned]. Must not
  /// throw: a recovery that dies half way through leaves a device that is
  /// neither lost nor usable, which is the one state nothing above can handle.
  BackendDiagnostic? repopulate();
}

/// Whether an image cache keeps the pixels it uploaded.
///
/// The choice this enum exists to make explicit: a GPU texture can only be
/// rebuilt after a device loss if its bytes still exist somewhere in Dart, and
/// keeping them costs exactly the size of the image.
///
/// Device-independent on purpose, and here rather than in a backend: both
/// `GlImageCache` and `D3d11ImageCache` make the same trade, and putting the
/// enum in one of them would make the other import a graphics API it has
/// nothing to do with.
enum GpuImageSourceRetention {
  /// Keep a reference to the source `Framebuffer`, so the texture can be
  /// re-uploaded after a device loss.
  ///
  /// **The cost, stated.** `width * height * 4` bytes per cached image, held
  /// for the life of the cache, on top of the texture itself. A 4K photograph
  /// is 33 MB of Dart heap that the application may believe it released.
  ///
  /// This is the default, and choosing it is a smaller change than it looks:
  /// both caches used to be a `Map<Object, texture>.identity()` **keyed by the
  /// image**, so they already held every source alive for the same lifetime.
  /// The retention is not new; what is new is that it is now load-bearing and
  /// named, rather than an accident of the lookup structure.
  retain,

  /// Drop the reference as soon as the upload completes.
  ///
  /// The image can be collected by Dart as soon as the application drops it,
  /// which is the right answer for a decoder that hands over a large bitmap and
  /// never wants it again. The price is stated where it is paid: a device loss
  /// makes such a texture **unrecoverable**, the recovery names it in
  /// [DeviceRecovered.unrecoverableResources], and every later `resolve` of
  /// that image returns null - which `GpuRasterSink.drawDeviceImage` turns into
  /// an `UnsupportedCapabilityError` naming the backend and the image, rather
  /// than a frame with a missing element and no error anywhere.
  uploadOnly,
}

/// A [GpuRecoverableResource] built from two closures.
///
/// A backend's resources are fields of a target, not objects with a life of
/// their own: "the mask atlas texture and the sink that names it" is one
/// recovery unit and there is no class it could sensibly be. Writing a
/// four-method class per unit would put the discard and the rebuild in
/// different places from the field they act on, which is where they get out of
/// step.
///
/// [recoveryOf] is a callback rather than a value because the answer can change
/// between losses: an image cache entry is [GpuResourceRecovery.reuploaded]
/// until its source is dropped and [GpuResourceRecovery.orphaned] afterwards.
final class CallbackGpuResource implements GpuRecoverableResource {
  CallbackGpuResource({
    required this.resourceName,
    required GpuResourceRecovery Function() recoveryOf,
    required void Function() onDiscard,
    required BackendDiagnostic? Function() onRepopulate,
  })  : _recoveryOf = recoveryOf,
        _onDiscard = onDiscard,
        _onRepopulate = onRepopulate;

  /// The common case: a recovery kind that does not change.
  CallbackGpuResource.fixed({
    required String resourceName,
    required GpuResourceRecovery recovery,
    required void Function() onDiscard,
    required BackendDiagnostic? Function() onRepopulate,
  }) : this(
          resourceName: resourceName,
          recoveryOf: (() => recovery),
          onDiscard: onDiscard,
          onRepopulate: onRepopulate,
        );

  @override
  final String resourceName;

  final GpuResourceRecovery Function() _recoveryOf;
  final void Function() _onDiscard;
  final BackendDiagnostic? Function() _onRepopulate;

  @override
  GpuResourceRecovery get recovery => _recoveryOf();

  @override
  void discardOnDeviceLoss() => _onDiscard();

  @override
  BackendDiagnostic? repopulate() => _onRepopulate();

  @override
  String toString() => 'CallbackGpuResource($resourceName, ${recovery.name})';
}

/// The backend half of a recovery - the steps only a device can perform.
///
/// Implemented by `GlRenderDevice` and `D3d11RenderDevice`, and by a fake in
/// the tests. Everything else in this file is device-independent, which is what
/// lets the step order, the inventory and the fallback policy be tested on a
/// machine with no GPU at all.
abstract interface class GpuRecoveryHost {
  /// Named in every event and diagnostic this recovery produces.
  String get backendName;

  /// The loss state this host shares with its targets.
  GpuDeviceState get deviceState;

  /// Step 1. After this returns, nothing may be submitted until the device is
  /// back: an in-flight frame must present as [PresentStatus.deviceLost] or
  /// [PresentStatus.stale], never be drawn.
  void stopSubmissions();

  /// Step 3, the device's own half: shaders, pipeline state, buffers. The
  /// per-resource half is [GpuRecoverableResource.discardOnDeviceLoss].
  void discardNativeResources();

  /// Step 4. Returns null when a usable device and context exist again.
  ///
  /// Must clear [GpuDeviceState] itself - via [GpuDeviceState.recover] - only
  /// when it succeeded, and must leave the state lost when it did not.
  BackendDiagnostic? recreateDevice();

  /// Step 5's inventory, in the order the resources should be rebuilt.
  ///
  /// Read *after* [recreateDevice], so a host may return targets that only
  /// exist once the device does.
  Iterable<GpuRecoverableResource> recoverableResources();
}

/// When to stop trying and hand the frame loop to the CPU.
///
/// ## The numbers, and why these
///
/// [maxAttempts] is **3** and [window] is **10 seconds**. The criterion is a
/// sliding window: attempts older than [window] are forgotten, and the attempt
/// that would make the count exceed [maxAttempts] is refused instead of run.
/// So three losses inside ten seconds are all recovered from; a fourth inside
/// the same ten seconds falls back.
///
/// Three rather than one, because a single loss is the *common* case and is
/// always worth recovering: a driver update, a laptop waking from hibernation
/// and an external monitor being unplugged each produce exactly one, and a
/// renderer that gave up after one would drop to software for an event the
/// user did not even notice.
///
/// Three rather than ten, because every attempt costs a full device creation -
/// shader compilation, pipeline objects, every atlas re-uploaded - and a
/// machine that has lost its device three times in ten seconds is not going to
/// be fixed by a fourth. Ten attempts would mean several seconds of a frozen
/// window before the fallback the user was always going to get.
///
/// Ten seconds rather than "consecutive", because consecutive-failure counters
/// never fire on the case that matters: a GPU that resets once a minute for an
/// hour recovers cleanly every time, resets the counter every time, and the
/// application stutters forever. A window catches the loop and forgives the
/// isolated event.
///
/// ## What happens to the content already drawn
///
/// Nothing is carried across. The GPU's copy of the last presented frame died
/// with the device, the swap chain's back buffers are gone, and the layer
/// targets holding intermediate pixels were caches. What survives is the
/// *scene*, which was never on the GPU: the `DisplayList` and the render tree
/// that produced it are Dart objects. So the owner's obligation after
/// [RendererFellBackToCpu] is exactly the one after [DeviceRecovered] - repaint
/// in full, into a CPU target this time. There is no partial state to
/// reconcile, and that is a consequence of step 2 having nothing to do.
final class GpuRecoveryPolicy {
  const GpuRecoveryPolicy({
    this.maxAttempts = 3,
    this.window = const Duration(seconds: 10),
  }) : assert(maxAttempts > 0, 'a policy that never recovers is not a policy');
  // There is deliberately no assert on [window]. `Duration.inMicroseconds` is a
  // property access and `Duration ==` is an operator override, so neither is
  // constant-evaluable and both turn this constructor into a compile error the
  // moment anybody writes `const GpuRecoveryPolicy(...)`. A zero window is
  // harmless anyway: every attempt is pruned immediately, so the coordinator
  // never falls back, which is what [neverFallBack] asks for on purpose.

  /// How many recovery attempts may fall inside [window].
  final int maxAttempts;

  /// How long an attempt is remembered.
  final Duration window;

  /// Never falls back. For a test that wants the loop and not the escape, and
  /// for an embedder that has no CPU renderer to fall back to.
  static const GpuRecoveryPolicy neverFallBack =
      GpuRecoveryPolicy(maxAttempts: 1 << 30, window: Duration(days: 3650));
}

/// How a recovery ended.
enum GpuRecoveryStatus {
  /// The device was not lost, so nothing was done. Not a failure: a caller
  /// that recovers defensively on every `deviceLost` present will see this
  /// when two targets report the same loss.
  notLost,

  /// The device is back and every resource with a source is in place.
  recovered,

  /// The device is back, and at least one resource could not be restored
  /// because its Dart-side source is gone. See
  /// [GpuRecoveryReport.unrecoverableResources]; those are refused by name
  /// from now on.
  recoveredWithLosses,

  /// A step refused. The device is still lost and another attempt is allowed.
  failed,

  /// The policy's limit was reached. Terminal: this coordinator will not try
  /// again.
  fellBackToCpu,
}

/// What one recovery attempt did, for the log and for the caller's decision.
final class GpuRecoveryReport {
  const GpuRecoveryReport({
    required this.status,
    required this.backendName,
    required this.attempt,
    required this.elapsed,
    this.cause,
    this.failure,
    this.failedStep,
    this.unrecoverableResources = const <String>[],
    this.repopulatedCount = 0,
    this.discardedCount = 0,
  });

  final GpuRecoveryStatus status;
  final String backendName;

  /// Which attempt this was, counting from 1 over the coordinator's lifetime.
  final int attempt;

  /// Wall time spent in steps 1-5. Step 7 of section 23.12 asks for it.
  final Duration elapsed;

  /// Why the device was lost, straight from [GpuDeviceState.lossDiagnostic].
  /// Null only when [status] is [GpuRecoveryStatus.notLost].
  final BackendDiagnostic? cause;

  /// What refused, when [status] is [GpuRecoveryStatus.failed] or
  /// [GpuRecoveryStatus.fellBackToCpu].
  final BackendDiagnostic? failure;

  /// The step that refused, by the names section 23.12 uses.
  final String? failedStep;

  /// Resources that could not be put back, by name.
  final List<String> unrecoverableResources;

  final int repopulatedCount;
  final int discardedCount;

  bool get isRecovered =>
      status == GpuRecoveryStatus.recovered ||
      status == GpuRecoveryStatus.recoveredWithLosses;

  @override
  String toString() => 'GpuRecoveryReport($backendName, attempt $attempt, '
      '${status.name}, ${elapsed.inMilliseconds}ms, '
      'repopulated $repopulatedCount, discarded $discardedCount'
      '${unrecoverableResources.isEmpty ? '' : ', lost '
          '${unrecoverableResources.join(', ')}'}'
      '${failure == null ? '' : ', failed at $failedStep: $failure'})';
}

/// The names step 7 records, and the strings [GpuRecoveryReport.failedStep]
/// and [DeviceRecoveryFailed.step] carry. Kept as constants so a log and a
/// test agree on the spelling.
abstract final class GpuRecoveryStep {
  static const String stopSubmissions = 'stop submissions';
  static const String preserveScene = 'preserve the logical scene';
  static const String discardResources = 'discard native resources';
  static const String recreateDevice = 'recreate device and surface';
  static const String repopulateResources = 'rebuild resources from Dart';
  static const String repaint = 'repaint in full';
}

/// Runs the eight steps, bounds the loop, and says what happened.
///
/// One per device. Holding it per *target* would give each target its own
/// attempt counter, so a window with four targets would take four times as
/// long to reach the fallback - and each of them would try to recreate the
/// same device.
final class GpuRecoveryCoordinator {
  GpuRecoveryCoordinator({
    required GpuRecoveryHost host,
    RendererEventSink? events,
    this.policy = const GpuRecoveryPolicy(),
    DateTime Function()? clock,
  })  : _host = host,
        _events = events,
        _clock = clock ?? DateTime.now;

  final GpuRecoveryHost _host;
  final RendererEventSink? _events;
  final GpuRecoveryPolicy policy;

  /// Injectable so the loop test does not have to take ten real seconds, and
  /// so the window is exercised at its boundary rather than near it.
  final DateTime Function() _clock;

  final List<DateTime> _attemptTimes = <DateTime>[];
  int _attemptCount = 0;
  bool _fellBack = false;
  BackendDiagnostic? _fallbackReason;

  /// Every attempt ever made, including the refused one that fell back.
  int get attemptCount => _attemptCount;

  /// How many attempts are still inside the policy's window, at [_clock]'s
  /// idea of now. For a caller that wants to warn before the fallback.
  int get attemptsInWindow {
    _pruneAttempts(_clock());
    return _attemptTimes.length;
  }

  /// True once the policy gave up. Terminal.
  bool get hasFallenBackToCpu => _fellBack;

  /// Why, when it did. Null otherwise.
  BackendDiagnostic? get fallbackReason => _fallbackReason;

  /// Reports the loss that has just been observed, before any recovery.
  ///
  /// Split from [recover] because the two are not the same moment: a present
  /// that returns [PresentStatus.deviceLost] should say so on the channel
  /// immediately, while the decision to recover may be the frame loop's and may
  /// come later. Idempotent per loss - calling it twice for one
  /// [GpuDeviceState.lossCount] emits one event - so every target sharing a
  /// device may call it without producing one event per target.
  bool reportLoss() {
    final GpuDeviceState state = _host.deviceState;
    final BackendDiagnostic? cause = state.lossDiagnostic;
    if (cause == null) return false;
    if (state.lossCount == _reportedLossCount) return false;
    _reportedLossCount = state.lossCount;
    _events?.emit(DeviceLost(
      backendName: _host.backendName,
      diagnostic: cause,
      lossCount: state.lossCount,
    ));
    return true;
  }

  int _reportedLossCount = 0;

  /// Runs one recovery attempt.
  ///
  /// Never throws, including when a host or a resource does: an exception
  /// escaping here would unwind through the frame loop and leave the device in
  /// the one state nothing above can handle - neither lost nor usable. A throw
  /// becomes [GpuRecoveryStatus.failed] with the error as the diagnostic's
  /// detail.
  GpuRecoveryReport recover() {
    final GpuDeviceState state = _host.deviceState;
    if (_fellBack) {
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.fellBackToCpu,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: Duration.zero,
        cause: state.lossDiagnostic,
        failure: _fallbackReason,
        failedStep: GpuRecoveryStep.recreateDevice,
      );
    }

    final BackendDiagnostic? cause = state.lossDiagnostic;
    if (cause == null) {
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.notLost,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: Duration.zero,
      );
    }

    // The loss is reported even when the caller never called reportLoss, so a
    // log always shows the cause before it shows the outcome.
    reportLoss();

    final DateTime now = _clock();
    _pruneAttempts(now);
    if (_attemptTimes.length >= policy.maxAttempts) {
      return _fallBack(cause);
    }
    _attemptTimes.add(now);
    _attemptCount++;

    final Stopwatch watch = Stopwatch()..start();
    try {
      return _runSteps(cause, watch);
    } on Object catch (error, stack) {
      // A host that throws is a bug in the host, and it must not become a bug
      // in the frame loop. The device stays lost, so the next attempt is
      // allowed and the policy still bounds it.
      final BackendDiagnostic failure = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the recovery threw, which is a bug in the backend it was '
            'driving; the device is left lost',
        detail: '$error\n$stack',
      );
      if (!state.isLost) state.markLost(failure);
      _events?.emit(DeviceRecoveryFailed(
        backendName: _host.backendName,
        diagnostic: failure,
        attempt: _attemptCount,
        step: GpuRecoveryStep.recreateDevice,
      ));
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.failed,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: watch.elapsed,
        cause: cause,
        failure: failure,
        failedStep: GpuRecoveryStep.recreateDevice,
      );
    }
  }

  GpuRecoveryReport _runSteps(BackendDiagnostic cause, Stopwatch watch) {
    final GpuDeviceState state = _host.deviceState;

    // Step 1.
    _host.stopSubmissions();

    // Step 2 is a no-op here and the library comment says why.

    // Step 3. The device's own objects first, then the inventory's, and both
    // before anything is created: a resource that recreated itself while the
    // device was still gone would be creating objects on a dead driver.
    var discarded = 0;
    final List<GpuRecoverableResource> before =
        _host.recoverableResources().toList(growable: false);
    _host.discardNativeResources();
    for (final GpuRecoverableResource resource in before) {
      resource.discardOnDeviceLoss();
      discarded++;
    }

    // Step 4.
    final BackendDiagnostic? refused = _host.recreateDevice();
    if (refused != null) {
      // The host is required to leave the state lost when it fails; this
      // enforces it rather than trusting it, because a host that recovered the
      // state and then failed would leave a device reporting itself healthy.
      if (!state.isLost) state.markLost(refused);
      _events?.emit(DeviceRecoveryFailed(
        backendName: _host.backendName,
        diagnostic: refused,
        attempt: _attemptCount,
        step: GpuRecoveryStep.recreateDevice,
      ));
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.failed,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: watch.elapsed,
        cause: cause,
        failure: refused,
        failedStep: GpuRecoveryStep.recreateDevice,
        discardedCount: discarded,
      );
    }
    if (state.isLost) {
      // The other half of the same contract: a host that returns null has
      // claimed success, and a state still marked lost would make every
      // present below answer deviceLost forever.
      final BackendDiagnostic inconsistent = BackendDiagnostic(
        kind: DiagnosticKind.connectionFailed,
        message: 'the backend reported a successful device recreation and left '
            'the device marked lost',
        detail: 'GpuRecoveryHost.recreateDevice must call '
            'GpuDeviceState.recover() when it succeeds; ${_host.backendName} '
            'did not, and the loss it left is: ${state.lossDiagnostic}',
      );
      _events?.emit(DeviceRecoveryFailed(
        backendName: _host.backendName,
        diagnostic: inconsistent,
        attempt: _attemptCount,
        step: GpuRecoveryStep.recreateDevice,
      ));
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.failed,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: watch.elapsed,
        cause: cause,
        failure: inconsistent,
        failedStep: GpuRecoveryStep.recreateDevice,
        discardedCount: discarded,
      );
    }

    // Step 5. The inventory is read again, because a host whose targets were
    // rebuilt by step 4 has different resources now.
    var repopulated = 0;
    final List<String> orphans = <String>[];
    for (final GpuRecoverableResource resource
        in _host.recoverableResources()) {
      if (resource.recovery == GpuResourceRecovery.orphaned) {
        orphans.add(resource.resourceName);
        continue;
      }
      final BackendDiagnostic? failure = resource.repopulate();
      if (failure == null) {
        repopulated++;
        continue;
      }
      // A resource that refuses is a lost device again, not a partial one: it
      // was created on the new device and the new device would not take it.
      if (!state.isLost) state.markLost(failure);
      _events?.emit(DeviceRecoveryFailed(
        backendName: _host.backendName,
        diagnostic: failure,
        attempt: _attemptCount,
        step: GpuRecoveryStep.repopulateResources,
      ));
      return GpuRecoveryReport(
        status: GpuRecoveryStatus.failed,
        backendName: _host.backendName,
        attempt: _attemptCount,
        elapsed: watch.elapsed,
        cause: cause,
        failure: failure,
        failedStep: GpuRecoveryStep.repopulateResources,
        unrecoverableResources: List<String>.unmodifiable(orphans),
        repopulatedCount: repopulated,
        discardedCount: discarded,
      );
    }

    watch.stop();
    // Steps 6 and 7: the owner repaints, and this is the record.
    _events?.emit(DeviceRecovered(
      backendName: _host.backendName,
      diagnostic: cause,
      lossCount: state.lossCount,
      elapsed: watch.elapsed,
      unrecoverableResources: List<String>.unmodifiable(orphans),
    ));
    return GpuRecoveryReport(
      status: orphans.isEmpty
          ? GpuRecoveryStatus.recovered
          : GpuRecoveryStatus.recoveredWithLosses,
      backendName: _host.backendName,
      attempt: _attemptCount,
      elapsed: watch.elapsed,
      cause: cause,
      unrecoverableResources: List<String>.unmodifiable(orphans),
      repopulatedCount: repopulated,
      discardedCount: discarded,
    );
  }

  /// Step 8. Terminal, and the device is deliberately left lost: every present
  /// from here answers [PresentStatus.deviceLost], which is what makes the
  /// owner switch to the CPU renderer instead of quietly showing a frozen
  /// window.
  GpuRecoveryReport _fallBack(BackendDiagnostic cause) {
    _fellBack = true;
    _fallbackReason = BackendDiagnostic(
      kind: DiagnosticKind.incompatibleDevice,
      message: 'the GPU device was lost ${_attemptTimes.length + 1} times in '
          '${policy.window.inSeconds}s, so the renderer stopped recreating it',
      detail: 'the policy allows ${policy.maxAttempts} recovery attempts '
          'inside ${policy.window.inSeconds}s; the last cause was '
          '"${cause.message}". Nothing on the GPU survives - the scene does, '
          'because it is a DisplayList in Dart - so the owner must repaint in '
          'full into a CPU target',
    );
    _events?.emit(RendererFellBackToCpu(
      backendName: _host.backendName,
      diagnostic: _fallbackReason!,
      attempts: _attemptTimes.length,
      window: policy.window,
    ));
    return GpuRecoveryReport(
      status: GpuRecoveryStatus.fellBackToCpu,
      backendName: _host.backendName,
      attempt: _attemptCount,
      elapsed: Duration.zero,
      cause: cause,
      failure: _fallbackReason,
      failedStep: GpuRecoveryStep.recreateDevice,
    );
  }

  void _pruneAttempts(DateTime now) {
    final DateTime cutoff = now.subtract(policy.window);
    while (_attemptTimes.isNotEmpty && _attemptTimes.first.isBefore(cutoff)) {
      _attemptTimes.removeAt(0);
    }
  }
}
