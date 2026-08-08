import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Frame transport 3 of 3: IOSurface.
//
// Shared memory removes the copies but the host still has to wrap the bytes in
// a CGImage for every frame, and the WindowServer copies them again when it
// composites. An IOSurface is the buffer type the window server itself uses:
// hand the layer the surface once and later frames are just writes into pages
// the compositor is already scanning out.
//
// Crossing the process boundary uses the global-surface path
// (kIOSurfaceIsGlobal + IOSurfaceGetID / IOSurfaceLookup). Apple deprecated it
// in favour of mach-port passing, which needs a port right to travel between
// the processes - a pipe cannot carry one. The deprecated call still resolves
// and works on macOS 14; if it ever stops, the replacement is an XPC channel,
// not a different surface API.
// ---------------------------------------------------------------------------

final DynamicLibrary _ioSurfaceLib = DynamicLibrary.open(
    '/System/Library/Frameworks/IOSurface.framework/IOSurface');
final DynamicLibrary _coreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

typedef _VoidPtr = Pointer<Void>;

/// 'BGRA' as a big-endian FourCC, matching kCGImageAlphaPremultipliedFirst +
/// kCGBitmapByteOrder32Little on little-endian hardware.
const int kPixelFormatBGRA = 0x42475241;

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

_VoidPtr _key(String name) => _ioSurfaceLib.lookup<_VoidPtr>(name).value;

class IOSurfaceFrame {
  IOSurfaceFrame._(this._surface, this.id, this.width, this.height,
      this.bytesPerRow, this._allocSize);

  final _VoidPtr _surface;
  final int id;
  final int width;
  final int height;
  final int bytesPerRow;
  final int _allocSize;

  bool _closed = false;

  static IOSurfaceFrame create({required int width, required int height}) {
    final properties = _cfDictionaryCreateMutable(
      nullptr,
      0,
      // These two are structs, not pointers: the symbol's address IS the
      // argument, so no dereference here - unlike the CFString keys below.
      _coreFoundation.lookup<Void>('kCFTypeDictionaryKeyCallBacks'),
      _coreFoundation.lookup<Void>('kCFTypeDictionaryValueCallBacks'),
    );
    if (properties == nullptr) throw StateError('CFDictionaryCreateMutable');

    final slot = calloc<Int32>();
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
    putInt('kIOSurfacePixelFormat', kPixelFormatBGRA);
    // Without this the surface is private to this process and IOSurfaceLookup
    // in the host returns null.
    _cfDictionarySetValue(properties, _key('kIOSurfaceIsGlobal'),
        _coreFoundation.lookup<_VoidPtr>('kCFBooleanTrue').value);
    calloc.free(slot);

    final surface = _ioSurfaceCreate(properties);
    _cfRelease(properties);
    if (surface == nullptr) throw StateError('IOSurfaceCreate returned null');

    return IOSurfaceFrame._(
      surface,
      _ioSurfaceGetID(surface),
      width,
      height,
      _ioSurfaceGetBytesPerRow(surface),
      _ioSurfaceGetAllocSize(surface),
    );
  }

  /// Writes into the surface while holding the lock the compositor honours.
  void withPixels(void Function(Uint8List pixels) write) {
    final seed = calloc<Uint32>();
    try {
      final locked = _ioSurfaceLock(_surface, 0, seed);
      if (locked != 0) throw StateError('IOSurfaceLock -> $locked');
      final base = _ioSurfaceGetBaseAddress(_surface);
      write(base.cast<Uint8>().asTypedList(_allocSize));
      _ioSurfaceUnlock(_surface, 0, seed);
    } finally {
      calloc.free(seed);
    }
  }

  void fillBgra(int blue, int green, int red, {int alpha = 255}) {
    withPixels((pixels) {
      for (var row = 0; row < height; row++) {
        final start = row * bytesPerRow;
        for (var x = 0; x < width; x++) {
          final i = start + x * 4;
          pixels[i] = blue;
          pixels[i + 1] = green;
          pixels[i + 2] = red;
          pixels[i + 3] = alpha;
        }
      }
    });
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _cfRelease(_surface);
  }
}
