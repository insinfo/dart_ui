/// The budgets, the quality trade and the kill switches, in one value.
///
/// The renderer decides per draw and it decides well - the measurements in
/// `doc/architecture/ACELERACAO_GPU_VETORIAL.md` are what that claim rests on.
/// What it had no way to hear was anything the *application* knows: how much
/// texture memory this machine can spare, whether this program would rather
/// have an exact edge or a faster frame, and - when a shape comes out wrong on
/// one customer's driver - which route to take away in order to find out which
/// one is lying.
///
/// Three deliberate non-goals, because each of them was the obvious first
/// design and each is wrong:
///
///   * **This is not "choose your renderer".** There is no `useSparse` or
///     `useStencil`. The right route differs *within one frame*: a video
///     editor has static chrome and an animating canvas on screen at the same
///     time, so any global mode is the wrong answer for half the window. The
///     switches here only ever take a route *away*, and taking one away always
///     leaves the parity route - the dense analytic atlas - underneath.
///   * **This is not where a subtree speaks.** Per-subtree advice is
///     `ContentHint` and it is declared in the widget tree, because it is a
///     property of the content and not of the process.
///   * **No knob that does nothing.** Every field below names what it changes
///     and where it is read. Where the reading end is still a seam, the field's
///     comment says so by name rather than implying an effect it does not yet
///     have.
library;

import '../foundation/diagnostics.dart';
import '../graphics/content_hint.dart';
import 'gpu/gpu_path_strategy.dart';
import 'render_diagnostics.dart';

/// What to do when edge quality and throughput disagree.
///
/// The trade is real and measured. Every route in this renderer that starts
/// from the shared analytic coverage - the CPU rasteriser, the dense mask
/// atlas, the sparse strip encoder - deviates from the reference by **0**.
/// Stencil-then-cover does not: it is masked by a stencil test, which is
/// binary, so its only antialiasing is MSAA, and N samples express N+1
/// coverage values against a continuous truth. Measured on an off-grid fringe
/// against the CPU: **42 levels at 4 samples, 18 at 16**, over 636 edge pixels
/// of a 25 600 pixel scene, interior exact.
///
/// That is the entire content of this enum. It is not a general "quality"
/// slider and there is nothing else behind it, because there is nothing else
/// in the renderer that trades one for the other.
enum RenderQualityPreference {
  /// Never accept a route whose edge is quantised.
  ///
  /// Removes stencil-then-cover outright. The cost is real and one-directional:
  /// a large uncached shape that would have gone to the cover pass is
  /// rasterised on the CPU and uploaded as an area-proportional mask instead,
  /// every frame it is not cached.
  ///
  /// **Known limit, stated rather than hidden:** tessellated meshes are also
  /// MSAA-resolved when they are drawn antialiased, and that case is gated by
  /// the backend per render pass - it can see whether the pass is
  /// multisampled and this policy cannot. `exact` therefore removes the route
  /// whose deviation was measured and does not claim to remove one it cannot
  /// see. Turning [GpuStrategySwitches.tessellation] off as well is the
  /// complete answer, at the cost of the aliased case, where B is exact.
  exact,

  /// The measured defaults. Stencil-then-cover is selected only where it was
  /// shown to pay: an uncached mask at or above
  /// [RenderPolicy.stencilThresholdFor], on a pass that really has a stencil
  /// attachment and at least four samples.
  balanced,

  /// Reach for the cover pass sooner on large shapes.
  ///
  /// Lowers the uncached-mask threshold from 16 KiB (a 128x128 shape) to
  /// 4 KiB (64x64). The upper number is where the alpha8 upload stops being
  /// noise on the integrated GPU this was measured on; the lower one is
  /// roughly where the cover pass's two fixed extra passes stop dominating,
  /// so between them the choice is a preference and not a fact - which is
  /// exactly what this enum is for. What it buys is the CPU rasterisation and
  /// the per-frame upload of every large uncached shape; what it costs is up
  /// to 18 levels on those shapes' fringes.
  speed,
}

