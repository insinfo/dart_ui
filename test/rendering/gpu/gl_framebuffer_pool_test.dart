/// The framebuffer pool's arithmetic, counted with a fake factory.
///
/// "The pool reuses its buffers" is a claim about how many times the driver
/// was asked for one, and there is no way to observe that through a real GL
/// context without a debugger attached. So the factory is an interface and
/// this file implements it with three integers and a counter - the same
/// technique `gpu_glyph_atlas_test.dart` uses to prove a glyph was rasterised
/// once.
library;

import 'package:dart_ui/src/rendering/gpu/gl/gl_framebuffer_pool.dart';
import 'package:test/test.dart';

void main() {
  group('size classes', () {
    test('small sizes round to a power of two, with a floor', () {
      // Below 256 the number of classes is what matters: a screen of chips and
      // badges of assorted sizes has to end up sharing a handful of targets.
      expect(GlFramebufferPool.sizeClass(1), 32);
      expect(GlFramebufferPool.sizeClass(32), 32);
      expect(GlFramebufferPool.sizeClass(33), 64);
      expect(GlFramebufferPool.sizeClass(100), 128);
      expect(GlFramebufferPool.sizeClass(128), 128);
      expect(GlFramebufferPool.sizeClass(129), 256);
      expect(GlFramebufferPool.sizeClass(256), 256);
    });

    test('large sizes round to a block, so a full-screen layer is not doubled',
        () {
      // The whole reason the policy has two halves: the next power of two
      // after 1080 is 2048, which would cost a 1080p layer four times its own
      // memory. Blocks of 256 keep the waste under 25% at 1024 and under 7% at
      // 4096.
      expect(GlFramebufferPool.sizeClass(257), 512);
      expect(GlFramebufferPool.sizeClass(512), 512);
      expect(GlFramebufferPool.sizeClass(1000), 1024);
      expect(GlFramebufferPool.sizeClass(1080), 1280);
      expect(GlFramebufferPool.sizeClass(1920), 2048);
      expect(GlFramebufferPool.sizeClass(3840), 3840);
    });

    test('a target is allocated at its class, not at the size asked for', () {
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(factory: factory);

      final target = pool.acquireLayerTarget(100, 60);

      expect(target.width, 128);
      expect(target.height, 64);
      expect(factory.created.single, <int>[128, 64]);
    });
  });

  group('reuse', () {
    test('a released target answers the next request of its class', () {
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(factory: factory);

      final first = pool.acquireLayerTarget(100, 60);
      pool.releaseLayerTarget(first);
      final second = pool.acquireLayerTarget(100, 60);

      expect(identical(first, second), isTrue);
      expect(pool.createCount, 1);
      expect(pool.reuseCount, 1);
      expect(factory.deleted, isEmpty);
    });

    test('a layer that grew by a pixel still hits, which is the entire point',
        () {
      // The failure mode a pool matching on the exact size has: a list one
      // item taller, a panel animating a fraction of a pixel, and the pool
      // allocates and destroys a target every frame - worse than no pool.
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(factory: factory);

      var target = pool.acquireLayerTarget(300, 180);
      for (var frame = 1; frame <= 10; frame++) {
        pool.releaseLayerTarget(target);
        target = pool.acquireLayerTarget(300 + frame, 180 + frame);
      }

      expect(pool.createCount, 1);
      expect(pool.reuseCount, 10);
    });

    test('two live layers of the same class get two targets', () {
      // Nothing is released between them, so reuse would hand one framebuffer
      // to two layers and the second would overwrite the first.
      final pool = GlFramebufferPool(factory: _SpyFactory());

      final a = pool.acquireLayerTarget(100, 100);
      final b = pool.acquireLayerTarget(100, 100);

      expect(identical(a, b), isFalse);
      expect(pool.createCount, 2);
    });

    test('a different class does not reuse', () {
      final pool = GlFramebufferPool(factory: _SpyFactory());
      pool.releaseLayerTarget(pool.acquireLayerTarget(100, 100));
      pool.acquireLayerTarget(300, 100);

      expect(pool.createCount, 2);
      expect(pool.reuseCount, 0);
    });

    test('targets survive across frames, which is why the pool exists', () {
      final pool = GlFramebufferPool(factory: _SpyFactory());
      for (var frame = 0; frame < 60; frame++) {
        final target = pool.acquireLayerTarget(200, 120);
        pool.releaseLayerTarget(target);
      }

      expect(pool.createCount, 1);
      expect(pool.reuseCount, 59);
      expect(pool.deleteCount, 0);
    });
  });

  group('budgets', () {
    test('idle memory over the budget is deleted, oldest first', () {
      // 256x256x4 is 256 KiB; a budget of 300 KiB holds exactly one.
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(
        factory: factory,
        maxIdleBytes: 300 * 1024,
        maxTotalBytes: 8 * 1024 * 1024,
      );

      final first = pool.acquireLayerTarget(200, 200);
      final second = pool.acquireLayerTarget(200, 200);
      pool.releaseLayerTarget(first);
      pool.releaseLayerTarget(second);

      expect(pool.idleCount, 1);
      expect(pool.deleteCount, 1);
      expect(factory.deleted.single, first.id,
          reason: 'the least recently released is the least likely to match');
      expect(pool.idleBytes, 256 * 1024);
    });

    test(
        'an idle target still counts against the total, and is given up '
        'before the budget refuses', () {
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(
        factory: factory,
        // Two 256x256 targets exactly, and idle memory allowed to fill it.
        maxIdleBytes: 512 * 1024,
        maxTotalBytes: 512 * 1024,
      );

      final small = pool.acquireLayerTarget(200, 200);
      pool.releaseLayerTarget(small);
      // 512x512 is 1 MiB, which does not fit beside the idle one - or at all,
      // until the idle one is deleted.
      expect(() => pool.acquireLayerTarget(400, 400),
          throwsA(isA<GlFramebufferBudgetError>()));
      expect(factory.deleted, contains(small.id),
          reason: 'the budget gives up its idle memory before it refuses');
    });

    test('exceeding the total budget is a named error carrying the numbers',
        () {
      final pool = GlFramebufferPool(
        factory: _SpyFactory(),
        maxIdleBytes: 128 * 1024,
        maxTotalBytes: 512 * 1024,
      );

      pool.acquireLayerTarget(200, 200);
      pool.acquireLayerTarget(200, 200);

      expect(
        () => pool.acquireLayerTarget(200, 200),
        throwsA(isA<GlFramebufferBudgetError>()
            .having((e) => e.liveBytes, 'liveBytes', 512 * 1024)
            .having((e) => e.maxTotalBytes, 'maxTotalBytes', 512 * 1024)
            .having((e) => e.requestedWidth, 'requestedWidth', 256)
            .having((e) => e.toString(), 'message', contains('MiB'))),
      );
    });

    test('trim gives the memory back and dispose deletes everything', () {
      final factory = _SpyFactory();
      final pool = GlFramebufferPool(factory: factory);
      pool.releaseLayerTarget(pool.acquireLayerTarget(100, 100));
      pool.releaseLayerTarget(pool.acquireLayerTarget(300, 300));

      expect(pool.idleCount, 2);
      pool.trim();
      expect(pool.idleCount, 0);
      expect(pool.idleBytes, 0);
      expect(pool.liveBytes, 0);
      expect(factory.deleted.length, 2);

      pool.dispose();
      expect(factory.deleted.length, 2, reason: 'nothing left to delete');
    });
  });

  group('refusals', () {
    test('a zero-sized layer never reaches the driver', () {
      final pool = GlFramebufferPool(factory: _SpyFactory());
      expect(() => pool.acquireLayerTarget(0, 10), throwsArgumentError);
      expect(() => pool.acquireLayerTarget(10, -1), throwsArgumentError);
    });

    test('a driver that refuses is a StateError naming the size', () {
      final pool = GlFramebufferPool(factory: _SpyFactory(refuse: true));
      expect(
        () => pool.acquireLayerTarget(64, 64),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('64x64'))),
      );
    });

    test('a foreign target is refused rather than pooled', () {
      // Two allocators wired to one layer stack would otherwise show up as a
      // framebuffer leak in one and a double free in the other.
      final pool = GlFramebufferPool(factory: _SpyFactory());
      expect(
        () => pool.releaseLayerTarget(
            GlFramebuffer(id: 9, textureId: 9, width: 8, height: 8)),
        returnsNormally,
      );
    });
  });
}

/// A factory that hands out integers and remembers what it was asked for.
final class _SpyFactory implements GlFramebufferFactory {
  _SpyFactory({this.refuse = false});

  /// Stands in for a driver that will not create a framebuffer - out of
  /// memory, or an incomplete attachment.
  final bool refuse;

  final List<List<int>> created = <List<int>>[];
  final List<int> deleted = <int>[];
  int _nextName = 1;

  @override
  GlFramebuffer? createFramebuffer(int width, int height) {
    if (refuse) return null;
    created.add(<int>[width, height]);
    final int name = _nextName++;
    return GlFramebuffer(
      id: name,
      textureId: name + 1000,
      width: width,
      height: height,
    );
  }

  @override
  void deleteFramebuffer(GlFramebuffer framebuffer) =>
      deleted.add(framebuffer.id);
}
