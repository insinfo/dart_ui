/// `IOSurface` bindings: the frame transport ADR 0001 chose.
///
/// The numbers behind that choice, `macos-14` arm64, minimum of 120 frames:
///
///     size        pipe        shm         iosurface
///     480x320       975 us      831 us     66 us
///     1920x1080  14 361 us   10 363 us    107 us
///     3840x2160  56 092 us   45 202 us    130 us
///
/// The frame grows 54x and the cost grows 2x, because nothing in the present
/// path is per-pixel: the surface is handed to the layer once and every later
/// frame only marks the contents changed. `shm` stays within 1.4x of the pipe
/// at every size, which proves the dominant cost is the per-frame `CGImage`
/// rebuild plus the CoreAnimation upload - both per-pixel, both untouched by
/// shared memory, both removed by this.
///
/// Two things this file does NOT do, on purpose:
///
///   * it does not depend on `package:ffi`. `dart_ui` has one dependency
///     (`meta`, annotations only) and a windowing backend is a bad reason to
///     add a second, so the handful of `malloc`/`free` calls needed here are
///     bound directly.
///   * it does not open a library at import time. Every handle below is a lazy
///     top-level final, so importing this file on Windows or Linux - which
///     `probe()` does, transitively - costs nothing and throws nothing.
library;

import 'dart:ffi';
import 'dart:typed_data';

typedef _VoidPtr = Pointer<Void>;

final DynamicLibrary _ioSurfaceLib = DynamicLibrary.open(
  '/System/Library/Frameworks/IOSurface.framework/IOSurface',
);
final DynamicLibrary _coreFoundation = DynamicLibrary.open(
  '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
);
final DynamicLibrary _process = DynamicLibrary.process();

/// `calloc(count, size)`. Zeroed rather than `malloc`ed because every
/// structure handed to Mach below has reserved fields the kernel reads.
final _calloc = _process.lookupFunction<_VoidPtr Function(IntPtr, IntPtr),
    _VoidPtr Function(int, int)>('calloc');
final _free = _process
    .lookupFunction<Void Function(_VoidPtr), void Function(_VoidPtr)>('free');

/// Zero-initialised scratch memory for FFI calls.
///
/// Allocation lives here rather than in a `package:ffi` `Allocator` for the
/// reason in the library comment. Every caller frees in a `finally`.
Pointer<T> macosCalloc<T extends NativeType>(int bytes) =>
    _calloc(1, bytes).cast<T>();

void macosFree(Pointer<NativeType> pointer) => _free(pointer.cast());

/// 'BGRA' as a big-endian FourCC, which is what
/// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little` means on
/// little-endian hardware - and therefore exactly `PixelFormat.bgra8888`.
const int kMacosPixelFormatBgra = 0x42475241;

const int _kCFNumberSInt32Type = 3;

final _cfDictionaryCreateMutable = _coreFoundation.lookupFunction<
    _VoidPtr Function(_VoidPtr, IntPtr, _VoidPtr, _VoidPtr),
    _VoidPtr Function(
        _VoidPtr, int, _VoidPtr, _VoidPtr)>('CFDictionaryCreateMutable');
final _cfDictionarySetValue = _coreFoundation.lookupFunction<
    Void Function(_VoidPtr, _VoidPtr, _VoidPtr),
    void Function(_VoidPtr, _VoidPtr, _VoidPtr)>('CFDictionarySetValue');
final _cfNumberCreate = _coreFoundation.lookupFunction<
    _VoidPtr Function(_VoidPtr, Int32, _VoidPtr),
    _VoidPtr Function(_VoidPtr, int, _VoidPtr)>('CFNumberCreate');
final _cfRelease = _coreFoundation.lookupFunction<Void Function(_VoidPtr),
    void Function(_VoidPtr)>('CFRelease');

final _ioSurfaceCreate = _ioSurfaceLib.lookupFunction<
    _VoidPtr Function(_VoidPtr),
    _VoidPtr Function(_VoidPtr)>('IOSurfaceCreate');