/// Individually disable a general-path route, for diagnosis.
///
/// These exist to bisect a rendering bug on a machine you do not have. A shape
/// comes out wrong on one driver; turning sparse off and seeing it come right
/// names the route in one run, where reading five backends' worth of code
/// names it in a week.
///
/// Two properties make them worth shipping rather than keeping in a debug
/// build. They are **safe**: every one of them falls back to the dense
/// analytic atlas, which is the parity route, so a disabled switch can cost
/// frame time and cannot produce a wrong picture. And they are
/// **observable**: [RenderPolicy.restrict] records each one it applies into
/// the frame diagnostics and [RenderPolicy.describe] emits it as a
/// [BackendDiagnostic] with [DiagnosticKind.rejectedByPolicy], so a support
/// log says which routes were off. A silent kill switch would turn one
/// mystery into two.
///
/// The dense atlas and analytic primitives have no switch on purpose: the
/// first is the fallback everything else recovers to, and the second is
/// closed-form shader coverage that no other route can be cheaper than.
final class GpuStrategySwitches {
  const GpuStrategySwitches({
    this.sparseStrips = true,
    this.tessellation = true,
    this.stencilThenCover = true,
    this.computeTiles = true,
  });

  /// Nothing disabled - the default, and what production runs.
  static const GpuStrategySwitches all = GpuStrategySwitches();

  /// Every optional route off: only analytic primitives and the dense atlas
  /// remain. The far end of a bisection, and a useful baseline for a bug
  /// report.
  static const GpuStrategySwitches denseOnly = GpuStrategySwitches(
    sparseStrips: false,
    tessellation: false,
    stencilThenCover: false,
    computeTiles: false,
  );

  final bool sparseStrips;
  final bool tessellation;
  final bool stencilThenCover;
  final bool computeTiles;

  bool get allEnabled =>
      sparseStrips && tessellation && stencilThenCover && computeTiles;

  /// False only for a route this object switched off. Strategies with no
  /// switch answer true.
  bool isEnabled(GpuPathStrategy strategy) => switch (strategy) {
        GpuPathStrategy.analyticPrimitive ||
        GpuPathStrategy.coverageAtlas =>
          true,
        GpuPathStrategy.sparseStrips => sparseStrips,
        GpuPathStrategy.tessellatedMesh => tessellation,
        GpuPathStrategy.stencilThenCover => stencilThenCover,
        GpuPathStrategy.computeTiles => computeTiles,
      };

  /// The routes that are off, in enum order. Empty for [all].
  Iterable<GpuPathStrategy> get disabled =>
      GpuPathStrategy.values.where((GpuPathStrategy s) => !isEnabled(s));

  GpuStrategySwitches copyWith({
    bool? sparseStrips,
    bool? tessellation,
    bool? stencilThenCover,
    bool? computeTiles,
  }) =>
      GpuStrategySwitches(
        sparseStrips: sparseStrips ?? this.sparseStrips,
        tessellation: tessellation ?? this.tessellation,
        stencilThenCover: stencilThenCover ?? this.stencilThenCover,
        computeTiles: computeTiles ?? this.computeTiles,
      );

  @override
  bool operator ==(Object other) =>
      other is GpuStrategySwitches &&
      other.sparseStrips == sparseStrips &&
      other.tessellation == tessellation &&
      other.stencilThenCover == stencilThenCover &&
      other.computeTiles == computeTiles;

  @override
  int get hashCode =>
      Object.hash(sparseStrips, tessellation, stencilThenCover, computeTiles);

  @override
  String toString() => allEnabled
      ? 'GpuStrategySwitches.all'
      : 'GpuStrategySwitches(off: '
          '${disabled.map((GpuPathStrategy s) => s.name).join(', ')})';
}

/// The reason string a kill switch records. One constant so the frame
/// diagnostics, the [BackendDiagnostic] and a test all say the same thing.
const String kStrategyDisabledByPolicy = 'disabled by RenderPolicy kill switch';

/// The reason [RenderQualityPreference.exact] records for the cover pass.
const String kStencilRefusedForQuality =
    'RenderQualityPreference.exact excludes MSAA cover: 18 levels of deviation '
    'at 16 samples, 42 at 4';

