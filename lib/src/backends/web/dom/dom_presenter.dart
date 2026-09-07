/// A third web presentation path: HTML elements instead of pixels.
///
/// ## What this trades, and why the trade is worth making
///
/// A canvas is a picture. Everything the browser gives an interface for free -
/// find-in-page, text selection, a screen reader, keyboard focus that follows
/// the DOM, view-source, a crawler, zoom that the compositor does rather than
/// the application - is lost the moment the interface is painted rather than
/// expressed. This presenter gives all of that back and gives up fine control
/// over pixels: it can express solid boxes, rounded corners, clips, affine
/// transforms, group opacity, images and text, and it refuses arbitrary paths,
/// gradients and blend modes **by name**, counting every refusal. See
/// [DomCanvasPresenter.refusals].
///
/// It is also the path that works where WebGL is blocked, disabled by policy,
/// or absent - which is why it is registered last rather than not at all.
///
/// ## How it sits over the window
///
/// `WebWindow` is a wrapper around one `<canvas>`, and the canvas is where the
/// framework's input listeners live: `dom_input_translation.dart` turns DOM
/// events into framework events there, and the render tree does the hit
/// testing. This presenter therefore does **not** replace the canvas. It builds
/// its tree in a sibling element positioned exactly over it, with
/// `pointer-events: none` on every node it creates, so that the pointer falls
/// straight through to the canvas and the application behaves identically to
/// the GPU paths. The keyboard is the exception and it is the point: `tabindex`
/// needs no pointer, so the semantics layer can offer real focus without taking
/// any input away. See [DomPointerPolicy] for the one policy that changes this
/// and what it costs.
///
/// The canvas keeps its size and its listeners and is given a transparent
/// backing store it never draws into. Hiding it would be tidier and would also
/// stop every pointer event in the application, which is the bug this
/// arrangement exists to not have.
///
/// ## Device loss
///
/// There is none. A DOM tree is not a device: it is not lost on a GPU reset,
/// there is nothing to recreate, and [isDeviceLost] answers false always.
/// [recoverFromDeviceLoss] answers true for the same reason - a caller that
/// asked has nothing to recover from, and answering false would make a page
/// tear itself down over an event that did not affect it.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../../app/window_host.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list.dart';
import '../../../platform/native_window.dart';
import '../../../rendering/renderer.dart';
import '../../../semantics/semantics.dart';
import '../web_window.dart';
import 'dom_scene.dart';
import 'dom_semantics_layer.dart';

/// Where the presenter gets the semantic tree from.
///
/// A callback rather than a tree, for the reason `AccessibilityTreeSource`
/// gives: the render root is replaced when the tree is remounted, and a source
/// captured once would publish a detached tree for the rest of the process.
///
/// The embedder supplies `() => application.buildOwner.buildSemantics()`. It is
/// not taken automatically because `Application` only registers an
/// `AccessibilityHost` for a `NativeHandleWindow`, and a page has no native
/// handle - see `dom_semantics_layer.dart`.
typedef DomSemanticsSource = SemanticsSnapshot Function();

