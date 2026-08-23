import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/transform2d.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_tessellated_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/vector/cpu_tessellation.dart';
import 'package:test/test.dart';

void main() {
  test('retains one VBO/IBO pair and changes only per-draw state', () {
    final CpuTessellatedPathCache cache = CpuTessellatedPathCache();
    final TessellatedPathMesh mesh = cache.resolve(
      Path.rect(const Rect.fromLTRB(1, 2, 5, 7)),
    );
    final _FakeTessellatedDriver driver = _FakeTessellatedDriver();
    final TessellatedGlExecutor executor = TessellatedGlExecutor(driver)
      ..initialize(desktop: true);
    final TessellatedGlMaterial material = TessellatedGlMaterial(
      red: 0.25,
      green: 0.125,
      blue: 0,
      alpha: 0.5,
      blendMode: blendModeSrcOver,
    );

    final TessellatedGlExecutionStats first = executor.submit(
      mesh,
      material: material,
      viewportWidth: 100,
      viewportHeight: 80,
      localToTarget: const Transform2D(2, 0, 0, 3, 7, 11),
      clip: const Rect.fromLTRB(4, 5, 40, 50),
    );
    final TessellatedGlExecutionStats second = executor.submit(
      cache.resolve(Path.rect(const Rect.fromLTRB(1, 2, 5, 7))),
      material: material,
      viewportWidth: 100,
      viewportHeight: 80,
      yFlip: 1,
      localToTarget: const Transform2D.translation(20, 30),
    );

    expect(first.uploadedMeshes, 1);
    expect(first.uploadedBytes, mesh.metrics.retainedBytes);
    expect(first.triangles, 2);
    expect(second.uploadedMeshes, 0);
    expect(driver.uploads, 1);
    expect(executor.retainedMeshCount, 1);
    expect(driver.transforms, <Transform2D>[
      const Transform2D(2, 0, 0, 3, 7, 11),
      const Transform2D.translation(20, 30),
    ]);
    expect(driver.clips, <Rect?>[
      const Rect.fromLTRB(4, 5, 40, 50),
      null,
    ]);
    expect(
        driver.events,
        containsAllInOrder(<String>[
          'begin:100x80:0',
          'draw:10/11:6',
          'end',
          'begin:100x80:1',
          'draw:10/11:6',
          'end',
        ]));
  });

  test('release and normal disposal delete retained buffers exactly once', () {
    final TessellatedPathMesh first = const CpuPathTessellator()
        .tessellate(Path.rect(const Rect.fromLTRB(0, 0, 4, 4)));
    final TessellatedPathMesh second = const CpuPathTessellator()
        .tessellate(Path.rect(const Rect.fromLTRB(0, 0, 8, 3)));
    final _FakeTessellatedDriver driver = _FakeTessellatedDriver();
    final TessellatedGlExecutor executor = TessellatedGlExecutor(driver)
      ..initialize(desktop: false);
    final material = TessellatedGlMaterial(
      red: 1,
      green: 1,
      blue: 1,
      alpha: 1,
      blendMode: blendModeSrc,
    );
    for (final TessellatedPathMesh mesh in <TessellatedPathMesh>[
      first,
      second
    ]) {
      executor.submit(
        mesh,
        material: material,
        viewportWidth: 16,
        viewportHeight: 16,
      );
    }

    expect(executor.releaseMesh(first.cacheKey), isTrue);
    expect(executor.releaseMesh(first.cacheKey), isFalse);
    executor
      ..dispose()
      ..dispose();

    expect(driver.deletedMeshes, <String>['10/11', '12/13']);
    expect(driver.resourceDeletes, 1);
  });

  test('device loss forgets names and lazily uploads the CPU mesh again', () {
    final TessellatedPathMesh mesh = const CpuPathTessellator()
        .tessellate(Path.rect(const Rect.fromLTRB(0, 0, 4, 4)));
    final _FakeTessellatedDriver driver = _FakeTessellatedDriver();
    final TessellatedGlExecutor executor = TessellatedGlExecutor(driver)
      ..initialize(desktop: true);
    final material = TessellatedGlMaterial(
      red: 1,
      green: 0,
      blue: 0,
      alpha: 1,
    );
    executor.submit(
      mesh,
      material: material,
      viewportWidth: 8,
      viewportHeight: 8,
    );

    executor.discardNativeResources();

    expect(executor.isInitialized, isFalse);
    expect(executor.retainedMeshCount, 0);
    expect(driver.discards, 1);
    expect(driver.deletedMeshes, isEmpty);
    expect(driver.resourceDeletes, 0);

    executor.initialize(desktop: true);
    final TessellatedGlExecutionStats stats = executor.submit(
      mesh,
      material: material,
      viewportWidth: 8,
      viewportHeight: 8,
    );
    expect(stats.uploadedMeshes, 1);
    expect(driver.uploads, 2);
    expect(driver.resourceCreates, 2);
  });

  test('empty and invalid submissions do not start a pass', () {
    final _FakeTessellatedDriver driver = _FakeTessellatedDriver();
    final TessellatedGlExecutor executor = TessellatedGlExecutor(driver)
      ..initialize(desktop: true);
    final material = TessellatedGlMaterial(
      red: 0,
      green: 0,
      blue: 0,
      alpha: 0,
    );
    final TessellatedGlExecutionStats empty = executor.submit(
      const CpuPathTessellator().tessellate(Path.empty),
      material: material,
      viewportWidth: 4,
      viewportHeight: 4,
    );
    expect(empty.drawCalls, 0);
    expect(driver.events, isNot(contains(startsWith('begin:'))));

    expect(
      () => executor.submit(
        const CpuPathTessellator()
            .tessellate(Path.rect(const Rect.fromLTRB(0, 0, 2, 2))),
        material: material,
        viewportWidth: 4,
        viewportHeight: 4,
        yFlip: 2,
      ),
      throwsArgumentError,
    );
    expect(driver.events, isNot(contains(startsWith('begin:'))));
  });

  test('a failed retained draw still closes the GL pass', () {
    final _FakeTessellatedDriver driver =
        _FakeTessellatedDriver(failDraw: true);
    final TessellatedGlExecutor executor = TessellatedGlExecutor(driver)
      ..initialize(desktop: true);
    expect(
      () => executor.submit(
        const CpuPathTessellator()
            .tessellate(Path.rect(const Rect.fromLTRB(0, 0, 2, 2))),
        material: TessellatedGlMaterial(
          red: 1,
          green: 1,
          blue: 1,
          alpha: 1,
        ),
        viewportWidth: 4,
        viewportHeight: 4,
      ),
      throwsStateError,
    );
    expect(driver.events.last, 'end');
  });
}