/// Who rasterises the inside of a glyph.
///
/// The framework owns its whole text stack - shaping, OpenType, hinting
/// policy, the rasteriser - so that one document lays out and draws the same
/// on every platform. That is a promise, and this enum is the one place an
/// application is allowed to break it, deliberately and for one reason.
///
/// **What this never moves.** Shaping, metrics, line breaking and glyph
/// placement stay in Dart under every value below. A widget is the same size,
/// a hit test lands on the same character and a line breaks in the same place
/// on Windows, Linux, macOS and the web. Only the pixels *inside* a glyph can
/// change.
enum GlyphRasterization {
  /// This framework's rasteriser, everywhere. The default.
  ///
  /// One document, one set of pixels, on every platform and in every backend.
  /// The CPU renderer, OpenGL, Direct3D and Direct2D all draw the coverage
  /// `GlyphCache` produced, and their parity against each other is measured at
  /// deviation 0 wherever they share it.
  portable,

  /// Let the platform rasterise glyph bodies where it can.
  ///
  /// Today exactly one backend reads this: **Direct2D on Windows**, which
  /// draws a run this framework already shaped through
  /// `ID2D1RenderTarget::DrawGlyphRun` so Windows applies its own hinting and
  /// ClearType. Every other backend and every other platform ignores it and
  /// draws the portable way; the field is declared here rather than in a
  /// Windows-only corner because an application declares it once, and a policy
  /// that moved depending on where the program ran would be worse than one
  /// that is inert.
  ///
  /// **Turning this on has consequences, and they are the point of the
  /// option, not a defect:**
  ///
  ///   * text on Windows stops matching text on other platforms pixel for
  ///     pixel, and golden images that contain text become Windows-specific;
  ///   * a run whose font is not installed on the machine, or whose installed
  ///     copy numbers its glyphs differently from the bytes the application
  ///     loaded, is drawn the portable way instead - the backend refuses by
  ///     name rather than drawing correctly spaced nonsense;
  ///   * ClearType is not guaranteed. Direct2D falls back to greyscale of its
  ///     own accord under a rotation, into a layer and wherever the target is
  ///     transparent, so the same option produces subpixel text in some places
  ///     on the same screen and greyscale in others.
  ///
  /// `doc/architecture/TEXTO_DIRECT2D.md` states what was measured and why the
  /// default is [portable].
  platformNative,
}

/// Budgets and policy the application declares once, for the whole process.
///
/// Immutable and comparable, so it can be a `const` in an
/// `ApplicationOptions` and so a test can assert two policies are the same
/// policy.
final class RenderPolicy {
  const RenderPolicy({
    this.maskAtlasByteBudget = kDefaultMaskAtlasByteBudget,
    this.quality = RenderQualityPreference.balanced,
    this.strategies = GpuStrategySwitches.all,
    this.diagnostics = RenderDiagnosticsMode.off,
    this.glyphRasterization = GlyphRasterization.portable,
  }) : assert(maskAtlasByteBudget > 0);

  /// Everything at its measured default: today's behaviour exactly.
  static const RenderPolicy defaults = RenderPolicy();

  /// Bytes the dense mask atlas may hold.
  ///
  /// **Default 1 MiB, and it is not a guess:** the atlas is alpha8 and its
  /// existing default page is 1024 x 1024, so 1 MiB is the size the renderer
  /// already runs at. Declaring it here changes nothing by itself and gives
  /// the number a name.
  ///
  /// Observable effect: [maskAtlasSide], and through it the page
  /// `GpuMaskAtlas.forPolicy` allocates. A larger budget holds more shapes
  /// resident, so a UI with many distinct icons evicts and re-rasterises less
  /// - the atlas reports `evictions` and `compactions` and both should fall.
  /// A smaller one is the right answer on a memory-constrained target and
  /// costs re-rasterisation.
  ///
  /// The atlas is square and a power of two, so the budget is rounded *down*
  /// to the largest such page that fits: 1 MiB and 1.9 MiB both give 1024.
  /// Rounding down rather than to the nearest keeps the field a ceiling, which
  /// is the only reading that makes it a budget.
  final int maskAtlasByteBudget;

  /// See [RenderQualityPreference]. Default [RenderQualityPreference.balanced]
  /// - the measured behaviour, unchanged.
  final RenderQualityPreference quality;

  /// See [GpuStrategySwitches]. Default: nothing disabled.
  final GpuStrategySwitches strategies;

