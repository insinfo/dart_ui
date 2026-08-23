/// Backend-neutral GPU submission data for sparse coverage strips.
///
/// [SparseStripGenerator] deliberately stops at coverage. This file performs
/// the next, equally reusable stage: it packs boundary alpha into texture
/// pages and turns solid and alpha-covered runs into compact instance arrays.
/// A GL, D3D, Metal, Vulkan or WebGPU backend can consume the same data:
///
///   1. upload the shelf rows exposed by [alphaUploadCount];
///   2. visit batches in order;
///   3. draw the batch's solid instances without a texture;
///   4. draw its alpha instances, rebinding whenever [alphaAtlasPage] changes.
///
/// A batch is one path/material pair. Keeping batches ordered is essential:
/// solid and boundary runs do not overlap *within* a path, but paths can
/// overlap each other. Grouping every solid run in the frame ahead of every
/// alpha run would therefore change compositing order.
///
/// No API-specific handles, normalised UVs or shader layouts occur here.
/// Atlas coordinates stay in integer texels, so each backend chooses its own
/// texture binding and derives UVs using [atlasWidth] and [atlasHeight]. All
/// typed arrays and texture pages are high-water arenas reused by [reset].
library;

import 'dart:typed_data';

import 'sparse_strips.dart';

/// `x, y, width, height` for a solid quad.
const int kSparseSolidInstanceStride = 4;

/// `x, y, width, height, atlasPage, atlasX, atlasY` for an alpha quad.
const int kSparseAlphaInstanceStride = 7;

/// `material, solidFirst, solidCount, alphaFirst, alphaCount` per ordered
/// submission batch.
const int kSparseBatchStride = 5;

/// `page, x, y, width, height` per alpha texture upload.
const int kSparseAlphaUploadStride = 5;

/// Static feature requirements a future rendering-strategy selector can
/// compare with a backend's capabilities.
///
/// Sparse strips need neither compute nor stencil. Instancing is preferred,
/// but not required: a backend may expand each record into four vertices.
final class SparseStripGpuRequirements {
  const SparseStripGpuRequirements._();

  static const bool requiresCompute = false;
  static const bool requiresStencil = false;
  static const bool requiresStorageBuffers = false;
  static const bool requiresAlpha8Sampling = true;
  static const bool supportsCpuVertexExpansion = true;
}

/// A snapshot of the costs relevant to selecting between sparse strips, a
/// dense analytic atlas, CPU tessellation, stencil-then-cover and compute.
final class SparseStripPlanMetrics {
  const SparseStripPlanMetrics({
    required this.batchCount,
    required this.sourceQuadCount,
    required this.solidInstanceCount,
    required this.alphaInstanceCount,
    required this.estimatedDrawCallCount,
    required this.alphaTexelBytes,
    required this.alphaUploadBytes,
    required this.alphaUploadCount,
    required this.atlasPageCount,
    required this.instanceBufferBytes,
    required this.sourceEncodedBytes,
    required this.retainedCapacityBytes,
    required this.arenaGrowths,
  });

  final int batchCount;
  final int sourceQuadCount;
  final int solidInstanceCount;
  final int alphaInstanceCount;

  /// One draw for each non-empty solid or alpha range in each ordered batch.
  final int estimatedDrawCallCount;

  /// Meaningful coverage bytes. This excludes row pitch and retained pages.
  final int alphaTexelBytes;

  /// Bytes described by the current upload records.
  final int alphaUploadBytes;
  final int alphaUploadCount;
  final int atlasPageCount;

  /// Meaningful bytes in solid, alpha and batch typed arrays.
  final int instanceBufferBytes;

  /// Size of the input [StripBuffer] records and alpha bytes.
  final int sourceEncodedBytes;

  /// Bytes retained by all typed-array and alpha-page arenas.
  final int retainedCapacityBytes;

  /// Number of typed-array growths and lazily allocated alpha pages.
  final int arenaGrowths;