final _ioSurfaceGetID = _ioSurfaceLib.lookupFunction<Uint32 Function(_VoidPtr),
    int Function(_VoidPtr)>('IOSurfaceGetID');
final _ioSurfaceLock = _ioSurfaceLib.lookupFunction<
    Int32 Function(_VoidPtr, Uint32, Pointer<Uint32>),
    int Function(_VoidPtr, int, Pointer<Uint32>)>('IOSurfaceLock');
final _ioSurfaceUnlock = _ioSurfaceLib.lookupFunction<
    Int32 Function(_VoidPtr, Uint32, Pointer<Uint32>),
    int Function(_VoidPtr, int, Pointer<Uint32>)>('IOSurfaceUnlock');
final _ioSurfaceGetBaseAddress = _ioSurfaceLib.lookupFunction<
    _VoidPtr Function(_VoidPtr),
    _VoidPtr Function(_VoidPtr)>('IOSurfaceGetBaseAddress');
final _ioSurfaceGetAllocSize = _ioSurfaceLib.lookupFunction<
    IntPtr Function(_VoidPtr), int Function(_VoidPtr)>('IOSurfaceGetAllocSize');
final _ioSurfaceGetBytesPerRow = _ioSurfaceLib.lookupFunction<
    IntPtr Function(_VoidPtr),
    int Function(_VoidPtr)>('IOSurfaceGetBytesPerRow');
final _ioSurfaceCreateMachPort = _ioSurfaceLib.lookupFunction<
    Uint32 Function(_VoidPtr),
    int Function(_VoidPtr)>('IOSurfaceCreateMachPort');

/// Dereferences one of IOSurface's exported `CFStringRef` property keys.
_VoidPtr _key(String name) => _ioSurfaceLib.lookup<_VoidPtr>(name).value;

/// Raised when a surface cannot be created or locked.
///
/// A distinct type so a caller can tell "the compositor refused us memory"
/// apart from a programming error, and recover by shrinking rather than by
/// dying.
final class MacosSurfaceError extends Error {
  MacosSurfaceError(this.operation, {this.status});

  final String operation;
  final int? status;

  @override
  String toString() => status == null
      ? 'MacosSurfaceError: $operation'
      : 'MacosSurfaceError: $operation -> $status';
}

/// The part of a surface `MacosSurfacePool` needs.
///
/// An interface rather than the concrete class so the pool's invariant - never
/// write the slot you just presented - can be tested on a machine with no
/// IOSurface. That invariant is arithmetic, and arithmetic should not need a
/// compositor to verify.
abstract interface class MacosPoolSurface {
  int get id;
  int get width;
  int get height;
  int get bytesPerRow;
  bool get isDisposed;

  void withPixels(void Function(Uint8List pixels) write);

  /// A send right naming this surface, for the rendezvous handoff.
  int createMachPort();

  void dispose();
}

/// One `IOSurface` owned by this process.
///
/// Ownership matters and is the reason crash recovery is cheap: the surface
/// belongs to Dart, the host is a consumer of pixels. The measured consequence
/// (run `31272239992`) is that a `SIGKILL`ed host leaves the surface intact,
/// a replacement host reattaches the *same* surface, and the framebuffer never
/// has to be re-uploaded.
final class MacosIOSurface implements MacosPoolSurface {
  MacosIOSurface._(
    this._surface,
    this.id,
    this.width,
    this.height,
    this.bytesPerRow,
    this._allocSize,
  );

  final _VoidPtr _surface;

  /// The global surface id. Only meaningful when [isGlobal]; the deprecated
  /// `IOSurfaceLookup` path is the only thing that consumes it.
  @override
  final int id;

  @override
  final int width;

  @override
  final int height;

  /// The surface's own stride, which is NOT `width * 4`: IOSurface rounds up
  /// for alignment. `Framebuffer` carries this value for the same reason.
  @override
  final int bytesPerRow;

  final int _allocSize;

  bool _disposed = false;
  @override
  bool get isDisposed => _disposed;

