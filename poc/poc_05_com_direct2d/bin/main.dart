/// POC-05: creates a Direct2D factory and exercises IUnknown through Dart FFI.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _iidID2D1Factory = '{06152247-6F50-465A-9245-118BFD3B6007}';
const _d2d1FactoryTypeSingleThreaded = 0;
const _d3dDriverTypeHardware = 1;
const _d3d11SdkVersion = 7;
const _d3dFeatureLevels = <int>[0xb000, 0xa100, 0xa000];

typedef _D2D1CreateFactoryNative = Int32 Function(
  Uint32 factoryType,
  Pointer<GUID> riid,
  Pointer<Void> options,
  Pointer<Pointer<Void>> factory,
);
typedef _D2D1CreateFactoryDart = int Function(
  int factoryType,
  Pointer<GUID> riid,
  Pointer<Void> options,
  Pointer<Pointer<Void>> factory,
);

typedef _D3D11CreateDeviceNative = Int32 Function(
  Pointer<Void> adapter,
  Uint32 driverType,
  Pointer<Void> software,
  Uint32 flags,
  Pointer<Uint32> featureLevels,
  Uint32 featureLevelsCount,
  Uint32 sdkVersion,
  Pointer<Pointer<Void>> device,
  Pointer<Uint32> selectedFeatureLevel,
  Pointer<Pointer<Void>> immediateContext,
);
typedef _D3D11CreateDeviceDart = int Function(
  Pointer<Void> adapter,
  int driverType,
  Pointer<Void> software,
  int flags,
  Pointer<Uint32> featureLevels,
  int featureLevelsCount,
  int sdkVersion,
  Pointer<Pointer<Void>> device,
  Pointer<Uint32> selectedFeatureLevel,
  Pointer<Pointer<Void>> immediateContext,
);

void main() {
  final initializeResult =
      CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED);
  if (FAILED(initializeResult)) {
    throw WindowsException(initializeResult);
  }

  try {
    using((arena) {
      final iid = arena<GUID>()..ref.setGUID(_iidID2D1Factory);
      final result = arena<Pointer<Void>>();
      final createFactory = DynamicLibrary.open('d2d1.dll')
          .lookupFunction<_D2D1CreateFactoryNative, _D2D1CreateFactoryDart>(
        'D2D1CreateFactory',
      );

      final hr = createFactory(
        _d2d1FactoryTypeSingleThreaded,
        iid,
        nullptr,
        result,
      );
      if (FAILED(hr)) throw WindowsException(hr);
      if (result.value == nullptr) {
        throw StateError(
            'D2D1CreateFactory returned a null interface pointer.');
      }

      // `COMObject` represents the caller-owned out storage. Its first field
      // receives the native interface pointer, which IUnknown then uses as
      // the `this` argument for COM vtable calls.
      final factory = IUnknown(result.cast<COMObject>());
      try {
        final countAfterAddRef = factory.addRef();
        final countAfterRelease = factory.release();

        final queried = arena<Pointer<Void>>();
        final queryHr = factory.queryInterface(iid, queried.cast());
        if (FAILED(queryHr)) throw WindowsException(queryHr);
        if (queried.value == nullptr) {
          throw StateError('QueryInterface returned a null interface pointer.');
        }
        final queriedFactory = IUnknown(queried.cast<COMObject>());
        queriedFactory.detach();
        final queriedReleaseCount = queriedFactory.release();

        print('POC-05: COM + Direct2D factory');
        print('D2D1CreateFactory: success');
        print(
            'IUnknown AddRef -> $countAfterAddRef; Release -> $countAfterRelease');
        print(
            'QueryInterface(ID2D1Factory): success; Release -> $queriedReleaseCount');
      } finally {
        // This pointer is returned by Direct2D; make the release deterministic.
        factory.detach();
        factory.release();
      }

      final featureLevels = arena<Uint32>(_d3dFeatureLevels.length);
      for (var index = 0; index < _d3dFeatureLevels.length; index++) {
        featureLevels[index] = _d3dFeatureLevels[index];
      }
      final deviceStorage = arena<COMObject>();
      final contextStorage = arena<COMObject>();
      final selectedFeatureLevel = arena<Uint32>();
      final createDevice = DynamicLibrary.open('d3d11.dll')
          .lookupFunction<_D3D11CreateDeviceNative, _D3D11CreateDeviceDart>(
        'D3D11CreateDevice',
      );
      final deviceHr = createDevice(
        nullptr,
        _d3dDriverTypeHardware,
        nullptr,
        0,
        featureLevels,
        _d3dFeatureLevels.length,
        _d3d11SdkVersion,
        deviceStorage.cast(),
        selectedFeatureLevel,
        contextStorage.cast(),
      );
      if (FAILED(deviceHr)) throw WindowsException(deviceHr);

      final device = IUnknown(deviceStorage);
      final context = IUnknown(contextStorage);
      try {
        print('D3D11CreateDevice: success '
            '(feature level 0x${selectedFeatureLevel.value.toRadixString(16)})');
        print('✅ COM factory and D3D11 device lifecycle passed.');
      } finally {
        context.detach();
        context.release();
        device.detach();
        device.release();
      }
    });
  } finally {
    CoUninitialize();
  }
}
