/// Windows attribute bits absent from Dart's portable FileStat snapshot.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

final _Attributes? _attributes = Platform.isWindows ? _Attributes.load() : null;

int? readWindowsFileAttributes(String path) => _attributes?.read(path);

final class _Attributes {
  _Attributes(DynamicLibrary kernel) {
    _get = kernel.lookupFunction<Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)>('GetFileAttributesW');
    _alloc = kernel.lookupFunction<
        Pointer<Void> Function(IntPtr, Uint32, IntPtr),
        Pointer<Void> Function(int, int, int)>('HeapAlloc');
    _free = kernel.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>),
        int Function(int, int, Pointer<Void>)>('HeapFree');
    _heap = kernel
        .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  }
  static _Attributes? load() {
    try {
      return _Attributes(DynamicLibrary.open('kernel32.dll'));
    } on ArgumentError {
      return null;
    }
  }

  late final int Function(Pointer<Uint16>) _get;
  late final Pointer<Void> Function(int, int, int) _alloc;
  late final int Function(int, int, Pointer<Void>) _free;
  late final int _heap;

  int? read(String path) {
    path = path.replaceAll('/', String.fromCharCode(92));
    // GetFileAttributesW needs the extended namespace for long absolute paths.
    if (path.length >= 248 && !path.startsWith(r'\\?\')) {
      if (path.startsWith(r'\\')) {
        path = r'\\?\UNC\' + path.substring(2);
      } else if (path.length > 2 && path[1] == ':') {
        path = r'\\?\' + path;
      }
    }
    final memory = _alloc(_heap, 8, (path.length + 1) * 2);
    if (memory == nullptr) return null;
    final text = memory.cast<Uint16>();
    try {
      for (var i = 0; i < path.length; i++) {
        text[i] = path.codeUnitAt(i);
      }
      final value = _get(text);
      return value == 0xffffffff ? null : value;
    } finally {
      _free(_heap, 0, memory);
    }
  }
}
