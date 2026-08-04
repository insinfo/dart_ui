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

// objc_allocateClassPair
typedef ObjcAllocateClassPairNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> superclass, Pointer<Utf8> name, IntPtr extraBytes);
typedef ObjcAllocateClassPairDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> superclass, Pointer<Utf8> name, int extraBytes);
final objc_allocateClassPair = libObjC.lookupFunction<
    ObjcAllocateClassPairNative,
    ObjcAllocateClassPairDart>('objc_allocateClassPair');

// objc_registerClassPair
typedef ObjcRegisterClassPairNative = Void Function(Pointer<ObjCObject> cls);
typedef ObjcRegisterClassPairDart = void Function(Pointer<ObjCObject> cls);
final objc_registerClassPair = libObjC.lookupFunction<
    ObjcRegisterClassPairNative,
    ObjcRegisterClassPairDart>('objc_registerClassPair');

// class_addMethod
typedef ClassAddMethodNative = Int8 Function(Pointer<ObjCObject> cls,
    Pointer<ObjCSel> name, Pointer<Void> imp, Pointer<Utf8> types);
typedef ClassAddMethodDart = int Function(Pointer<ObjCObject> cls,
    Pointer<ObjCSel> name, Pointer<Void> imp, Pointer<Utf8> types);
final class_addMethod =
    libObjC.lookupFunction<ClassAddMethodNative, ClassAddMethodDart>(
        'class_addMethod');

// Base pointer for objc_msgSend
final Pointer<NativeFunction<Void Function()>> objc_msgSend_ptr =
    libObjC.lookup<NativeFunction<Void Function()>>('objc_msgSend');

// MsgSend variants using asFunction

// Pointer msgSend(Pointer, Selector)
typedef MsgSendPointerNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
typedef MsgSendPointerDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target, Pointer<ObjCSel> op);
final msgSendPointer = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendPointerNative>>()
    .asFunction<MsgSendPointerDart>();

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

// Pointer msgSend(Pointer, Selector, Double, Double, Double, Double) - e.g. for initWithContentRect:
// Wait, NSRect is passed by value (struct). FFI supports passing structs by value.
final class NSRect extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double width;
  @Double()
  external double height;
}

// Pointer msgSend(Pointer, Selector, NSRect, IntPtr, IntPtr, Bool)
typedef MsgSendPointerRectIntIntBoolNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target,
    Pointer<ObjCSel> op,
    NSRect rect,
    IntPtr styleMask,
    IntPtr backing,
    Bool defer);
typedef MsgSendPointerRectIntIntBoolDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target,
    Pointer<ObjCSel> op,
    NSRect rect,
    int styleMask,
    int backing,
    bool defer);
final msgSendPointerRectIntIntBool = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendPointerRectIntIntBoolNative>>()
    .asFunction<MsgSendPointerRectIntIntBoolDart>();

// Pointer msgSend(Pointer, Selector, Double, Pointer, Selector, Pointer, Bool)
typedef MsgSendTimerNative = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target,
    Pointer<ObjCSel> op,
    Double delay,
    Pointer<ObjCObject> tgt,
    Pointer<ObjCSel> sel,
    Pointer<ObjCObject> userInfo,
    Bool repeats);
typedef MsgSendTimerDart = Pointer<ObjCObject> Function(
    Pointer<ObjCObject> target,
    Pointer<ObjCSel> op,
    double delay,
    Pointer<ObjCObject> tgt,
    Pointer<ObjCSel> sel,
    Pointer<ObjCObject> userInfo,
    bool repeats);
final msgSendTimer = objc_msgSend_ptr
    .cast<NativeFunction<MsgSendTimerNative>>()
    .asFunction<MsgSendTimerDart>();

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
  Pointer<ObjCObject> msgSend(String selector) {
    return msgSendPointer(this, sel(selector));
  }
}

// Structs
final class NSPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class NSSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}
