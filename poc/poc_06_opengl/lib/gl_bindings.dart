import 'dart:ffi';
import 'package:ffi/ffi.dart';

final DynamicLibrary libGL = DynamicLibrary.open('libGL.so.1');

// glClearColor
typedef GlClearColorNative = Void Function(
    Float red, Float green, Float blue, Float alpha);
typedef GlClearColorDart = void Function(
    double red, double green, double blue, double alpha);
final glClearColor =
    libGL.lookupFunction<GlClearColorNative, GlClearColorDart>('glClearColor');

// glClear
const int glColorBufferBit = 0x00004000;
typedef GlClearNative = Void Function(Uint32 mask);
typedef GlClearDart = void Function(int mask);
final glClear = libGL.lookupFunction<GlClearNative, GlClearDart>('glClear');

// glViewport
typedef GlViewportNative = Void Function(
    Int32 x, Int32 y, Int32 width, Int32 height);
typedef GlViewportDart = void Function(int x, int y, int width, int height);
final glViewport =
    libGL.lookupFunction<GlViewportNative, GlViewportDart>('glViewport');

// glGetString
const int glVersion = 0x1F02;
const int glRenderer = 0x1F01;
const int glVendor = 0x1F00;

typedef GlGetStringNative = Pointer<Utf8> Function(Uint32 name);
typedef GlGetStringDart = Pointer<Utf8> Function(int name);
final glGetString =
    libGL.lookupFunction<GlGetStringNative, GlGetStringDart>('glGetString');
