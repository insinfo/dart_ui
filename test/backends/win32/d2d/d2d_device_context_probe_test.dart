/// Which Direct2D interface generation the targets in `d2d_targets.dart`
/// actually are, asked of the runtime rather than assumed from the header.
///
/// The question this file answers is the one the sprite-batch route depends
/// on: `ID2D1SpriteBatch` is created by `ID2D1DeviceContext3`, and the targets
/// this backend builds are made by `ID2D1Factory::CreateDCRenderTarget` and
/// `CreateHwndRenderTarget` - Direct2D 1.0 constructors. Whether the object
/// they return *also* implements the later interfaces is a property of the
/// `d2d1.dll` on the machine, not of the call that made it, so it is probed
/// and printed rather than reasoned about.
///
/// The test asserts only that the probe answers; the answer itself is data,
/// recorded in `doc/architecture/TEXTO_DIRECT2D.md`.
library;

import 'dart:ffi';

import 'package:dart_ui/src/backends/win32/d2d/d2d1_library.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

/// The device-context chain, oldest first, and the sprite batch itself.
///
/// A GUID is written out in full rather than pulled from a header because
/// there is no header here; these are the values `d2d1_1.h`, `d2d1_2.h` and
/// `d2d1_3.h` declare.
const Map<String, String> _interfaces = <String, String>{
  'ID2D1DeviceContext': 'E8F7FE7A-191C-466D-AD95-975678BDA998',
  'ID2D1DeviceContext1': 'D37F57E4-6908-459F-A199-E72F24F79987',
  'ID2D1DeviceContext2': '394EA6A3-0C34-4321-950B-6CA20F0BE6C7',
  'ID2D1DeviceContext3': '235A7496-8351-414C-BCD4-6672AB2D8E00',
  'ID2D1DeviceContext4': '8C427831-3D90-4476-B647-C4FAE349E4DB',
};

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip = D2dSession.platformSkip ?? session.skipReason;

  tearDownAll(session.close);

  test('what a DC render target answers QueryInterface with', () {
    final D2dOffscreenSurface surface = session.surface(32, 32);
    addTearDown(surface.dispose);
    final D2d1Library library = D2d1Library.open().library!;
    final Allocator alloc = library.allocator;
    final Pointer<Guid> iid = alloc.allocate<Guid>(sizeOf<Guid>());
    final Pointer<Pointer<Void>> out =
        alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    addTearDown(() => alloc
      ..free(iid)
      ..free(out));

    final ComObject target = ComObject(surface.renderTarget.pointer);
    final List<String> supported = <String>[];
    final lines = <String>[];
    _interfaces.forEach((String name, String guid) {
      writeGuid(iid, guid);
      out.value = nullptr;
      final int hr = target.queryInterface(iid, out);
      final bool ok = !comFailed(hr) && out.value != nullptr;
      if (ok) {
        supported.add(name);
        ComObject(out.value).release();
      }
      lines.add('  $name  ${ok ? 'yes' : 'no (0x'
          '${hr.toUnsigned(32).toRadixString(16)})'}');
    });

    // ignore: avoid_print
    print('\nID2D1DCRenderTarget QueryInterface:\n${lines.join('\n')}');
    expect(lines, hasLength(_interfaces.length));
  }, skip: skip);
}