  /// See [RenderDiagnosticsMode]. Default [RenderDiagnosticsMode.off], because
  /// it is the only value that can be proved to cost nothing.
  final RenderDiagnosticsMode diagnostics;

  /// See [GlyphRasterization]. Default [GlyphRasterization.portable] - one
  /// document, one set of pixels, on every platform.
  ///
  /// Read by `d2d_raster_sink.dart` and by nothing else today. It is not a
  /// performance knob: the portable route on Direct2D was measured *faster*
  /// than the native one is expected to be, and the reason to turn this on is
  /// that the application wants Windows' own look.
  final GlyphRasterization glyphRasterization;

  /// 1 MiB: one 1024 x 1024 alpha8 page, which is `GpuMaskAtlas`'s own
  /// default.
  static const int kDefaultMaskAtlasByteBudget = 1 << 20;

  /// Smallest page this will produce, whatever the budget says.
  ///
  /// A 128 x 128 shape is the size at which the stencil route starts being
  /// considered, so a page smaller than twice that could not hold two of them
  /// beside each other and would thrash on any real interface. Below this the
  /// budget is not a smaller cache, it is no cache.
  static const int kMinimumMaskAtlasSide = 256;

  /// Largest page this will produce.
  ///
  /// 4096 is the texture size every GL 3.3 / ES 3.0 implementation is required
  /// to support. Going past the guaranteed minimum would turn a budget into a
  /// device-dependent failure at allocation time.
  static const int kMaximumMaskAtlasSide = 4096;

  /// The square page side [maskAtlasByteBudget] buys, a power of two, clamped
  /// to [kMinimumMaskAtlasSide]..[kMaximumMaskAtlasSide].
  int get maskAtlasSide {
    var side = kMinimumMaskAtlasSide;
    while (side < kMaximumMaskAtlasSide &&
        (side * 2) * (side * 2) <= maskAtlasByteBudget) {
      side *= 2;
    }
    return side;
  }

  /// Uncached dense-mask bytes above which the cover pass is preferred, for
  /// this [quality]. See [RenderQualityPreference].
  int get stencilThresholdFor => switch (quality) {
        // Unreachable in practice - `exact` removes the route in [restrict] -
        // but the number has to be defined for every value of the enum, and
        // the largest one is the safest thing for it to be.
        RenderQualityPreference.exact => 1 << 30,
        RenderQualityPreference.balanced => 16384,
        RenderQualityPreference.speed => 4096,
      };

  /// The selector this policy asks for.
  ///
  /// Everything except the stencil threshold stays at the value the
  /// measurements set, because nothing else in the selector is a preference:
  /// `sparseCrossingCostInDensePixels` is an exchange rate between two units
  /// of work, not a knob, and its own comment says how to re-derive it.
  GpuPathStrategySelector buildSelector() => GpuPathStrategySelector(
      stencilMinimumDenseMaskBytes: stencilThresholdFor);

  /// [device] with everything this policy forbids taken out.
  ///
  /// This is the **only** way a policy reaches the selector, and it is
  /// subtractive by construction: it can turn a capability off and it has no
  /// expression for turning one on. A policy therefore cannot ask a backend to
  /// execute something it did not report, which is the failure mode a
  /// "choose your renderer" option would have.
  ///
  /// Every subtraction is recorded into [diagnostics] with a named reason, so
  /// the frame report says why a route is missing rather than leaving its
  /// absence to be explained.
  GpuPathStrategyCapabilities restrict(
    GpuPathStrategyCapabilities device, {
    RenderDiagnosticsRecorder diagnostics = RenderDiagnosticsRecorder.disabled,
  }) {
    var sparse = device.sparseStrips;
    var tessellation = device.tessellation;
    var stencil = device.stencil;
    var compute = device.compute;

    if (sparse && !strategies.sparseStrips) {
      sparse = false;
      diagnostics.recordRefusal(
        GpuPathStrategy.sparseStrips,
        kStrategyDisabledByPolicy,
      );
    }
    if (tessellation && !strategies.tessellation) {
      tessellation = false;
      diagnostics.recordRefusal(
        GpuPathStrategy.tessellatedMesh,
        kStrategyDisabledByPolicy,
      );
    }
    if (compute && !strategies.computeTiles) {
      compute = false;
      diagnostics.recordRefusal(
        GpuPathStrategy.computeTiles,
        kStrategyDisabledByPolicy,
      );
    }
    if (stencil && !strategies.stencilThenCover) {
      stencil = false;
      diagnostics.recordRefusal(
        GpuPathStrategy.stencilThenCover,
        kStrategyDisabledByPolicy,
      );
    } else if (stencil && quality == RenderQualityPreference.exact) {
      stencil = false;
      diagnostics.recordRefusal(
        GpuPathStrategy.stencilThenCover,
        kStencilRefusedForQuality,
      );
    }

    return GpuPathStrategyCapabilities(
      analyticPrimitives: device.analyticPrimitives,
      coverageAtlas: device.coverageAtlas,
      sparseStrips: sparse,
      tessellation: tessellation,
      stencil: stencil,
      compute: compute,
    );
  }

