/// The overlay: stacking order, and what `opaque` actually costs the entries
/// underneath it.
///
/// The assertions here are deliberately about *observable* things - pixels in a
/// framebuffer, taps that did or did not arrive, `State` objects that were or
/// were not disposed - rather than about the shape of the widget tree the
/// overlay happens to build. The tree is an implementation detail; "a click
/// cannot reach a control the user cannot see" is the contract.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

// `pixelAt` and `memoryTarget` are shared rather than re-implemented: a test
// helper that reads a framebuffer in two places is one that can disagree with
// itself about channel order.
import '../layout/helpers.dart';

const int _background = 0xFF000000;
const int _bottomColor = 0xFFCC3311;
const int _middleColor = 0xFF117744;
const int _topColor = 0xFF3366CC;

const (int, int, int, int) _backgroundPixel = (0x00, 0x00, 0x00, 0xFF);
const (int, int, int, int) _bottomPixel = (0xCC, 0x33, 0x11, 0xFF);
const (int, int, int, int) _middlePixel = (0x11, 0x77, 0x44, 0xFF);
const (int, int, int, int) _topPixel = (0x33, 0x66, 0xCC, 0xFF);

void main() {
  late PipelineOwner pipeline;
  late BuildOwner owner;
  late OverlayState overlay;

  OverlayState mount(
    List<OverlayEntry> initialEntries, {
    Size viewport = const Size(16, 16),
  }) {
    pipeline = PipelineOwner(rootConstraints: BoxConstraints.tight(viewport));
    owner = BuildOwner(pipelineOwner: pipeline);
    addTearDown(owner.dispose);
    final GlobalKey<OverlayState> key = GlobalKey<OverlayState>();
    owner.updateRoot(Overlay(key: key, initialEntries: initialEntries));
    pipeline.flushLayout();
    overlay = key.currentState!;
    return overlay;
  }

  void settle() {
    owner.buildScope();
    pipeline.flushLayout();
  }

  Future<Framebuffer> pixels({int side = 16}) async {
    settle();
    final DisplayList list = DisplayList();
    pipeline.drawFrame(list);
    final MemoryRenderTarget target = await memoryTarget(side, side);
    addTearDown(target.dispose);
    await target.renderDisplayList(list, clearColor: _background);
    return target.framebuffer;
  }

  OverlayEntry filled(
    int color, {
    bool opaque = false,
    bool maintainState = false,
  }) =>
      OverlayEntry(
        builder: (BuildContext context) => ColoredBox(color: color),
        opaque: opaque,
        maintainState: maintainState,
      );

  group('stacking order', () {
    test('the last entry inserted paints on top of the earlier ones', () async {
      mount(<OverlayEntry>[filled(_bottomColor)]);
      expect(pixelAt(await pixels(), 8, 8), _bottomPixel);

      overlay.insert(filled(_topColor));
      expect(pixelAt(await pixels(), 8, 8), _topPixel);
      expect(overlay.length, 2);
    });

    test('insert above and below place an entry at a named position', () {
      final OverlayEntry bottom = filled(_bottomColor);
      final OverlayEntry top = filled(_topColor);
      mount(<OverlayEntry>[bottom, top]);

      final OverlayEntry middle = filled(_middleColor);
      overlay.insert(middle, above: bottom);
      expect(overlay.entries, <OverlayEntry>[bottom, middle, top]);

      final OverlayEntry lowest = filled(_middleColor);
      overlay.insert(lowest, below: bottom);
      expect(overlay.entries, <OverlayEntry>[lowest, bottom, middle, top]);
    });

    test('two anchors at once are refused rather than silently resolved', () {
      final OverlayEntry bottom = filled(_bottomColor);
      final OverlayEntry top = filled(_topColor);
      mount(<OverlayEntry>[bottom, top]);

      expect(
        () => overlay.insert(filled(1), above: bottom, below: top),
        throwsArgumentError,
      );
    });

    test('an entry cannot be in two overlays at once', () {
      final OverlayEntry shared = filled(_bottomColor);
      mount(<OverlayEntry>[shared]);
      final OverlayState first = overlay;

      mount(<OverlayEntry>[filled(_topColor)]);
      expect(() => overlay.insert(shared), throwsStateError);
      expect(shared.overlay, same(first));
    });

    test('removing an entry that is in no overlay names the mistake', () {
      final OverlayEntry entry = filled(_topColor);
      mount(<OverlayEntry>[entry]);

      entry.remove();
      expect(entry.isInserted, isFalse);
      expect(entry.remove, throwsStateError);
    });
  });

  group('opaque', () {
    test(
        'an opaque entry in the middle hides what is below it and nothing '
        'above it', () async {
      final OverlayEntry bottom = filled(_bottomColor);
      final OverlayEntry middle = filled(_middleColor, opaque: true);
      // A small square, so the middle entry is still visible around it and the
      // test can tell "covered" from "painted over".
      final OverlayEntry top = OverlayEntry(
        builder: (BuildContext context) => const Center(
          child: SizedBox(
            width: 4,
            height: 4,
            child: ColoredBox(color: _topColor),
          ),
        ),
      );
      mount(<OverlayEntry>[bottom, middle, top]);

      expect(overlay.isOnstage(bottom), isFalse);
      expect(overlay.isOnstage(middle), isTrue);
      expect(overlay.isOnstage(top), isTrue);

      final Framebuffer buffer = await pixels();
      expect(pixelAt(buffer, 8, 8), _topPixel, reason: 'the top entry paints');
      expect(
        pixelAt(buffer, 1, 1),
        _middlePixel,
        reason: 'the opaque entry paints everywhere the top one does not',
      );
      for (int x = 0; x < 16; x++) {
        expect(pixelAt(buffer, x, 15), isNot(_bottomPixel));
      }
    });

    test('an opaque entry that is itself covered still hides what is below it',
        () async {
      final OverlayEntry bottom = filled(_bottomColor);
      final OverlayEntry middle = filled(_middleColor, opaque: true);
      final OverlayEntry top = filled(_topColor, opaque: true);
      mount(<OverlayEntry>[bottom, middle, top]);

      expect(overlay.isOnstage(top), isTrue);
      expect(overlay.isOnstage(middle), isFalse);
      expect(overlay.isOnstage(bottom), isFalse);
      expect(pixelAt(await pixels(), 8, 8), _topPixel);
    });

    test(
        'turning opaque on and off changes what is visible without '
        'reinserting anything', () async {
      final OverlayEntry bottom = filled(_bottomColor, maintainState: true);
      final OverlayEntry top = OverlayEntry(
        builder: (BuildContext context) => const Center(
          child: SizedBox(
            width: 4,
            height: 4,
            child: ColoredBox(color: _topColor),
          ),
        ),
      );
      mount(<OverlayEntry>[bottom, top]);
      expect(pixelAt(await pixels(), 1, 1), _bottomPixel);

      // Exactly what a route transition does when it finishes arriving.
      top.opaque = true;
      expect(overlay.isOnstage(bottom), isFalse);
      expect(pixelAt(await pixels(), 1, 1), _backgroundPixel);

      top.opaque = false;
      expect(pixelAt(await pixels(), 1, 1), _bottomPixel);
    });

    test('a covered entry receives no pointers, maintained or not', () {
      int bottomTaps = 0;
      int topTaps = 0;
      final OverlayEntry bottom = OverlayEntry(
        maintainState: true,
        builder: (BuildContext context) => GestureDetector(
          onTap: () => bottomTaps++,
          child: const ColoredBox(color: _bottomColor),
        ),
      );
      mount(<OverlayEntry>[bottom]);

      _tap(owner, const Offset(8, 8));
      expect(bottomTaps, 1, reason: 'the only entry takes the tap');

      final OverlayEntry top = OverlayEntry(
        opaque: true,
        builder: (BuildContext context) => GestureDetector(
          onTap: () => topTaps++,
          child: const ColoredBox(color: _topColor),
        ),
      );
      overlay.insert(top);
      settle();

      _tap(owner, const Offset(8, 8));
      expect(topTaps, 1);
      expect(
        bottomTaps,
        1,
        reason: 'a modal barrier is a barrier for clicks, not only for pixels',
      );

      overlay.remove(top);
      settle();
      _tap(owner, const Offset(8, 8));
      expect(bottomTaps, 2, reason: 'and the barrier lifts when it is removed');
    });
  });

  group('maintainState', () {
    test('a covered entry is torn down by default and rebuilt when it returns',
        () {
      final List<String> log = <String>[];
      int builds = 0;
      final OverlayEntry bottom = OverlayEntry(
        builder: (BuildContext context) {
          builds++;
          return _Tracked(log: log, name: 'bottom');
        },
      );
      mount(<OverlayEntry>[bottom]);
      expect(log, <String>['bottom init']);
      expect(builds, 1);

      final OverlayEntry top = filled(_topColor, opaque: true);
      overlay.insert(top);
      settle();

      expect(log, <String>['bottom init', 'bottom dispose']);
      expect(builds, 1, reason: 'a covered entry is not built at all');
      expect(overlay.isBuilt(bottom), isFalse);

      overlay.remove(top);
      settle();
      expect(log, <String>['bottom init', 'bottom dispose', 'bottom init']);
      expect(builds, 2);
    });

    test('maintainState keeps the state alive while it is invisible', () {
      final List<String> log = <String>[];
      final OverlayEntry bottom = OverlayEntry(
        maintainState: true,
        builder: (BuildContext context) => _Tracked(log: log, name: 'bottom'),
      );
      mount(<OverlayEntry>[bottom]);

      overlay.insert(filled(_topColor, opaque: true));
      settle();

      expect(log, <String>['bottom init'], reason: 'not disposed, just hidden');
      expect(overlay.isOnstage(bottom), isFalse);
      expect(overlay.isBuilt(bottom), isTrue);
    });
  });

  group('rebuilding', () {
    test('markNeedsBuild rebuilds one entry and leaves the others alone', () {
      int bottomBuilds = 0;
      int topBuilds = 0;
      final OverlayEntry bottom = OverlayEntry(
        builder: (BuildContext context) {
          bottomBuilds++;
          return const ColoredBox(color: _bottomColor);
        },
      );
      final OverlayEntry top = OverlayEntry(
        builder: (BuildContext context) {
          topBuilds++;
          return const ColoredBox(color: _topColor);
        },
      );
      mount(<OverlayEntry>[bottom, top]);
      expect((bottomBuilds, topBuilds), (1, 1));

      top.markNeedsBuild();
      settle();

      expect(
        (bottomBuilds, topBuilds),
        (1, 2),
        reason: 'a route repainting its transition must not rebuild the page '
            'underneath it',
      );
    });

    test('markNeedsBuild on an entry that is not built is a no-op', () {
      final OverlayEntry bottom = filled(_bottomColor);
      mount(<OverlayEntry>[bottom]);
      overlay.insert(filled(_topColor, opaque: true));
      settle();

      expect(bottom.markNeedsBuild, returnsNormally);
    });
  });

  group('lookup', () {
    test('Overlay.of finds the enclosing overlay from inside an entry', () {
      OverlayState? found;
      mount(<OverlayEntry>[
        OverlayEntry(
          builder: (BuildContext context) {
            found = Overlay.of(context);
            return const ColoredBox(color: _bottomColor);
          },
        ),
      ]);

      expect(found, same(overlay));
    });

    test('a widget with no overlay above it gets a named failure', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(8, 8)),
      );
      // The default reporter records *and* rethrows, so the failure is both
      // attributable and visible here.
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);
      addTearDown(owner.dispose);

      expect(
        () => owner.updateRoot(
          _Probe(onBuild: (BuildContext context) => Overlay.of(context)),
        ),
        throwsStateError,
      );
      expect(Overlay.maybeOf, isA<Function>());
    });
  });
}

/// A leaf that records when its state was created and destroyed.
final class _Tracked extends StatefulWidget {
  const _Tracked({required this.log, required this.name});

  final List<String> log;
  final String name;

  @override
  State<_Tracked> createState() => _TrackedState();
}

final class _TrackedState extends State<_Tracked> {
  @override
  void initState() {
    super.initState();
    widget.log.add('${widget.name} init');
  }

  @override
  void dispose() {
    widget.log.add('${widget.name} dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: _bottomColor);
}

/// Runs a callback in a build, so a lookup can be tested where a lookup
/// happens.
final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild});

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const ColoredBox(color: 0xFF000000);
  }
}

void _tap(BuildOwner owner, Offset position) {
  owner.dispatchPointerEvent(
    PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ),
  );
  owner.dispatchPointerEvent(
    PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    ),
  );
}
