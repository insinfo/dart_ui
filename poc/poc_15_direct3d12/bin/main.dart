/// POC-15: Direct3D 12 Initialization in pure Dart.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _d3dFeatureLevel11_0 = 0xb000;
const _iidID3D12Device = '{189819f1-1db6-4b57-be54-1821339b85f7}';

typedef _D3D12CreateDeviceNative = Int32 Function(
  Pointer<Void> pAdapter,
  Int32 minimumFeatureLevel,
  Pointer<GUID> riid,
  Pointer<Pointer<Void>> ppDevice,
);

typedef _D3D12CreateDeviceDart = int Function(
  Pointer<Void> pAdapter,
  int minimumFeatureLevel,
  Pointer<GUID> riid,
  Pointer<Pointer<Void>> ppDevice,
);

void main() {
  print('POC-15: Direct3D 12 Initialization\n');

  final initializeResult =
      CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED);
  if (FAILED(initializeResult)) {
    throw WindowsException(initializeResult);
  }

  try {
    using((arena) {
      final iid = arena<GUID>()..ref.setGUID(_iidID3D12Device);
      final deviceStorage = arena<Pointer<Void>>();

      final d3d12Lib = DynamicLibrary.open('d3d12.dll');
      final createDevice = d3d12Lib
          .lookupFunction<_D3D12CreateDeviceNative, _D3D12CreateDeviceDart>(
        'D3D12CreateDevice',
      );

      // Attempt to create a D3D12 device (Feature Level 11.0 minimum)
      final deviceHr = createDevice(
        nullptr,
        _d3dFeatureLevel11_0,
        iid,
        deviceStorage,
      );

      if (FAILED(deviceHr)) {
        throw WindowsException(deviceHr);
      }

      if (deviceStorage.value == nullptr) {
        throw StateError(
            'D3D12CreateDevice returned a null interface pointer.');
      }

      // Wrap in IUnknown to manage lifecycle
      final device = IUnknown(deviceStorage.cast<COMObject>());
      try {
        print('✅ D3D12CreateDevice: success');
        print('   - ID3D12Device created successfully.');
        print('✅ Direct3D 12 FFI binding works!');
      } finally {
        device.detach();
        device.release();
      }
    });
  } finally {
    CoUninitialize();
  }
}
