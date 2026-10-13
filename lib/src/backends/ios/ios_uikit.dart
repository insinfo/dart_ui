/// The few UIKit and CoreGraphics calls the iOS backend makes, over `dart:ffi`.
///
/// Everything here runs on the main thread: the iOS runtime (ADR 0010) handles
/// the main isolate's messages there, so UIKit is called directly and calls
/// back synchronously. The struct-returning sends rely on arm64's convention,
/// where a `CGRect` or `CGPoint` - two or four doubles - comes back in
/// floating-point registers from plain `objc_msgSend` (there is no `_stret`
/// variant on arm64).
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import '../../ffi/objc_runtime.dart';

final class CGPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class CGSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

final class CGRect extends Struct {
  external CGPoint origin;
  external CGSize size;
}

final class UIEdgeInsets extends Struct {
  @Double()
  external double top;
  @Double()
  external double left;
  @Double()
  external double bottom;
  @Double()
  external double right;
}

final DynamicLibrary _objc = tryLoadObjCRuntime() ??
    (throw StateError('the Objective-C runtime is not loaded'));

/// UIKit, opened once so its classes are registered before any lookup.
final DynamicLibrary uikit =
    DynamicLibrary.open('/System/Library/Frameworks/UIKit.framework/UIKit');

final DynamicLibrary _coreGraphics = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
final DynamicLibrary _coreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

final CGRect Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendRect =
    _objc.lookupFunction<
        CGRect Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        CGRect Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');
final CGPoint Function(
        Pointer<ObjCObject>, Pointer<ObjCSelector>, Pointer<ObjCObject>)
    _sendPointWithObject = _objc.lookupFunction<
        CGPoint Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>, Pointer<ObjCObject>),
        CGPoint Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
            Pointer<ObjCObject>)>('objc_msgSend');
final double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>) _sendDouble =
    _objc.lookupFunction<
        Double Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        double Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');
final void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, double)
    _sendVoidDouble = _objc.lookupFunction<
        Void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, Double),
        void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
            double)>('objc_msgSend');
final UIEdgeInsets Function(Pointer<ObjCObject>, Pointer<ObjCSelector>)
    _sendInsets = _objc.lookupFunction<
        UIEdgeInsets Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        UIEdgeInsets Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');
final int Function(Pointer<ObjCObject>, Pointer<ObjCObject>) _addProtocol =
    _objc.lookupFunction<
        Uint8 Function(Pointer<ObjCObject>, Pointer<ObjCObject>),
        int Function(
            Pointer<ObjCObject>, Pointer<ObjCObject>)>('class_addProtocol');

/// `[target selector]` returning a `CGRect`.
CGRect sendRect(Pointer<ObjCObject> target, String selector) =>
    _sendRect(target, objcSelector(selector));

/// `[target selector:object]` returning a `CGPoint`.
CGPoint sendPoint(Pointer<ObjCObject> target, String selector,
        Pointer<ObjCObject> object) =>
    _sendPointWithObject(target, objcSelector(selector), object);

/// `[target selector]` returning a `CGFloat`.
double sendDouble(Pointer<ObjCObject> target, String selector) =>
    _sendDouble(target, objcSelector(selector));

/// `[target selector:value]` with one `CGFloat`.
void sendVoidDouble(
        Pointer<ObjCObject> target, String selector, double value) =>
    _sendVoidDouble(target, objcSelector(selector), value);

/// `[target selector]` returning `UIEdgeInsets`.
UIEdgeInsets sendInsets(Pointer<ObjCObject> target, String selector) =>
    _sendInsets(target, objcSelector(selector));

/// Declares that [cls] adopts [protocol]; UIKit asks before it calls.
void adoptProtocol(Pointer<ObjCObject> cls, String protocol) {
  final Pointer<ObjCObject> described = objcProtocol(protocol);
  if (described != nullptr) _addProtocol(cls, described);
}

/// `+[NSString stringWithUTF8String:]`, autoreleased.
Pointer<ObjCObject> nsString(String value) {
  final Pointer<Uint8> text = objcAllocateCString(value);
  try {
    return objcSendPointer1(objcClass('NSString'),
        objcSelector('stringWithUTF8String:'), text.address);
  } finally {
    objcFreeCString(text);
  }
}

/// The objects of an `NSSet`, by way of `allObjects`.
List<Pointer<ObjCObject>> setObjects(Pointer<ObjCObject> set) {
  final Pointer<ObjCObject> array =
      objcSendPointer(set, objcSelector('allObjects'));
  final int count = objcSendUnsigned(array, objcSelector('count'));
  return <Pointer<ObjCObject>>[
    for (var i = 0; i < count; i++)
      objcSendPointer1(array, objcSelector('objectAtIndex:'), i),
  ];
}

final Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int) _cfDataCreate =
    _coreFoundation.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Uint8>, int)>('CFDataCreate');
final void Function(Pointer<Void>) _cfRelease = _coreFoundation.lookupFunction<
    Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
final Pointer<Void> Function(Pointer<Void>) _providerWithData =
    _coreGraphics.lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(
            Pointer<Void>)>('CGDataProviderCreateWithCFData');
final Pointer<Void> Function() _deviceRgb = _coreGraphics.lookupFunction<
    Pointer<Void> Function(),
    Pointer<Void> Function()>('CGColorSpaceCreateDeviceRGB');
final Pointer<Void> Function(int, int, int, int, int, Pointer<Void>, int,
        Pointer<Void>, Pointer<Void>, bool, int) _imageCreate =
    _coreGraphics.lookupFunction<
        Pointer<Void> Function(IntPtr, IntPtr, IntPtr, IntPtr, IntPtr,
            Pointer<Void>, Uint32, Pointer<Void>, Pointer<Void>, Bool, Int32),
        Pointer<Void> Function(int, int, int, int, int, Pointer<Void>, int,
            Pointer<Void>, Pointer<Void>, bool, int)>('CGImageCreate');

/// A `CGImage` holding a copy of [pixels] - BGRA, premultiplied - or
/// nullptr. The caller releases it with [releaseCF] once a layer holds it.
Pointer<Void> createImage(Uint8List pixels,
    {required int width, required int height, required int bytesPerRow}) {
  final int length = bytesPerRow * height;
  final Pointer<Uint8> native =
      NativeAllocator.instance.allocate<Uint8>(length);
  native.asTypedList(length).setRange(0, length, pixels);
  final Pointer<Void> data = _cfDataCreate(nullptr, native, length);
  NativeAllocator.instance.free(native);
  final Pointer<Void> provider = _providerWithData(data);
  _cfRelease(data);
  final Pointer<Void> space = _deviceRgb();
  // kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little.
  final Pointer<Void> image = _imageCreate(width, height, 8, 32, bytesPerRow,
      space, 2 | (2 << 12), provider, nullptr, false, 0);
  _cfRelease(space);
  _cfRelease(provider);
  return image;
}

void releaseCF(Pointer<Void> object) {
  if (object != nullptr) _cfRelease(object);
}
