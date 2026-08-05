// Metal.framework constants and the C-entry `MTLCreateSystemDefaultDevice`.
// Objective-C `id` types are exposed as `Pointer<ObjCObject>` from the runtime
// module, so this file only declares Metal-specific C symbols, structs and
// constants required by the clear-render POC.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'objc_runtime.dart';

// The Metal framework is loaded by name on macOS; `dlopen` resolves the framework
// path via the standard search rules.
final DynamicLibrary libMetal = DynamicLibrary.open('Metal');

// `id MTLCreateSystemDefaultDevice(void)` is the C entry point that returns the
// system-default GPU. It is *not* an Objective-C method, so we look it up on the
// Metal library directly instead of going through `objc_msgSend`.
final Pointer<ObjCObject> Function() mtlCreateSystemDefaultDevice =
    libMetal.lookupFunction<
        Pointer<ObjCObject> Function(),
        Pointer<ObjCObject> Function()>('MTLCreateSystemDefaultDevice');

// MTLPixelFormatBGRA8Unorm = 80 (see Metal/Metal.h).
const int mtlPixelFormatBGRA8Unorm = 80;

// MTLLoadActionClear = 0; MTLLoadActionLoad = 1; MTLLoadActionDontCare = 2.
const int mtlLoadActionClear = 0;

// MTLStoreActionStore = 0; MTLStoreActionDontCare = 2 (no multisample in POC).
const int mtlStoreActionStore = 0;

// MTLClearColor is a struct of four `double` components returned/stored by value:
//   typedef struct { double red, green, blue, alpha; } MTLClearColor;
// On both arm64 and x86_64 it fits in two GP registers (16 bytes per pair), so the
// standard `objc_msgSend` trampoline handles it as a value argument.
final class MTLClearColor extends Struct {
  @Double()
  external double red;
  @Double()
  external double green;
  @Double()
  external double blue;
  @Double()
  external double alpha;
}

// Void msgSend(Pointer, Selector, MTLClearColor) — `[colorAttachment setClearColor:]`.
typedef MsgSendVoidClearColorNative = Void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, MTLClearColor color);
typedef MsgSendVoidClearColorDart = void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, MTLClearColor color);
final msgSendVoidClearColor = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendVoidClearColorNative>>()
    .asFunction<MsgSendVoidClearColorDart>();