  int get emittedQuadCount => solidInstanceCount + alphaInstanceCount;
  int get estimatedVertexCount => emittedQuadCount * 4;
  int get estimatedIndexCount => emittedQuadCount * 6;
}

/// A reusable per-frame draw plan for [StripBuffer] values.
final class SparseStripDrawPlan {
  SparseStripDrawPlan({
    this.atlasWidth = 1024,
    this.atlasHeight = 1024,
    int initialInstances = 256,
    int initialBatches = 64,
  })  : _solidInstances = Int32List(
          _positive(initialInstances, 'initialInstances') *
              kSparseSolidInstanceStride,
        ),
        _alphaInstances = Int32List(
          initialInstances * kSparseAlphaInstanceStride,
        ),
        _batches = Int32List(
          _positive(initialBatches, 'initialBatches') * kSparseBatchStride,
        ),
        _atlas = _SparseAlphaAtlas(
          width: _positive(atlasWidth, 'atlasWidth'),
          height: _minimum(atlasHeight, kStripHeight, 'atlasHeight'),
        );

  final int atlasWidth;
  final int atlasHeight;
  final _SparseAlphaAtlas _atlas;

  Int32List _solidInstances;
  Int32List _alphaInstances;
  Int32List _batches;

  int _solidInstanceCount = 0;
  int _alphaInstanceCount = 0;
  int _batchCount = 0;
  int _sourceQuadCount = 0;
  int _sourceEncodedBytes = 0;
  int _estimatedDrawCallCount = 0;
  int _bufferGrowths = 0;

  int get solidInstanceCount => _solidInstanceCount;
  int get alphaInstanceCount => _alphaInstanceCount;
  int get batchCount => _batchCount;
  int get alphaPageCount => _atlas.pageCount;
  int get alphaUploadCount => _atlas.uploadCount;
  int get arenaGrowths => _bufferGrowths + _atlas.growths;

  /// Whole arenas, including unused capacity. Upload only the prefixes named
  /// by the corresponding counts.
  Int32List get solidInstanceStorage => _solidInstances;
  Int32List get alphaInstanceStorage => _alphaInstances;
  Int32List get batchStorage => _batches;
  Int32List get alphaUploadStorage => _atlas.uploadStorage;

  Int32List get solidInstances => Int32List.sublistView(
        _solidInstances,
        0,
        _solidInstanceCount * kSparseSolidInstanceStride,
      );

  Int32List get alphaInstances => Int32List.sublistView(
        _alphaInstances,
        0,
        _alphaInstanceCount * kSparseAlphaInstanceStride,
      );

  Int32List get batches => Int32List.sublistView(
        _batches,
        0,
        _batchCount * kSparseBatchStride,
      );

  /// The retained alpha8 page [page]. Only [alphaPageCount] pages are active.
  Uint8List alphaPagePixels(int page) => _atlas.pagePixels(page);

  int alphaUploadPage(int upload) => _atlas.uploadField(upload, 0);
  int alphaUploadX(int upload) => _atlas.uploadField(upload, 1);
  int alphaUploadY(int upload) => _atlas.uploadField(upload, 2);
  int alphaUploadWidth(int upload) => _atlas.uploadField(upload, 3);
  int alphaUploadHeight(int upload) => _atlas.uploadField(upload, 4);

  int batchMaterial(int batch) => _batchField(batch, 0);
  int batchSolidFirst(int batch) => _batchField(batch, 1);
  int batchSolidCount(int batch) => _batchField(batch, 2);
  int batchAlphaFirst(int batch) => _batchField(batch, 3);
  int batchAlphaCount(int batch) => _batchField(batch, 4);

  /// Alpha draw ranges in [batch]. Instances are page-monotonic, so a backend
  /// obtains each range by walking from [batchAlphaFirst] and starting a draw
  /// whenever [alphaAtlasPage] changes.
  int batchAlphaPageRunCount(int batch) => _alphaPageRunCount(
        batchAlphaFirst(batch),
        batchAlphaCount(batch),
      );

  int batchEstimatedDrawCallCount(int batch) =>
      (batchSolidCount(batch) == 0 ? 0 : 1) + batchAlphaPageRunCount(batch);