  /// Cached typed view of the mapped pages.
  ///
  /// Rebuilt on every lock, never cached across locks: `IOSurfaceLock` does
  /// not promise the same base address twice, which is the same warning
  /// `Frame.framebuffer` carries in `renderer.dart`.
  static MacosIOSurface create({
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) {
      throw MacosSurfaceError('IOSurfaceCreate: ${width}x$height');
    }
    final properties = _cfDictionaryCreateMutable(
      nullptr,
      0,
      // Struct globals, not pointers to structs: the symbol's address IS the
      // argument here, unlike the CFString keys below.
      _coreFoundation.lookup<Void>('kCFTypeDictionaryKeyCallBacks'),
      _coreFoundation.lookup<Void>('kCFTypeDictionaryValueCallBacks'),
    );
    if (properties == nullptr) {
      throw MacosSurfaceError('CFDictionaryCreateMutable');
    }

    final slot = macosCalloc<Int32>(4);
    try {
      void putInt(String key, int value) {
        slot.value = value;
        final number =
            _cfNumberCreate(nullptr, _kCFNumberSInt32Type, slot.cast());
        _cfDictionarySetValue(properties, _key(key), number);
        _cfRelease(number);
      }

      final bytesPerRow = width * 4;
      putInt('kIOSurfaceWidth', width);
      putInt('kIOSurfaceHeight', height);
      putInt('kIOSurfaceBytesPerElement', 4);
      putInt('kIOSurfaceBytesPerRow', bytesPerRow);
      putInt('kIOSurfaceAllocSize', bytesPerRow * height);
      putInt('kIOSurfacePixelFormat', kMacosPixelFormatBgra);
    } finally {
      macosFree(slot);
    }

    final surface = _ioSurfaceCreate(properties);
    _cfRelease(properties);
    if (surface == nullptr) throw MacosSurfaceError('IOSurfaceCreate');

    return MacosIOSurface._(
      surface,
      _ioSurfaceGetID(surface),
      width,
      height,
      _ioSurfaceGetBytesPerRow(surface),
      _ioSurfaceGetAllocSize(surface),
    );
  }

  /// A send right naming this surface, for `IOSurfaceLookupFromMachPort`.
  ///
  /// The right is deliberately not deallocated afterwards. Apple's samples do
  /// deallocate it; the trade recorded in
  /// `doc/logs/MACH_PORT_HANDOFF_2026-08-08.md` is that leaking one port name
  /// per surface has no failure mode, while dropping the last right to a
  /// surface the compositor is scanning out has an ugly one. Revisit when a
  /// long-running process starts resizing thousands of times.
  @override
  int createMachPort() {
    _checkAlive();
    final port = _ioSurfaceCreateMachPort(_surface);
    if (port == 0) throw MacosSurfaceError('IOSurfaceCreateMachPort');
    return port;
  }

  /// Runs [write] with the surface locked, so the compositor does not scan out
  /// a half-written frame within this call.
  ///
  /// The lock does not make double buffering unnecessary: it is advisory
  /// between IOSurface clients, and the 3 339 us unsynchronised write window
  /// measured in `doc/logs/PRESENT_PACING_2026-08-08.md` is exactly the time
  /// this call spends holding it. `MacosSurfacePool` is what removes the risk.
  @override
  void withPixels(void Function(Uint8List pixels) write) {
    _checkAlive();
    final seed = macosCalloc<Uint32>(4);
    try {
      final locked = _ioSurfaceLock(_surface, 0, seed);
      if (locked != 0) throw MacosSurfaceError('IOSurfaceLock', status: locked);
      try {
        final base = _ioSurfaceGetBaseAddress(_surface);
        if (base == nullptr) throw MacosSurfaceError('IOSurfaceGetBaseAddress');
        write(base.cast<Uint8>().asTypedList(_allocSize));
      } finally {
        _ioSurfaceUnlock(_surface, 0, seed);
      }
    } finally {
      macosFree(seed);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cfRelease(_surface);
  }

  void _checkAlive() {
    if (_disposed) throw MacosSurfaceError('surface used after dispose');
  }
}