  /// [workload] adjusted by what the application said about the subtree.
  ///
  /// A forwarder, kept because it is the name the seam was documented under.
  /// The rule itself is [GpuPathWorkload.withContentHint], which lives on the
  /// workload for a mechanical reason: applying a hint means copying every
  /// field of that class, and a copy written out here would silently drop any
  /// cost fact added there later. It is also where the selector reads it -
  /// see [GpuPathStrategySelector.select], which takes the hint directly and
  /// owns the precedence rule.
  static GpuPathWorkload applyContentHint(
    GpuPathWorkload workload,
    ContentHint hint,
  ) =>
      workload.withContentHint(hint);

  /// The quality actually in force for a subtree: the hint if it declared one,
  /// this policy otherwise.
  RenderQualityPreference qualityFor(ContentHint hint) =>
      switch (hint.quality) {
        RenderQualityHint.unspecified => quality,
        RenderQualityHint.preferQuality => RenderQualityPreference.exact,
        RenderQualityHint.preferSpeed => RenderQualityPreference.speed,
      };

  /// This policy as evidence, in the form the framework already reports.
  ///
  /// Emitted once at [Application.start] through `ApplicationOptions
  /// .onDiagnostic`, beside the backend probes, so a support log that already
  /// says which GPU was chosen also says which routes were taken away and why.
  /// Everything at its default produces an empty list: a policy that changed
  /// nothing has nothing to report, and a log full of "still the default" is a
  /// log nobody reads.
  List<BackendDiagnostic> describe() {
    final List<BackendDiagnostic> out = <BackendDiagnostic>[];
    for (final GpuPathStrategy strategy in strategies.disabled) {
      out.add(BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'GPU path strategy ${strategy.name} is disabled',
        detail: kStrategyDisabledByPolicy,
      ));
    }
    if (quality == RenderQualityPreference.exact &&
        strategies.stencilThenCover) {
      out.add(const BackendDiagnostic(
        kind: DiagnosticKind.rejectedByPolicy,
        message: 'GPU path strategy stencilThenCover is disabled',
        detail: kStencilRefusedForQuality,
      ));
    }
    if (quality == RenderQualityPreference.speed) {
      out.add(BackendDiagnostic.note(
        'stencil-then-cover threshold lowered to $stencilThresholdFor bytes',
        detail: 'RenderQualityPreference.speed trades up to 18 levels of edge '
            'deviation on large uncached shapes for the CPU raster and upload '
            'they would otherwise cost every frame',
      ));
    }
    if (maskAtlasByteBudget != kDefaultMaskAtlasByteBudget) {
      out.add(BackendDiagnostic.note(
        'mask atlas budget $maskAtlasByteBudget bytes '
        '(${maskAtlasSide}x$maskAtlasSide page)',
      ));
    }
    if (diagnostics != RenderDiagnosticsMode.off) {
      out.add(BackendDiagnostic.note(
        'render diagnostics enabled: ${diagnostics.name}',
      ));
    }
    return out;
  }

  RenderPolicy copyWith({
    int? maskAtlasByteBudget,
    RenderQualityPreference? quality,
    GpuStrategySwitches? strategies,
    RenderDiagnosticsMode? diagnostics,
  }) =>
      RenderPolicy(
        maskAtlasByteBudget: maskAtlasByteBudget ?? this.maskAtlasByteBudget,
        quality: quality ?? this.quality,
        strategies: strategies ?? this.strategies,
        diagnostics: diagnostics ?? this.diagnostics,
      );

  @override
  bool operator ==(Object other) =>
      other is RenderPolicy &&
      other.maskAtlasByteBudget == maskAtlasByteBudget &&
      other.quality == quality &&
      other.strategies == strategies &&
      other.diagnostics == diagnostics &&
      other.glyphRasterization == glyphRasterization;

  @override
  int get hashCode => Object.hash(maskAtlasByteBudget, quality, strategies,
      diagnostics, glyphRasterization);

  @override
  String toString() => 'RenderPolicy(${maskAtlasByteBudget}B atlas, '
      '${quality.name}, $strategies, diagnostics: ${diagnostics.name}, '
      'glyphs: ${glyphRasterization.name})';
}