  int solidX(int instance) => _solidField(instance, 0);
  int solidY(int instance) => _solidField(instance, 1);
  int solidWidth(int instance) => _solidField(instance, 2);
  int solidHeight(int instance) => _solidField(instance, 3);

  int alphaX(int instance) => _alphaField(instance, 0);
  int alphaY(int instance) => _alphaField(instance, 1);
  int alphaWidth(int instance) => _alphaField(instance, 2);
  int alphaHeight(int instance) => _alphaField(instance, 3);
  int alphaAtlasPage(int instance) => _alphaField(instance, 4);
  int alphaAtlasX(int instance) => _alphaField(instance, 5);
  int alphaAtlasY(int instance) => _alphaField(instance, 6);

  /// Forgets the frame while retaining every arena at its high-water mark.
  void reset() {
    _solidInstanceCount = 0;
    _alphaInstanceCount = 0;
    _batchCount = 0;
    _sourceQuadCount = 0;
    _sourceEncodedBytes = 0;
    _estimatedDrawCallCount = 0;
    _atlas.reset();
  }

  /// Appends one path/material pair and returns its ordered batch index.
  ///
  /// Returns `-1` for an empty buffer. A boundary strip wider than one atlas
  /// page is split into adjacent alpha instances without changing coverage.
  int append(StripBuffer buffer, {required int materialIndex}) {
    if (materialIndex < 0) {
      throw RangeError.value(materialIndex, 'materialIndex', 'must be >= 0');
    }
    if (buffer.quadCount == 0) return -1;

    final int solidFirst = _solidInstanceCount;
    final int alphaFirst = _alphaInstanceCount;

    for (var i = 0; i < buffer.fillCount; i++) {
      _addSolid(
        buffer.fillX(i),
        buffer.fillY(i),
        buffer.fillWidth(i),
        kStripHeight,
      );
    }

    for (var i = 0; i < buffer.stripCount; i++) {
      final int sourceWidth = buffer.stripWidth(i);
      final int sourceOffset = buffer.stripAlphaOffset(i);
      var chunkStart = 0;
      while (chunkStart < sourceWidth) {
        final int chunkWidth = _min(atlasWidth, sourceWidth - chunkStart);
        _atlas.allocate(chunkWidth);
        _atlas.writeLastPlacement(
          buffer.alphas,
          sourceOffset: sourceOffset + chunkStart,
          sourceRowStride: sourceWidth,
          width: chunkWidth,
        );
        _addAlpha(
          buffer.stripX(i) + chunkStart,
          buffer.stripY(i),
          chunkWidth,
          kStripHeight,
          _atlas.lastPage,
          _atlas.lastX,
          _atlas.lastY,
        );
        chunkStart += chunkWidth;
      }
    }

    final int solidCount = _solidInstanceCount - solidFirst;
    final int alphaCount = _alphaInstanceCount - alphaFirst;
    final int batch = _addBatch(
      materialIndex,
      solidFirst,
      solidCount,
      alphaFirst,
      alphaCount,
    );
    _sourceQuadCount += buffer.quadCount;
    _sourceEncodedBytes += buffer.encodedByteLength;
    if (solidCount != 0) _estimatedDrawCallCount++;
    _estimatedDrawCallCount += _alphaPageRunCount(alphaFirst, alphaCount);
    return batch;
  }

  SparseStripPlanMetrics get metrics {
    final int instanceBytes =
        _solidInstanceCount * kSparseSolidInstanceStride * 4 +
            _alphaInstanceCount * kSparseAlphaInstanceStride * 4 +
            _batchCount * kSparseBatchStride * 4;
    return SparseStripPlanMetrics(
      batchCount: _batchCount,
      sourceQuadCount: _sourceQuadCount,
      solidInstanceCount: _solidInstanceCount,
      alphaInstanceCount: _alphaInstanceCount,
      estimatedDrawCallCount: _estimatedDrawCallCount,
      alphaTexelBytes: _atlas.texelBytes,
      alphaUploadBytes: _atlas.uploadBytes,
      alphaUploadCount: _atlas.uploadCount,
      atlasPageCount: _atlas.pageCount,
      instanceBufferBytes: instanceBytes,
      sourceEncodedBytes: _sourceEncodedBytes,
      retainedCapacityBytes: _solidInstances.lengthInBytes +
          _alphaInstances.lengthInBytes +
          _batches.lengthInBytes +
          _atlas.retainedCapacityBytes,
      arenaGrowths: arenaGrowths,
    );
  }

