/// Window media publication and safe-area consumption.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  group('MediaQueryData', () {
    const MediaQueryData data = MediaQueryData(
      size: Size(800, 600),
      devicePixelRatio: 2,
      padding: EdgeInsets(10, 20, 30, 40),
      viewPadding: EdgeInsets(12, 25, 35, 45),
      viewInsets: EdgeInsets(0, 0, 0, 200),
    );

    test('orientation and copyWith preserve every unspecified field', () {
      final MediaQueryData changed = data.copyWith(
        size: const Size(500, 900),
        highContrast: true,
      );

      expect(data.orientation, Orientation.landscape);
      expect(changed.orientation, Orientation.portrait);
      expect(changed.devicePixelRatio, 2);
      expect(changed.padding, data.padding);
      expect(changed.viewInsets, data.viewInsets);
      expect(changed.highContrast, isTrue);
    });

    test('removePadding consumes only the named edges', () {
      final MediaQueryData removed = data.removePadding(
        removeLeft: true,
        removeBottom: true,
      );

      expect(removed.padding, const EdgeInsets(0, 20, 30, 0));
      expect(removed.viewPadding, const EdgeInsets(2, 25, 35, 5));
      expect(removed.viewInsets, data.viewInsets);
    });

    test('removeViewInsets and removeViewPadding adjust related values', () {
      final MediaQueryData noInsets = data.removeViewInsets(
        removeBottom: true,
      );
      expect(noInsets.viewInsets.bottom, 0);
      expect(noInsets.viewPadding.bottom, 0);

      final MediaQueryData noViewPadding = data.removeViewPadding(
        removeTop: true,
        removeRight: true,
      );
      expect(noViewPadding.viewPadding, const EdgeInsets(12, 0, 0, 45));
      expect(noViewPadding.padding, const EdgeInsets(10, 0, 0, 40));
    });

    test('removing no edges returns the same immutable value', () {
      expect(identical(data.removePadding(), data), isTrue);
      expect(identical(data.removeViewInsets(), data), isTrue);
      expect(identical(data.removeViewPadding(), data), isTrue);
    });
  });

  group('publication', () {
    test('of and the focused getters see the nearest scope', () {
      const MediaQueryData outer = MediaQueryData(
        size: Size(800, 600),
        devicePixelRatio: 2,
      );
      const MediaQueryData inner = MediaQueryData(
        size: Size(320, 480),
        devicePixelRatio: 3,
      );
      final List<MediaQueryData> seen = <MediaQueryData>[];

      mounted(
        MediaQuery(
          data: outer,
          child: MediaQuery(
            data: inner,
            child: _Probe(onBuild: seen.add),
          ),
        ),
        outer.size,
      );

      expect(seen, <MediaQueryData>[inner]);
    });

    test('notification compares data and a changed root reaches dependents',
        () {
      final List<MediaQueryData> seen = <MediaQueryData>[];
      const Widget leaf = SizedBox(width: 1, height: 1);
      final _Probe probe = _Probe(onBuild: seen.add, child: leaf);
      final MediaQuery original = MediaQuery(
        data: const MediaQueryData(size: Size(100, 100)),
        child: probe,
      );
      final MediaQuery equal = MediaQuery(
        data: const MediaQueryData(size: Size(100, 100)),
        child: probe,
      );
      final MediaQuery changed = MediaQuery(
        data: const MediaQueryData(size: Size(200, 100)),
        child: probe,
      );
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      expect(equal.updateShouldNotify(original), isFalse);
      expect(changed.updateShouldNotify(original), isTrue);

      owner.updateRoot(original);
      owner.updateRoot(changed);

      expect(seen.map((MediaQueryData value) => value.size), <Size>[
        const Size(100, 100),
        const Size(200, 100),
      ]);
    });

    test('absence is named, while maybeOf stays nullable', () {
      final List<BuildContext> contexts = <BuildContext>[];
      mounted(_Capture(contexts.add), const Size(10, 10));
      final BuildContext context = contexts.single;

      expect(MediaQuery.maybeOf(context), isNull);
      expect(
        () => MediaQuery.of(context),
        throwsA(
          isA<MissingMediaQueryError>()
              .having(
                (MissingMediaQueryError error) => error.requestedBy,
                'requestedBy',
                '_Capture',
              )
              .having(
                (MissingMediaQueryError error) => error.toString(),
                'message',
                allOf(contains('runApp'), contains('MediaQuery.maybeOf')),
              ),
        ),
      );
    });
  });

  group('SafeArea', () {
    const MediaQueryData media = MediaQueryData(
      size: Size(100, 100),
      padding: EdgeInsets(10, 20, 30, 40),
      viewPadding: EdgeInsets(12, 25, 35, 45),
    );

    test('lays its child inside all four safe edges', () {
      final List<MediaQueryData> inside = <MediaQueryData>[];
      final (BuildOwner owner, _) = mounted(
        MediaQuery(
          data: media,
          child: SafeArea(child: _Probe(onBuild: inside.add)),
        ),
        media.size,
      );

      final RenderPadding render = owner.renderRoot! as RenderPadding;
      expect(render.padding, media.padding);
      expect(render.child!.parentData!.offset, const Offset(10, 20));
      expect(render.child!.size, const Size(60, 40));
      expect(inside.single.padding, EdgeInsets.zero);
      expect(inside.single.viewPadding, const EdgeInsets(2, 5, 5, 5));
    });

    test('selected sides and minimum are combined edge by edge', () {
      final (BuildOwner owner, _) = mounted(
        const MediaQuery(
          data: media,
          child: SafeArea(
            top: false,
            right: false,
            minimum: EdgeInsets(15, 7, 8, 2),
            child: SizedBox(width: 1, height: 1),
          ),
        ),
        media.size,
      );

      final RenderPadding render = owner.renderRoot! as RenderPadding;
      expect(render.padding, const EdgeInsets(15, 7, 8, 40));
    });

    test('nested safe areas do not apply one system inset twice', () {
      final (BuildOwner owner, _) = mounted(
        const MediaQuery(
          data: media,
          child: SafeArea(
            child: SafeArea(child: SizedBox(width: 1, height: 1)),
          ),
        ),
        media.size,
      );

      final RenderPadding outer = owner.renderRoot! as RenderPadding;
      final RenderPadding inner = outer.child! as RenderPadding;
      expect(outer.padding, media.padding);
      expect(inner.padding, EdgeInsets.zero);
    });

    test('may keep persistent bottom padding above a temporary inset', () {
      final (BuildOwner owner, _) = mounted(
        const MediaQuery(
          data: MediaQueryData(
            size: Size(100, 100),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.only(bottom: 34),
            viewInsets: EdgeInsets.only(bottom: 200),
          ),
          child: SafeArea(
            maintainBottomViewPadding: true,
            child: SizedBox(width: 1, height: 1),
          ),
        ),
        const Size(100, 100),
      );

      expect(
        (owner.renderRoot! as RenderPadding).padding,
        const EdgeInsets.only(bottom: 34),
      );
    });
  });
}

final class _Probe extends StatelessWidget {
  const _Probe({required this.onBuild, this.child});

  final void Function(MediaQueryData data) onBuild;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    onBuild(MediaQuery.of(context));
    return child ?? const SizedBox(width: 1, height: 1);
  }
}

final class _Capture extends StatelessWidget {
  const _Capture(this.onBuild);

  final void Function(BuildContext context) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(context);
    return const SizedBox(width: 1, height: 1);
  }
}
