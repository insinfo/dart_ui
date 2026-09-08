/// The frame pipeline's timeline: where a frame's milliseconds actually went.
///
/// Until this file existed, `grep -rn "dart:developer" lib/` found nothing.
/// The framework could report that a frame cost 79 ms - [FrameTiming] has
/// counted microseconds for a long time - and could not say *which part* of it
/// cost that, because the only split it recorded was "the settle loop" against
/// "the present". Section 68.4.2 of the roadmap carried an unexplained 79 ms
/// per video frame as an open question for exactly that reason: there was
/// nothing to look inside with.
///
/// ## Why a facade and not `Timeline.startSync` at the call sites
///
/// [Timeline.startSync] checks internally whether the Dart stream is enabled
/// and returns immediately when it is not - but **the arguments are evaluated
/// at the call site regardless**. A name built by interpolation, or an
/// `arguments` map, is therefore allocated on every frame of every release
/// build, whether or not anybody is recording. That is the same trap
/// `rendering/render_diagnostics.dart` was written to avoid, and the rule is the same
/// one: "costs nothing" has to mean *no allocation*, not *a branch per call
/// site*.
///
/// So this file enforces two things the raw API cannot:
///
///   * **the guard is a compile-time constant.** [kFrameTimelineEnabled] is
///     `false` in an AOT release build - `dart compile exe` - and on both web
///     compilers, and `true` under `dart run` and `dart test`. The compiler
///     constant-folds the `if` and drops the body, arguments and all. Measured
///     on this SDK (3.6.2), AOT, 20 million iterations: a bracketed loop and
///     the same loop without the bracket are **0.03 ns per pair** apart, which
///     is inside a noise band of about 0.4 ns. Compiled *in* with no recorder
///     attached the same pair costs **31 ns**, so the constant is doing real
///     work and is not decoration;
///   * **every name is a `const String`.** The [FramePhase] constants below
///     are the whole vocabulary of the per-frame instrumentation. There is no
///     overload here that takes an interpolated name or a `Map`, because the
///     one that existed would eventually be called from inside a loop.
///
/// ## Coarse phases are permanent; fine ones are not
///
/// The distinction matters enough to be stated rather than left to taste:
///
///   * the **coarse per-frame phases** - [FramePhase.frame], [build],
///     [layout], [paint], [present] and their immediate neighbours - are meant
///     to stay in the source forever. They are what the framework was missing,
///     and a per-frame constant-string bracket is affordable even when the
///     stream is live;
///   * **fine-grained instrumentation** - per widget, per draw call, anything
///     inside an inner loop - is temporary by nature. A `Timeline` event costs
///     on the order of a microsecond when the stream is recording, so ten
///     thousand of them per frame *change the number they are measuring*. Add
///     them to hunt something, then delete them. Nothing in this file is
///     fine-grained, and nothing fine-grained should be added to it.
///
/// ## Reading a trace
///
/// `tool/frame_timeline_trace.dart` drives a program under the VM Service,
/// pulls `getVMTimeline` and writes a Chrome Trace Event file that
/// `ui.perfetto.dev` opens directly. It also prints the phases sorted by total
/// and by self time, so a regression is visible without a browser.
///
/// **A trace is a JIT measurement.** `Timeline` needs a VM Service, an AOT
/// executable has none, and relative costs under the JIT are not the relative
/// costs of the shipped binary - `tool/startup_cost.dart` measures a 120x gap
/// on start alone. Any conclusion drawn from a trace has to be re-checked
/// against [FrameTiming], which is a `Stopwatch` and therefore works in both,
/// before it is written down as a fact.
library;

import 'dart:developer' show Timeline;