  void _addSolid(int x, int y, int width, int height) {
    _ensureSolidCapacity(_solidInstanceCount + 1);
    final int base = _solidInstanceCount * kSparseSolidInstanceStride;
    _solidInstances[base] = x;
    _solidInstances[base + 1] = y;
    _solidInstances[base + 2] = width;
    _solidInstances[base + 3] = height;
    _solidInstanceCount++;
  }

  void _addAlpha(
    int x,
    int y,
    int width,
    int height,
    int page,
    int atlasX,
    int atlasY,
  ) {
    _ensureAlphaCapacity(_alphaInstanceCount + 1);
    final int base = _alphaInstanceCount * kSparseAlphaInstanceStride;
    _alphaInstances[base] = x;
    _alphaInstances[base + 1] = y;
    _alphaInstances[base + 2] = width;
    _alphaInstances[base + 3] = height;
    _alphaInstances[base + 4] = page;
    _alphaInstances[base + 5] = atlasX;
    _alphaInstances[base + 6] = atlasY;
    _alphaInstanceCount++;
  }

  int _addBatch(
    int material,
    int solidFirst,
    int solidCount,
    int alphaFirst,
    int alphaCount,
  ) {
    _ensureBatchCapacity(_batchCount + 1);
    final int batch = _batchCount;
    final int base = batch * kSparseBatchStride;
    _batches[base] = material;
    _batches[base + 1] = solidFirst;
    _batches[base + 2] = solidCount;
    _batches[base + 3] = alphaFirst;
    _batches[base + 4] = alphaCount;
    _batchCount++;
    return batch;
  }

  void _ensureSolidCapacity(int instances) {
    final int needed = instances * kSparseSolidInstanceStride;
    if (needed <= _solidInstances.length) return;
    _solidInstances = _grow(_solidInstances, needed);
    _bufferGrowths++;
  }

  void _ensureAlphaCapacity(int instances) {
    final int needed = instances * kSparseAlphaInstanceStride;
    if (needed <= _alphaInstances.length) return;
    _alphaInstances = _grow(_alphaInstances, needed);
    _bufferGrowths++;
  }

  void _ensureBatchCapacity(int batches) {
    final int needed = batches * kSparseBatchStride;
    if (needed <= _batches.length) return;
    _batches = _grow(_batches, needed);
    _bufferGrowths++;
  }

  int _solidField(int instance, int field) =>
      _solidInstances[instance * kSparseSolidInstanceStride + field];
  int _alphaField(int instance, int field) =>
      _alphaInstances[instance * kSparseAlphaInstanceStride + field];
  int _batchField(int batch, int field) =>
      _batches[batch * kSparseBatchStride + field];

  int _alphaPageRunCount(int first, int count) {
    if (count == 0) return 0;
    var runs = 1;
    var page = alphaAtlasPage(first);
    final int end = first + count;
    for (var i = first + 1; i < end; i++) {
      final int nextPage = alphaAtlasPage(i);
      if (nextPage != page) {
        runs++;
        page = nextPage;
      }
    }
    return runs;
  }
}

/// Shelf allocator specialised for four-row alpha strips.
final class _SparseAlphaAtlas {
  _SparseAlphaAtlas({required this.width, required this.height})
      : _uploads = Int32List(64 * kSparseAlphaUploadStride);

  final int width;
  final int height;
  final List<Uint8List> _pages = <Uint8List>[];
  Int32List _uploads;

  int pageCount = 0;
  int uploadCount = 0;
  int texelBytes = 0;
  int uploadBytes = 0;
  int growths = 0;

