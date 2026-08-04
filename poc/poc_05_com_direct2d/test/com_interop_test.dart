@TestOn('windows')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';
import 'package:win32/win32.dart';

void main() {
  test('GUID has the 16-byte ABI layout required by COM', () {
    expect(sizeOf<GUID>(), 16);
  });

  test('HRESULT helpers distinguish successful and failed calls', () {
    expect(SUCCEEDED(S_OK), isTrue);
    expect(FAILED(S_OK), isFalse);
    expect(FAILED(E_FAIL), isTrue);
  });

  test('GUID serialization preserves all COM fields', () {
    final guid = calloc<GUID>();
    addTearDown(() => calloc.free(guid));
    guid.ref.setGUID('{06152247-6F50-465A-9245-118BFD3B6007}');

    expect(guid.ref.toString().toUpperCase(),
        '{06152247-6F50-465A-9245-118BFD3B6007}');
  });
}
