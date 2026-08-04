import 'dart:ffi';
import 'dart:io';

void main() {
  print('OS: ${Platform.operatingSystem}');
  print('OS Version: ${Platform.operatingSystemVersion}');
  print('Dart: ${Platform.version}');
  print('Pointer size: ${sizeOf<Pointer<Void>>()} bytes');
  print('Int size: ${sizeOf<Int>()} bytes');
  print('Long size: ${sizeOf<Long>()} bytes');
  print('IntPtr size: ${sizeOf<IntPtr>()} bytes');
}