  int _page = 0;
  int _x = 0;
  int _y = 0;
  int _currentUpload = -1;

  int lastPage = 0;
  int lastX = 0;
  int lastY = 0;

  int get retainedCapacityBytes =>
      _pages.length * width * height + _uploads.lengthInBytes;

  Int32List get uploadStorage => _uploads;

  void reset() {
    pageCount = 0;
    uploadCount = 0;
    texelBytes = 0;
    uploadBytes = 0;
    _page = 0;
    _x = 0;
    _y = 0;
    _currentUpload = -1;
  }

  Uint8List pagePixels(int page) {
    if (page < 0 || page >= pageCount) {
      throw RangeError.range(page, 0, pageCount - 1, 'page');
    }
    return _pages[page];
  }

  int uploadField(int upload, int field) {
    if (upload < 0 || upload >= uploadCount) {
      throw RangeError.range(upload, 0, uploadCount - 1, 'upload');
    }
    return _uploads[upload * kSparseAlphaUploadStride + field];
  }

  void allocate(int allocationWidth) {
    if (allocationWidth <= 0 || allocationWidth > width) {
      throw RangeError.range(allocationWidth, 1, width, 'allocationWidth');
    }
    if (_x + allocationWidth > width) {
      _x = 0;
      _y += kStripHeight;
      _currentUpload = -1;
    }
    if (_y + kStripHeight > height) {
      _page++;
      _x = 0;
      _y = 0;
      _currentUpload = -1;
    }
    while (_pages.length <= _page) {
      _pages.add(Uint8List(width * height));
      growths++;
    }
    if (_page + 1 > pageCount) pageCount = _page + 1;

    lastPage = _page;
    lastX = _x;
    lastY = _y;
    _x += allocationWidth;
    texelBytes += allocationWidth * kStripHeight;

    if (_currentUpload < 0) {
      _ensureUploadCapacity(uploadCount + 1);
      _currentUpload = uploadCount++;
      final int base = _currentUpload * kSparseAlphaUploadStride;
      _uploads[base] = _page;
      _uploads[base + 1] = 0;
      _uploads[base + 2] = _y;
      _uploads[base + 3] = _x;
      _uploads[base + 4] = kStripHeight;
      uploadBytes += allocationWidth * kStripHeight;
    } else {
      final int widthField = _currentUpload * kSparseAlphaUploadStride + 3;
      final int oldWidth = _uploads[widthField];
      _uploads[widthField] = _x;
      uploadBytes += (_x - oldWidth) * kStripHeight;
    }
  }

  void writeLastPlacement(
    Uint8List source, {
    required int sourceOffset,
    required int sourceRowStride,
    required int width,
  }) {
    if (width <= 0 || width > this.width || width != lastWidth) {
      throw StateError('write must match the most recent atlas allocation');
    }
    final Uint8List destination = _pages[lastPage];
    for (var row = 0; row < kStripHeight; row++) {
      final int sourceStart = sourceOffset + row * sourceRowStride;
      final int destinationStart = (lastY + row) * this.width + lastX;
      destination.setRange(
        destinationStart,
        destinationStart + width,
        source,
        sourceStart,
      );
    }
  }

  int get lastWidth => _x - lastX;

  void _ensureUploadCapacity(int uploads) {
    final int needed = uploads * kSparseAlphaUploadStride;
    if (needed <= _uploads.length) return;
    _uploads = _grow(_uploads, needed);
    growths++;
  }
}

Int32List _grow(Int32List old, int needed) {
  var length = old.length * 2;
  while (length < needed) {
    length *= 2;
  }
  final Int32List grown = Int32List(length);
  grown.setRange(0, old.length, old);
  return grown;
}

int _positive(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be > 0');
  return value;
}

int _minimum(int value, int minimum, String name) {
  if (value < minimum) {
    throw ArgumentError.value(value, name, 'must be >= $minimum');
  }
  return value;
}

int _min(int a, int b) => a < b ? a : b;