/// Where a GPU backend finds the policy the application declared.
///
/// ## Where it is read, and why that is one place
///
/// `GpuPathPlanningTelemetry` reads it - once, in its constructor - and every
/// GPU backend in this repository builds one: the OpenGL vector replay, the
/// Direct3D 12 targets and the Vulkan ordered recorder all hand their
/// per-draw capabilities to it and take its decision. So [restrict] is
/// applied at the single point where what the *device* can execute meets what
/// the *selector* is allowed to choose, and [buildSelector] supplies the
/// selector that meets it there:
///
/// ```dart
/// final GpuPathStrategyCapabilities capabilities = policy.restrict(
///   capabilitiesProbe?.call(traits) ?? candidateCapabilities,
///   diagnostics: diagnostics,
/// );
/// ```
///
/// That is deliberately not repeated per backend. Three copies of one line is
/// three chances for a backend to forget it, and a kill switch that works on
/// two backends out of three is worse than none - it makes a bisection lie.
/// A backend added later gets the switches and the quality trade without
/// knowing they exist.
///
/// The workload half is wired at the same point and reads the same way:
/// `GpuPathStrategySelector.select` takes the [ContentHint] directly, because
/// the precedence rule - what a hint may and may not overrule - belongs beside
/// the branches it is ordered against.
///
/// ## Why this is a scope and not a parameter
///
/// It should be a parameter, and one day it will be. What stops it is the
/// distance: nothing between `Application.start` and a planner constructed
/// deep inside a backend's target has any other reason to carry a policy, so
/// the parameter would be threaded through five backends' constructors to be
/// read in one place. `GpuPathPlanningTelemetry` does take one - it is the
/// `policy:` argument, and a test passes it - so the scope is the default and
/// not the only way in, which is the shape that makes the eventual parameter
/// a change of default rather than a change of design.
///
/// Process-wide rather than per-window because a policy is a property of the
/// program - a memory budget and a bisection are not per-window decisions -
/// and because a per-window value would have to be found from inside a device
/// that does not know which window it is presenting.
final class RenderPolicyScope {
  const RenderPolicyScope._();

  static RenderPolicy _policy = RenderPolicy.defaults;
  static RenderDiagnosticsRecorder _diagnostics =
      RenderDiagnosticsRecorder.disabled;

  /// The declared policy, or [RenderPolicy.defaults] when nothing installed
  /// one. Never null, so a reader needs no fallback of its own.
  static RenderPolicy get policy => _policy;

  /// The recorder [policy] asked for. [RenderDiagnosticsRecorder.disabled]
  /// unless the policy turned diagnostics on, so an unconfigured process pays
  /// nothing.
  static RenderDiagnosticsRecorder get diagnostics => _diagnostics;

  /// Installs [value] and the recorder it implies.
  ///
  /// Called by `Application.start`. Idempotent, and safe to call from a test
  /// as long as [reset] follows - which is why [reset] exists rather than the
  /// setter being the whole API.
  static void install(RenderPolicy value) {
    _policy = value;
    _diagnostics = RenderDiagnosticsRecorder.forMode(value.diagnostics);
  }

  /// Back to the defaults. A test that installs must reset, or it configures
  /// every test that runs after it in the same isolate.
  static void reset() {
    _policy = RenderPolicy.defaults;
    _diagnostics = RenderDiagnosticsRecorder.disabled;
  }
}