/// Presents a display list as a DOM tree.
final class DomCanvasPresenter
    with DisposableMixin
    implements SurfacePresenter {
  DomCanvasPresenter._(
    this._host,
    this._sceneRoot,
    this._semanticsRoot,
    this._scene,
    this._semantics,
    this._ownsHost,
  );

  /// The name this path is registered and reported under.
  static const String backendName = 'web-dom';

  /// Always supported, and the honest answer.
  ///
  /// Every other presentation path in this repository probes something that can
  /// say no - a WebGL2 context, a WebGPU adapter, a D3D device. This one needs a
  /// `document` and nothing else, so a probe that could fail would be theatre.
  /// It is still a real probe rather than a constant `true`: a page compiled to
  /// run in a worker has no document, and returning a named rejection there is
  /// the difference between "the DOM path was not used" and a blank page.
  static BackendProbeResult probe() {
    final web.Element? body = web.document.body;
    if (body == null) {
      return BackendProbeResult.unsupported(
        backendName,
        const BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'there is no document body to build a DOM tree in',
          detail: 'this context has a global scope but no document, which is '
              'what a worker or a detached realm looks like',
        ),
      );
    }
    return BackendProbeResult(
      backendName: backendName,
      supported: true,
      capabilities: const <Capability>{
        Capability.cpuPresentation,
        Capability.keyboardInput,
        Capability.pointerInput,
        Capability.scrollInput,
      },
      diagnostics: const <BackendDiagnostic>[
        BackendDiagnostic.note(
          'presentation as HTML elements rather than pixels',
          detail: 'selectable text, find-in-page, screen readers and real '
              'keyboard focus; arbitrary paths, gradients and blend modes are '
              'refused by name and counted',
        ),
      ],
    );
  }

  /// Builds a DOM layer over the canvas [window] owns.
  ///
  /// Throws [BackendSelectionError] when the window is not a [WebWindow] or its
  /// canvas is not in a document, because that is the shape
  /// `PresentationPathEntry.attach` is called in and the selection machinery
  /// above turns the error into a report naming every candidate. The failure is
  /// real rather than defensive: a headless window offers a memory surface and
  /// no element, and a presenter that carried on would build a tree nobody can
  /// see.
  static Future<DomCanvasPresenter> attach(
    NativeWindow window, {
    DomPointerPolicy pointerPolicy = DomPointerPolicy.passThrough,
  }) async {
    if (window is! WebWindow) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            backendName,
            BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: 'the DOM path needs a window backed by an element and '
                  'this one is a ${window.runtimeType}',
              detail: 'offered: '
                  '${window.surfaces.map(
                        (NativeSurfaceDescriptor s) => s.kind,
                      ).join(', ')}',
            ),
          ),
        ],
      );
    }
    final web.Element? parent = window.canvas.parentElement;
    if (parent == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            backendName,
            const BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: 'the window\'s canvas is not in a document, so there is '
                  'nowhere to put a DOM tree beside it',
            ),
          ),
        ],
      );
    }
    // `position: relative` on the parent and not on the host, because the host
    // is what has to be positioned *against* the parent. Set only when the
    // parent is still statically positioned, so a page that laid its own
    // container out is not overridden.
    // `isA` rather than `is`: `package:web` types are extension types, so a
    // Dart `is` between two of them is a compile-time-true no-op that checks
    // nothing at runtime. This has to be a real `instanceof`, because a parent
    // that is an SVG element or a bare `Element` has no `style` to read.
    if (parent.isA<web.HTMLElement>()) {
      final web.HTMLElement styled = parent as web.HTMLElement;
      if (styled.style.position.isEmpty) styled.style.position = 'relative';
    }
    final _DomHostElements host = _buildHost(parent);
    host.host.style
      ..width = '${window.clientSize.width}px'
      ..height = '${window.clientSize.height}px';
    return DomCanvasPresenter._(
      host.host,
      host.scene,
      host.semantics,
      DomScene(host.scene, pointerPolicy: pointerPolicy),
      DomSemanticsLayer(host.semantics),
      true,
    );
  }

  /// Builds a DOM layer inside [container], for a test or an embedder that owns
  /// its own layout.
  ///
  /// The difference from [attach] is ownership: nothing here is positioned over
  /// anything, and [dispose] leaves [container] where it found it.
  static DomCanvasPresenter attachToElement(
    web.Element container, {
    DomPointerPolicy pointerPolicy = DomPointerPolicy.passThrough,
  }) {
    final _DomHostElements host = _buildHost(container);
    return DomCanvasPresenter._(
      host.host,
      host.scene,
      host.semantics,
      DomScene(host.scene, pointerPolicy: pointerPolicy),
      DomSemanticsLayer(host.semantics),
      true,
    );
  }

  static _DomHostElements _buildHost(web.Element parent) {
    final web.HTMLElement host =
        web.document.createElement('div') as web.HTMLElement;
    host
      ..className = 'dartui-dom-host'
      ..setAttribute(
        'style',
        // `left/top: 0` with `position: absolute` puts it exactly over the
        // canvas, which is the sibling immediately before it and is laid out at
        // the same origin. `overflow: hidden` is the root clip: without it a
        // widget that paints outside the window - a shadow, a tooltip mid
        // animation - would extend the page's scroll area, which on a canvas
        // backend simply cannot happen and would read as a layout bug here.
        'position:absolute;left:0;top:0;overflow:hidden;'
            'pointer-events:none;transform-origin:0 0',
      );
    final web.Element scene = web.document.createElement('div')
      ..className = 'dartui-dom-scene'
      ..setAttribute('style', 'position:absolute;left:0;top:0');
    final web.Element semantics = web.document.createElement('div')
      ..className = 'dartui-dom-semantics'
      // Above the visual layer in paint order and still `pointer-events: none`,
      // so it can never intercept a click. It is here for the keyboard and for
      // the accessibility tree.
      ..setAttribute('style', 'position:absolute;left:0;top:0');
    host
      ..append(scene)
      ..append(semantics);
    parent.append(host);
    return (host: host, scene: scene, semantics: semantics);
  }

  final web.HTMLElement _host;
  final web.Element _sceneRoot;
  final web.Element _semanticsRoot;
  final DomScene _scene;
  final DomSemanticsLayer _semantics;
  final bool _ownsHost;

  int _framesPresented = 0;

  /// Where the semantic tree comes from. Null publishes nothing, in which case
  /// the DOM still carries selectable, findable text and no roles.
  DomSemanticsSource? semanticsSource;

  /// Where an activation raised from the DOM goes. See
  /// [DomSemanticsLayer.onAction].
  set onSemanticsAction(
          void Function(int nodeId, SemanticsAction action)? fn) =>
      _semantics.onAction = fn;

  /// Where a newly discovered refusal is reported, once per distinct reason.
  set onRefusal(void Function(DomRefusal refusal)? fn) => _scene.onRefusal = fn;

  /// Everything the DOM could not express, and how often. Cumulative.
  Map<String, int> get refusals =>
      Map<String, int>.unmodifiable(_scene.refusals);

  /// Elements created, reused and removed on the last frame.
  ///
  /// `created == 0` on a steady-state frame is the observable claim that this
  /// backend does not destroy focus and selection every frame, and it is what
  /// the tests assert.
  int get lastCreated => _scene.lastCreated;
  int get lastReused => _scene.lastReused;
  int get lastRemoved => _scene.lastRemoved;

  /// Glyphs the display list could not name; see `dom_text.dart`.
  int get unresolvedGlyphs => _scene.unresolvedGlyphs;

  /// The element this presenter builds into. For tests and for an embedder that
  /// wants to style it.
  web.HTMLElement get hostElement => _host;

  web.Element get sceneElement => _sceneRoot;

  web.Element get semanticsElement => _semanticsRoot;

  int get semanticNodeCount => _semantics.publishedNodeCount;

  int get framesPresented => _framesPresented;

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'HTML elements in the page, composited by the '
            'browser',
        rasterizationApproach: RasterizationApproach.custom,
      );

  /// Always false. A DOM tree is not a device; see the library comment.
  @override
  bool get isDeviceLost => false;

  @override
  Future<bool> recoverFromDeviceLoss() async => !isDisposed;

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) async {
    throwIfDisposed();
    // `deviceTransform` is read and dropped, and that is the design rather than
    // an omission: a CSS pixel is already a logical unit and the browser
    // applies `devicePixelRatio` itself, so applying it here would draw
    // everything at twice the size on a retina display. See `dom_scene.dart`.
    //
    // `damage` is dropped too, and for a better reason than the GPU paths'. The
    // whole tree is retained: a command that did not change writes nothing to
    // the DOM, so the frame is already restricted to what actually moved,
    // element by element rather than rectangle by rectangle. Honouring a damage
    // rectangle on top of that could only *skip* work the diff already skipped,
    // while making a command outside the rectangle silently stale.
    if (clearColor != null) {
      _host.style.backgroundColor = _cssColor(clearColor);
    }
    try {
      _scene.update(list);
    } on Object catch (error, stack) {
      // A malformed list reaches the reader as a DisplayListFormatException,
      // and unwinding out of `present` would take the page's frame loop with
      // it. Reporting it as a failed present is what `PresentStatus.failed` is
      // for, and it keeps the next frame possible.
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the DOM scene could not be reconciled: $error',
          detail: '$stack',
        ),
      );
    }

    final DomSemanticsSource? source = semanticsSource;
    if (source != null) {
      // After the scene and not before, because the semantic bounds come from
      // `RenderBox.size` and the caller is expected to have laid out before
      // presenting. Ordering it here also means a failure in the visual layer
      // is reported without a half-published accessibility tree behind it.
      try {
        _semantics.update(source());
      } on Object catch (error) {
        return PresentResult(
          status: PresentStatus.failed,
          diagnostic: BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'the semantic tree could not be published: $error',
          ),
        );
      }
    }

    _framesPresented++;
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Resizes the host box.
  ///
  /// In **logical** units, computed back out of the pixel size the host was
  /// given: everything under [_host] is positioned in CSS pixels, and the
  /// window hands presenters physical ones. Doing this the other way - sizing
  /// the host in device pixels - produces a page whose clip is twice as large
  /// as its content on a retina screen, which looks like nothing at all until
  /// something paints outside the window.
  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {
    if (isDisposed) return;
    final double logicalWidth =
        scale == 0 ? pixelWidth * 1.0 : pixelWidth / scale;
    final double logicalHeight =
        scale == 0 ? pixelHeight * 1.0 : pixelHeight / scale;
    _host.style
      ..width = '${logicalWidth}px'
      ..height = '${logicalHeight}px';
  }

  @override
  void onDispose() {
    _semantics.clear();
    _scene.clear();
    // The host is removed, the canvas is not touched. Same ownership rule the
    // WebGL and WebGPU presenters state: the page created the canvas and this
    // presenter created the host, and each gives back only what it made.
    if (_ownsHost) _host.remove();
  }
}

/// The three elements a host is: the clipping box, the visual layer and the
/// accessibility layer.
typedef _DomHostElements = ({
  web.HTMLElement host,
  web.Element scene,
  web.Element semantics,
});

String _cssColor(int argb) {
  final int alpha = (argb >> 24) & 0xFF;
  final int red = (argb >> 16) & 0xFF;
  final int green = (argb >> 8) & 0xFF;
  final int blue = argb & 0xFF;
  if (alpha == 255) return 'rgb($red,$green,$blue)';
  return 'rgba($red,$green,$blue,${alpha / 255})';
}