/// Whether the per-frame [Timeline] brackets are compiled in.
///
/// True exactly where a trace can be taken: a Dart VM (`dart.library.io`) that
/// is not a product build. That excludes two targets for two different
/// reasons.
///
/// **An AOT release build** has no VM Service, so the events would have no
/// reader. `dart.vm.product` is the VM's own constant for it - verified rather
/// than assumed on this SDK: the same source prints `false` from `dart run`
/// and `true` from a `dart compile exe` binary.
///
/// **A web build** is excluded on `dart.library.io` because `Timeline` under
/// `dart2js` is *not* the no-op it is easy to assume it is. Compiled with
/// `dart compile js` and run, `Timeline.startSync` reaches real JavaScript -
/// under `node` it fails with `ReferenceError: self is not defined`, which is
/// only a node artifact, but in a browser it would succeed and write to the
/// browser's own performance timeline on every frame, forever, for events
/// nothing in this repository can read back: `getVMTimeline` needs a VM
/// Service and a browser has none. So the web build pays and gets nothing,
/// which is the exact cost this file exists to refuse.
///
/// Override with `-Ddart_ui.frame_timeline=true` to keep the brackets in an
/// AOT build (a profile build attached to a service), or with `=false` to
/// strip them from a JIT run that is being timed for something else.
const bool kFrameTimelineEnabled = bool.fromEnvironment(
  'dart_ui.frame_timeline',
  defaultValue: bool.fromEnvironment('dart.library.io') &&
      !bool.fromEnvironment('dart.vm.product'),
);

/// The names a frame is divided into, as constants so no call site builds one.
///
/// Flat strings rather than an enum plus a lookup: [Timeline] wants a `String`
/// and an enum would need a `name` read - or worse, an interpolation - at
/// every call site to produce it.
abstract final class FramePhase {
  /// One whole `ApplicationWindow.drawFrame`, from entry to present returning.
  static const String frame = 'ui.frame';

  /// The same, for the synchronous live-resize path.
  static const String frameSync = 'ui.frame.sync';

  /// Mounting the root element, which happens once per window and not per
  /// frame. Bracketed anyway: a first frame that costs 300 ms is a question
  /// somebody asks, and this is the answer to it.
  static const String mountRoot = 'ui.mountRoot';

  /// The build/layout/paint settle loop, including every pass it takes.
  static const String settle = 'ui.settle';

  /// `BuildOwner.buildScope` - widgets rebuilt into elements.
  static const String build = 'ui.build';

  /// The scheduler's per-frame callbacks: animation ticks, and in the video
  /// player the playback state machine that decides present/drop/wait.
  static const String frameCallbacks = 'ui.frameCallbacks';

  /// `PipelineOwner.flushLayout`.
  static const String layout = 'ui.layout';

  /// `PipelineOwner.flushPaint` - the display list is recorded here.
  static const String paint = 'ui.paint';

  /// Acquiring the back buffer from the windowing backend.
  static const String beginFrame = 'ui.beginFrame';

  /// The 3D pass, when a window has mesh scenes queued.
  static const String meshScenes = 'ui.meshScenes';

  /// Handing the display list to the presenter: rasterization on a CPU path,
  /// replay plus swapchain present on a GPU one. Everything after the CPU half
  /// of the frame is over.
  static const String present = 'ui.present';

  /// Acquiring the render target's own frame, inside the present.
  static const String presentAcquire = 'ui.present.acquire';

  /// Replaying the display list into a GPU command stream and submitting it.
  /// The whole of a GPU present, including the swapchain, because a native
  /// target does not hand those back separately.
  static const String presentReplay = 'ui.present.replay';

  /// Rasterizing the display list into a CPU framebuffer.
  static const String presentRasterize = 'ui.present.rasterize';

  /// Handing the finished framebuffer to the platform - the blit and the
  /// swap. On a CPU path this is where a full-surface copy shows up.
  static const String presentSwap = 'ui.present.swap';

  /// Publishing the semantic tree, when something is reading it.
  static const String accessibility = 'ui.accessibility';
}

/// Opens a named phase. Pass a [FramePhase] constant - never an interpolation.
///
/// The whole call disappears in an AOT release build; see the library comment
/// for why that is a constant-folded `if` and not a runtime check.
void beginFramePhase(String name) {
  if (kFrameTimelineEnabled) Timeline.startSync(name);
}

/// Closes the phase opened by the matching [beginFramePhase].
///
/// Must be paired on every path, including the ones a throw takes, which is
/// why every call site in this framework wraps the body in `try`/`finally`.
void endFramePhase() {
  if (kFrameTimelineEnabled) Timeline.finishSync();
}