final class _FakeTessellatedDriver implements TessellatedGlDriver {
  _FakeTessellatedDriver({this.failDraw = false});

  final bool failDraw;
  final List<String> events = <String>[];
  final List<Transform2D> transforms = <Transform2D>[];
  final List<Rect?> clips = <Rect?>[];
  final List<String> deletedMeshes = <String>[];
  int resourceCreates = 0;
  int resourceDeletes = 0;
  int uploads = 0;
  int discards = 0;
  int _nextBuffer = 10;

  @override
  void createResources({
    required String vertexSource,
    required String fragmentSource,
  }) {
    expect(vertexSource, contains('uLocalToTarget0'));
    expect(fragmentSource, contains('uColor'));
    resourceCreates++;
    events.add('create');
  }

  @override
  void deleteResources() {
    resourceDeletes++;
    events.add('deleteResources');
  }

  @override
  TessellatedGlMeshHandle uploadMesh(TessellatedPathMesh mesh) {
    uploads++;
    final int vertex = _nextBuffer++;
    final int index = _nextBuffer++;
    events.add('upload:$vertex/$index:${mesh.indices.length}');
    return TessellatedGlMeshHandle(
      vertexBuffer: vertex,
      indexBuffer: index,
      indexCount: mesh.indices.length,
    );
  }

  @override
  void deleteMesh(TessellatedGlMeshHandle mesh) {
    deletedMeshes.add('${mesh.vertexBuffer}/${mesh.indexBuffer}');
  }

  @override
  void beginTessellatedPass({
    required int viewportWidth,
    required int viewportHeight,
    required int yFlip,
  }) =>
      events.add('begin:${viewportWidth}x$viewportHeight:$yFlip');

  @override
  void setBlendState(GpuBlendState blend) => events.add('blend:$blend');

  @override
  void setPremultipliedColor(
    double red,
    double green,
    double blue,
    double alpha,
  ) =>
      events.add('color:$red/$green/$blue/$alpha');

  @override
  void setLocalToTarget(Transform2D transform) {
    transforms.add(transform);
  }

  @override
  void setClip(Rect? clip) {
    clips.add(clip);
  }

  @override
  void drawMesh(TessellatedGlMeshHandle mesh) {
    events.add(
      'draw:${mesh.vertexBuffer}/${mesh.indexBuffer}:${mesh.indexCount}',
    );
    if (failDraw) throw StateError('injected retained draw failure');
  }

  @override
  void endTessellatedPass() => events.add('end');

  @override
  void discardNativeResources() {
    discards++;
    events.add('discard');
  }
}
