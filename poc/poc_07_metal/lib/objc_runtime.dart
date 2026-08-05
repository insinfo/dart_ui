// Runtime symbols retain their exact Objective-C names for ABI traceability.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

final DynamicLibrary libObjC = DynamicLibrary.open('libobjc.A.dylib');

final class ObjCObject extends Opaque {}

final class ObjCSel extends Opaque {}

// sel_registerName
typedef SelRegisterNameNative = Pointer<ObjCSel> Function(Pointer<Utf8> name);
typedef SelRegisterNameDart = Pointer<ObjCSel> Function(Pointer<Utf8> name);
final sel_registerName =
    libObjC.lookupFunction<SelRegisterNameNative, SelRegisterNameDart>(
        'sel_registerName');

// objc_getClass
typedef ObjcGetClassNative = Pointer<ObjCObject> Function(Pointer<Utf8> name);
typedef ObjcGetClassDart = Pointer<ObjCObject> Function(Pointer<Utf8> name);
final objc_getClass = libObjC
    .lookupFunction<ObjcGetClassNative, ObjcGetClassDart>('objc_getClass');

// Base pointer for objc_msgSend. The Objective-C runtime exports a single
// `objc_msgSend` trampoline; specific signatures are obtained via `cast` and
// `asFunction`. On arm64 (the only macOS CI target in the plan) structs that
// fit in two registers are returned via the standard trampoline and we do not
// need `objc_msgSend_stret`/`_fpret` variants here.
final Pointer<NativeFunction<Void Function()>> objc_msgSend_ptr =
    libObjC.lookup<NativeFunction<Void Function()>>('objc_msgSend');

// Pointer msgSend(Pointer, Selector)
typedef MsgSendPointerNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
typedef MsgSendPointerDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
final msgSendPointer = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendPointerNative>>()
    .asFunction<MsgSendPointerDart>();

// Void msgSend(Pointer, Selector)
typedef MsgSendVoidNative = Void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
typedef MsgSendVoidDart = void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
final msgSendVoid = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendVoidNative>>()
    .asFunction<MsgSendVoidDart>();

// Void msgSend(Pointer, Selector, IntPtr)
typedef MsgSendVoidIntPtrNative = Void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, IntPtr arg1);
typedef MsgSendVoidIntPtrDart = void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, int arg1);
final msgSendVoidIntPtr = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendVoidIntPtrNative>>()
    .asFunction<MsgSendVoidIntPtrDart>();

// Void msgSend(Pointer, Selector, Pointer)
typedef MsgSendVoidPointerNative = Void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, Pointer<ObjCObject> arg1);
typedef MsgSendVoidPointerDart = void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, Pointer<ObjCObject> arg1);
final msgSendVoidPointer = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendVoidPointerNative>>()
    .asFunction<MsgSendVoidPointerDart>();

// Pointer msgSend(Pointer, Selector, Pointer)
typedef MsgSendPointerPointerNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, Pointer<ObjCObject> arg1);
typedef MsgSendPointerPointerDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, Pointer<ObjCObject> arg1);
final msgSendPointerPointer = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendPointerPointerNative>>()
    .asFunction<MsgSendPointerPointerDart>();

// Pointer msgSend(Pointer, Selector, IntPtr) — e.g. objectAtIndexedSubscript:
typedef MsgSendPointerIntPtrNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, IntPtr arg1);
typedef MsgSendPointerIntPtrDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, int arg1);
final msgSendPointerIntPtr = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendPointerIntPtrNative>>()
    .asFunction<MsgSendPointerIntPtrDart>();

// Structs passed by value to msgSend.

final class NSSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

// Void msgSend(Pointer, Selector, NSSize) — e.g. setDrawableSize:
typedef MsgSendVoidSizeNative = Void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, NSSize size);
typedef MsgSendVoidSizeDart = void Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op, NSSize size);
final msgSendVoidSize = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendVoidSizeNative>>()
    .asFunction<MsgSendVoidSizeDart>();

// Helpers

Pointer<ObjCSel> sel(String name) {
  final cStr = name.toNativeUtf8();
  final result = sel_registerName(cStr);
  calloc.free(cStr);
  return result;
}

Pointer<ObjCObject> getClass(String name) {
  final cStr = name.toNativeUtf8();
  final result = objc_getClass(cStr);
  calloc.free(cStr);
  return result;
}

extension ObjCObjectExt on Pointer<ObjCObject> {
  Pointer<ObjCObject> msgSend(String selector) =>
      msgSendPointer(this, sel(selector));
}
