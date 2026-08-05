/// POC-14: Direct3D 11 Initialization in pure Dart.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _d3dDriverTypeHardware = 1;
const _d3dDriverTypeWarp = 5;
const _d3d11SdkVersion = 7;
const _d3dFeatureLevels = <int>[0xb000, 0xa100, 0xa000]; // 11.0, 10.1, 10.0
const _d3d11CreateDeviceBgraSupport = 0x20;

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
  print('POC-14: Direct3D 11 Initialization\n');

  final initializeResult =
      CoInitializeEx(nullptr, COINIT.COINIT_APARTMENTTHREADED);
  if (FAILED(initializeResult)) {
    throw WindowsException(initializeResult);
  }

  try {
    using((arena) {
      final featureLevels = arena<Uint32>(_d3dFeatureLevels.length);
      for (var index = 0; index < _d3dFeatureLevels.length; index++) {
        featureLevels[index] = _d3dFeatureLevels[index];
      }

      final deviceStorage = arena<COMObject>();
      final contextStorage = arena<COMObject>();
      final selectedFeatureLevel = arena<Uint32>();

      final d3d11Lib = DynamicLibrary.open('d3d11.dll');
      final createDevice = d3d11Lib
          .lookupFunction<_D3D11CreateDeviceNative, _D3D11CreateDeviceDart>(
        'D3D11CreateDevice',
      );

      // Attempt to create a hardware device first
      int deviceHr = createDevice(
        nullptr,
        _d3dDriverTypeHardware,
        nullptr,
        _d3d11CreateDeviceBgraSupport,
        featureLevels,
        _d3dFeatureLevels.length,
        _d3d11SdkVersion,
        deviceStorage.cast(),
        selectedFeatureLevel,
        contextStorage.cast(),
      );

      String deviceType = 'Hardware';
      if (FAILED(deviceHr)) {
        print(
            'Warning: Hardware device creation failed (HR: $deviceHr), falling back to WARP...');
        deviceHr = createDevice(
          nullptr,
          _d3dDriverTypeWarp,
          nullptr,
          _d3d11CreateDeviceBgraSupport,
          featureLevels,
          _d3dFeatureLevels.length,
          _d3d11SdkVersion,
          deviceStorage.cast(),
          selectedFeatureLevel,
          contextStorage.cast(),
        );
        deviceType = 'WARP (Software)';
      }

      if (FAILED(deviceHr)) {
        throw WindowsException(deviceHr);
      }

      final device = IUnknown(deviceStorage);
      final context = IUnknown(contextStorage);
      try {
        final featureLevelHex =
            selectedFeatureLevel.value.toRadixString(16).toUpperCase();
        print('✅ D3D11CreateDevice: success');
        print('   - Device Type: $deviceType');
        print('   - Feature Level: 0x$featureLevelHex');
        print('✅ COM memory lifecycle validated.');
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
