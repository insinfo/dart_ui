/// COM, checked where it can be checked everywhere and where it cannot.
///
/// The file splits deliberately in two, and the split is the point.
///
/// **What runs on every platform.** A `GUID`'s sixteen bytes, an `HRESULT`'s
/// sign and its name. Neither needs a COM runtime - they are layout and
/// arithmetic - and both are exactly the things whose failure is silent. A GUID
/// laid out wrong makes `QueryInterface` answer `E_NOINTERFACE` for an interface
/// the object certainly implements, and the backend then reports "this driver is
/// too old" for the rest of its life. An `HRESULT` compared unsigned never
/// matches `DXGI_ERROR_DEVICE_REMOVED`, so device-loss detection quietly stops
/// firing. A test that only did a live `QueryInterface` would pass on a machine
/// whose driver happens to answer and prove neither.
///
/// **What needs a real object.** Reference counting cannot be tested against a
/// fake: the whole question is whether `AddRef` and `Release` reach the same
/// object the driver is counting. So those tests open a Direct3D 11 device -
/// the one COM object this repository can create on demand - and skip by name
/// where there is none, which on the Linux and macOS halves of CI is every run.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('a GUID', () {
    test('serialises as three integers and eight bytes, not sixteen bytes', () {
      // IID_ID3D11Device, and the one assertion in this file that would catch
      // the mistake the whole Guid class exists to prevent. The canonical text
      // is db6f6ddb-ac77-4e88-8253-819df9bbf140; the first three groups are
      // *numbers* and reach memory little-endian, the last two are *bytes* and
      // reach it in the order written.
      final bytes = iidId3d11Device.toBytes();

      expect(bytes, <int>[
        0xdb, 0x6d, 0x6f, 0xdb, // Data1 = 0xdb6f6ddb, byte-reversed
        0x77, 0xac, //             Data2 = 0xac77, byte-reversed
        0x88, 0x4e, //             Data3 = 0x4e88, byte-reversed
        0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40, // Data4, in order
      ]);
      // Said the other way round, because this is the shape a naive
      // implementation produces and it is wrong in three groups out of four.
      expect(bytes.sublist(0, 4), isNot(<int>[0xdb, 0x6f, 0x6d, 0xdb]));
    });

    test('and IID_IUnknown, whose tail is the part everyone recognises', () {
      // 00000000-0000-0000-C000-000000000046. The three leading zero fields
      // make the byte-order question invisible, which is exactly why this is
      // *not* the only GUID asserted above: it would pass with any endianness.
      expect(iidIUnknown.toBytes(), <int>[
        0, 0, 0, 0, //
        0, 0, //
        0, 0, //
        0xC0, 0, 0, 0, 0, 0, 0, 0x46,
      ]);
    });

    test('round-trips through its canonical text', () {
      const text = '50c83a1c-e072-4c48-87b0-3630fa36a6d0';
      expect(Guid.parse(text).toString(), text);
      // Braces are what Windows tooling prints, so they are accepted.
      expect(Guid.parse('{$text}'), Guid.parse(text));
      expect(Guid.parse('  $text  '), Guid.parse(text));
    });

    test('equality is by value, so an IID can be a map key', () {
      final a = Guid.parse('54ec77fa-1377-44e6-8c32-88fd5f44c84c');
      expect(a, iidIdxgiDevice);
      expect(a.hashCode, iidIdxgiDevice.hashCode);
      expect(a == iidIdxgiFactory2, isFalse);
    });

    test('a malformed spelling is a FormatException, not a wrong GUID', () {
      // The failure mode this refuses: a GUID that parses to *something* is
      // indistinguishable at the call site from one that parsed correctly, and
      // the only symptom is an interface that is never found.
      for (final String bad in <String>[
        'not-a-guid',
        '50c83a1c-e072-4c48-87b0-3630fa36a6d', // one digit short
        '50c83a1ce0724c4887b03630fa36a6d0', // no dashes
        '50c83a1g-e072-4c48-87b0-3630fa36a6d0', // 'g' is not hex
      ]) {
        expect(() => Guid.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('writes itself into native memory the same way it does into a list',
        () {
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Uint8> pointer = iidIdxgiFactory2.allocateIn(arena);
      expect(pointer.asTypedList(16), iidIdxgiFactory2.toBytes());
    });
  });

  group('an HRESULT', () {
    test('is signed, so a DXGI error compares equal to its constant', () {
      // The bug this normalisation exists for: dart:ffi returns an Int32 as a
      // signed Dart int, and 0x887A0005 written in Dart source is *positive*
      // because Dart integers are 64-bit. Comparing the two directly is never
      // equal, and device-loss detection silently stops firing.
      expect(hresult(0x887A0005), dxgiErrorDeviceRemoved);
      expect(0x887A0005 == dxgiErrorDeviceRemoved, isFalse);
      expect(hresult(-2005270523), dxgiErrorDeviceRemoved);
      expect(hresult(0x00000000), sOk);
    });

    test('splits success from failure on the sign bit and nothing else', () {
      expect(succeeded(sOk), isTrue);
      // S_FALSE is a *success*. Treating it as an error is how a legitimate
      // "nothing to do" becomes a reported failure.
      expect(succeeded(sFalse), isTrue);
      // And so is DXGI_STATUS_OCCLUDED, which is what Present returns for a
      // window nothing can see.
      expect(succeeded(dxgiStatusOccluded), isTrue);
      expect(failed(dxgiStatusOccluded), isFalse);

      expect(failed(eNoInterface), isTrue);
      expect(failed(0x887A0001), isTrue, reason: 'unsigned literal, failure');
      expect(succeeded(eFail), isFalse);
    });

    test('names the codes this renderer branches on', () {
      // Both halves, always: the name is what a reader recognises, the hex is
      // what a search engine and the driver documentation index.
      expect(hresultName(eNoInterface), 'E_NOINTERFACE (0x80004002)');
      expect(hresultName(eInvalidArg), 'E_INVALIDARG (0x80070057)');
      expect(hresultName(0x887A0001), 'DXGI_ERROR_INVALID_CALL (0x887a0001)');
      expect(
        hresultName(dxgiErrorDeviceRemoved),
        'DXGI_ERROR_DEVICE_REMOVED (0x887a0005)',
      );
      expect(hresultName(dxgiErrorDeviceReset), contains('DEVICE_RESET'));
      expect(hresultName(dxgiStatusOccluded), contains('DXGI_STATUS_OCCLUDED'));
      expect(hresultName(sOk), 'S_OK (0x00000000)');
    });

    test('a code with no name still reports its hexadecimal value', () {
      // Every unnamed code is padded to eight digits, which is what makes two
      // of them comparable by eye in a log.
      expect(hresultName(0x80070666), '0x80070666');
      expect(hresultName(0x00000042), '0x00000042');
      // A named code keeps its name even when it is a success, so the two
      // branches of hresultName are both exercised against the same input
      // shape.
      expect(hresultName(0x00000001), 'S_FALSE (0x00000001)');
    });

    test('checkHresult passes a success through and throws on failure', () {
      expect(checkHresult(sOk, 'ID3D11Device::CreateTexture2D'), sOk);
      expect(checkHresult(sFalse, 'anything'), sFalse);

      expect(
        () => checkHresult(0x887A0001, 'ID3D11Device::CreateBuffer',
            detail: '4096 bytes'),
        throwsA(
          isA<ComError>()
              .having((e) => e.hresult, 'hresult', dxgiErrorInvalidCall)
              .having(
                  (e) => e.operation, 'operation', 'ID3D11Device::CreateBuffer')
              .having(
                  (e) => e.name, 'name', contains('DXGI_ERROR_INVALID_CALL'))
              .having((e) => e.toString(), 'toString', contains('4096 bytes')),
        ),
      );
    });
  });

  group('a ComBag', () {
    test('releases last-acquired-first', () {
      // Not cosmetic: COM objects hold references to each other - a swap chain
      // holds the device, a render-target view holds the texture - and
      // releasing the device while a swap chain still points at it leaves the
      // last release running on a thread nobody chose.
      final order = <int>[];
      final bag = ComBag();
      for (var i = 0; i < 4; i++) {
        bag.keepRelease(() => order.add(i));
      }
      expect(bag.length, 4);
      bag.dispose();
      expect(order, <int>[3, 2, 1, 0]);
    });

    test('disposing twice releases once', () {
      var releases = 0;
      final bag = ComBag()..keepRelease(() => releases++);
      bag
        ..dispose()
        ..dispose();
      expect(releases, 1);
    });
  });

  group('a live COM object', () {
    final session = _ComSession.open();
    tearDownAll(session.close);

    test('AddRef and Release move the count by exactly one each', () {
      // Counted rather than assumed. COM has no getter for the reference
      // count; ComObject.refCount takes one and immediately drops it, which is
      // balanced by construction, so asking cannot change the answer.
      final device = session.device!;
      final int before = device.refCount;
      expect(before, greaterThan(0));

      expect(device.addRef(), before + 1);
      expect(device.refCount, before + 1);
      expect(device.release(), before);
      expect(device.refCount, before,
          reason: 'an AddRef matched by a Release leaves the count where it '
              'started; anything else is the leak or the double free this '
              'class exists to make visible');
    }, skip: session.skipReason);

    test('QueryInterface for an interface the object has takes a reference',
        () {
      // ID3D11Device and IDXGIDevice are the same object, so a successful QI
      // is visible as an increment on the count of the object that answered -
      // which is the proof that the returned pointer is a *reference* and has
      // to be released independently.
      final device = session.device!;
      final int before = device.refCount;

      final ComObject? dxgi =
          device.queryInterface(iidIdxgiDevice, interfaceName: 'IDXGIDevice');
      expect(dxgi, isNotNull);
      expect(dxgi!.interfaceName, 'IDXGIDevice');
      expect(device.refCount, before + 1);

      dxgi.dispose();
      expect(device.refCount, before,
          reason: 'the interface QI handed back owned one reference, and '
              'disposing it must give exactly that one back');
    }, skip: session.skipReason);

    test('QueryInterface for an interface it does not have answers null', () {
      // Null and not an exception: "does this driver expose that interface" is
      // a question with two legitimate answers. The GUID below is not any
      // interface; a device that answered it would mean the GUID never reached
      // the driver.
      final device = session.device!;
      final int before = device.refCount;

      final ComObject? nothing = device
          .queryInterface(Guid.parse('11112222-3333-4444-5555-666677778888'));
      expect(nothing, isNull);
      expect(device.refCount, before,
          reason: 'a refused QueryInterface must not have taken a reference');
    }, skip: session.skipReason);

    test('the raw form reports E_NOINTERFACE rather than hiding it', () {
      final device = session.device!;
      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();

      expect(
        device.queryInterfaceInto(
            Guid.parse('11112222-3333-4444-5555-666677778888'), out),
        eNoInterface,
      );
      expect(out.value, nullptr);
      // And the positive case through the same door, so the two are compared
      // against each other rather than each against a hand-written constant.
      expect(device.queryInterfaceInto(iidIUnknown, out), sOk);
      expect(out.value, isNot(nullptr));
      ComObject(out.value).dispose();
    }, skip: session.skipReason);

    test('every COM object answers a QueryInterface for IUnknown', () {
      final ComObject? unknown = session.device!.queryInterface(iidIUnknown);
      expect(unknown, isNotNull);
      unknown!.dispose();
    }, skip: session.skipReason);

    test('disposing twice releases once', () {
      // The idempotence DisposableMixin supplies is not a convenience here: it
      // is the difference between a leak and a double free, and both paths are
      // routinely taken by the same error handler.
      final device = session.device!;
      final ComObject copy =
          device.queryInterface(iidIUnknown, interfaceName: 'IUnknown')!;
      final int before = device.refCount;

      copy
        ..dispose()
        ..dispose()
        ..dispose();

      expect(device.refCount, before - 1,
          reason: 'three disposes released one reference; a second real '
              'Release would have taken the count below where it belongs and '
              'the next use would read freed memory that still looks like a '
              'vtable');
    }, skip: session.skipReason);

    test('a disposed wrapper refuses to be used again', () {
      final ComObject copy = session.device!.queryInterface(iidIUnknown)!
        ..dispose();
      expect(() => copy.refCount, throwsStateError);
      expect(copy.addRef, throwsStateError);
    }, skip: session.skipReason);

    test('toString names the interface and the pointer', () {
      final device = session.device!;
      expect(device.toString(), startsWith('ID3D11Device(0x'));
    }, skip: session.skipReason);
  });
}

/// One raw D3D11 device for the whole file, or the reason there is none.
///
/// Raw rather than a `D3d11RenderDevice`: this file is about `ComObject`, and
/// going through the renderer would drag shader compilation into a test that
/// has nothing to say about it.
final class _ComSession {
  _ComSession._(this.device, this.context, this.skipReason, this._arena);

  final D3d11Device? device;
  final D3d11DeviceContext? context;

  /// Null when a device opened. A string - which `skip:` accepts - when it did
  /// not, so a run with no GPU names what was missing instead of passing
  /// quietly.
  final String? skipReason;

  final NativeArena? _arena;

  static _ComSession open() {
    if (!Platform.isWindows) {
      return _ComSession._(
          null,
          null,
          'COM objects need Windows; this is ${Platform.operatingSystem}',
          null);
    }
    if (!NativeAllocator.isAvailable) {
      return _ComSession._(
          null, null, 'no native allocator on this machine', null);
    }
    try {
      return _open();
    } on Object catch (error) {
      return _ComSession._(
          null, null, 'opening a D3D11 device threw: $error', null);
    }
  }

  static _ComSession _open() {
    final D3d11LibraryLoad load = D3d11Libraries.open();
    if (!load.isLoaded) {
      return _ComSession._(null, null,
          'no d3d11.dll/dxgi.dll: ${load.diagnostics.join('; ')}', null);
    }
    final api = D3d11Api(load.libraries!);
    final arena = NativeArena();
    final Pointer<Uint32> levels =
        arena.allocate<Uint32>(4 * kD3d11FeatureLevels.length);
    for (var i = 0; i < kD3d11FeatureLevels.length; i++) {
      levels[i] = kD3d11FeatureLevels[i];
    }
    final Pointer<Pointer<Void>> deviceOut = arena.allocateOutPointer();
    final Pointer<Pointer<Void>> contextOut = arena.allocateOutPointer();
    final Pointer<Uint32> selected = arena.allocate<Uint32>(4);

    for (final int driverType in <int>[
      d3dDriverTypeHardware,
      d3dDriverTypeWarp
    ]) {
      // Two attempts per driver type: the full list, then the list without
      // 11.1, which a pre-11.1 runtime rejects wholesale rather than skipping.
      for (var skip = 0; skip < 2; skip++) {
        final int hr = hresult(api.createDevice(
          nullptr,
          driverType,
          nullptr,
          d3d11CreateDeviceBgraSupport,
          Pointer<Uint32>.fromAddress(levels.address + skip * 4),
          kD3d11FeatureLevels.length - skip,
          d3d11SdkVersion,
          deviceOut,
          selected,
          contextOut,
        ));
        if (succeeded(hr) && deviceOut.value != nullptr) {
          return _ComSession._(
            D3d11Device(deviceOut.value),
            D3d11DeviceContext(contextOut.value),
            null,
            arena,
          );
        }
        if (hr != eInvalidArg) break;
      }
    }
    arena.dispose();
    return _ComSession._(
        null, null, 'D3D11CreateDevice refused every driver type', null);
  }

  void close() {
    context?.dispose();
    device?.dispose();
    _arena?.dispose();
  }
}
