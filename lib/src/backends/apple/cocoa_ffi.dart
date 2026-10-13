/// The Objective-C sends and CoreGraphics calls that UIKit and AppKit backends
/// running on the main thread share, over `dart:ffi`.
///
/// Factored out of the iOS backend (`ios_uikit.dart`) when the macOS embedded
/// backend (`macos/embedded/`) needed the same geometry structs, image
/// creation and struct-carrying sends. Nothing here opens UIKit or AppKit:
/// the caller loads the framework it subclasses.
///
/// The struct-returning sends rely on arm64's convention, where a `CGRect` or
/// `CGPoint` - two or four doubles, a homogeneous floating-point aggregate -
/// comes back in floating-point registers from plain `objc_msgSend` (there is
/// no `_stret` variant on arm64). x86_64 returns a `CGRect` in memory and
/// would need `objc_msgSend_stret`; both callers are arm64-only today (the
/// iOS device and simulator, and the embedded runtime built for macOS arm64).
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

/// A `CGPoint` to pass by value.
CGPoint cgPoint(double x, double y) => Struct.create<CGPoint>()
  ..x = x
  ..y = y;

/// A `CGSize` to pass by value.
CGSize cgSize(double width, double height) => Struct.create<CGSize>()
  ..width = width
  ..height = height;

/// A `CGRect` to pass by value.
CGRect cgRect(double x, double y, double width, double height) {
  final CGRect rect = Struct.create<CGRect>();
  rect.origin
    ..x = x
    ..y = y;
  rect.size
    ..width = width
    ..height = height;
  return rect;
}

final DynamicLibrary _objc = tryLoadObjCRuntime() ??
    (throw StateError('the Objective-C runtime is not loaded'));

final DynamicLibrary _coreGraphics = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics');
final DynamicLibrary _coreFoundation = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');

typedef _Id = Pointer<ObjCObject>;
typedef _Sel = Pointer<ObjCSelector>;

final CGRect Function(_Id, _Sel) _sendRect = _objc.lookupFunction<
    CGRect Function(_Id, _Sel), CGRect Function(_Id, _Sel)>('objc_msgSend');
final CGRect Function(_Id, _Sel, CGRect) _sendRectWithRect =
    _objc.lookupFunction<CGRect Function(_Id, _Sel, CGRect),
        CGRect Function(_Id, _Sel, CGRect)>('objc_msgSend');
final CGRect Function(_Id, _Sel, CGRect, _Id) _sendRectWithRectAndObject =
    _objc.lookupFunction<CGRect Function(_Id, _Sel, CGRect, _Id),
        CGRect Function(_Id, _Sel, CGRect, _Id)>('objc_msgSend');
final CGPoint Function(_Id, _Sel) _sendPoint = _objc.lookupFunction<
    CGPoint Function(_Id, _Sel), CGPoint Function(_Id, _Sel)>('objc_msgSend');
final CGPoint Function(_Id, _Sel, _Id) _sendPointWithObject =
    _objc.lookupFunction<CGPoint Function(_Id, _Sel, _Id),
        CGPoint Function(_Id, _Sel, _Id)>('objc_msgSend');
final double Function(_Id, _Sel) _sendDouble = _objc.lookupFunction<
    Double Function(_Id, _Sel), double Function(_Id, _Sel)>('objc_msgSend');
final void Function(_Id, _Sel, double) _sendVoidDouble = _objc.lookupFunction<
    Void Function(_Id, _Sel, Double),
    void Function(_Id, _Sel, double)>('objc_msgSend');
final void Function(_Id, _Sel, CGPoint) _sendVoidPoint = _objc.lookupFunction<
    Void Function(_Id, _Sel, CGPoint),
    void Function(_Id, _Sel, CGPoint)>('objc_msgSend');
final void Function(_Id, _Sel, CGSize) _sendVoidSize = _objc.lookupFunction<
    Void Function(_Id, _Sel, CGSize),
    void Function(_Id, _Sel, CGSize)>('objc_msgSend');
final void Function(_Id, _Sel, CGRect, int) _sendVoidRectWord =
    _objc.lookupFunction<Void Function(_Id, _Sel, CGRect, IntPtr),
        void Function(_Id, _Sel, CGRect, int)>('objc_msgSend');
final _Id Function(_Id, _Sel, CGRect, int, int, int) _sendInitWithRect =
    _objc.lookupFunction<
        _Id Function(_Id, _Sel, CGRect, IntPtr, IntPtr, IntPtr),
        _Id Function(_Id, _Sel, CGRect, int, int, int)>('objc_msgSend');
final int Function(_Id, _Id) _addProtocol =
    _objc.lookupFunction<Uint8 Function(_Id, _Id), int Function(_Id, _Id)>(
        'class_addProtocol');

/// `[target selector]` returning a `CGRect`.
CGRect sendRect(Pointer<ObjCObject> target, String selector) =>
    _sendRect(target, objcSelector(selector));

/// `[target selector:rect]` returning a `CGRect` -
/// `contentRectForFrameRect:` and its kin.
CGRect sendRectWithRect(
        Pointer<ObjCObject> target, String selector, CGRect rect) =>
    _sendRectWithRect(target, objcSelector(selector), rect);

/// `[target selector:rect object:]` returning a `CGRect` -
/// `convertRect:toView:`.
CGRect sendRectWithRectAndObject(Pointer<ObjCObject> target, String selector,
        CGRect rect, Pointer<ObjCObject> object) =>
    _sendRectWithRectAndObject(target, objcSelector(selector), rect, object);

/// `[target selector]` returning a `CGPoint` - `locationInWindow`.
CGPoint sendPointGetter(Pointer<ObjCObject> target, String selector) =>
    _sendPoint(target, objcSelector(selector));

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

/// `[target selector:point]` - `setFrameTopLeftPoint:`.
void sendVoidPoint(
        Pointer<ObjCObject> target, String selector, CGPoint point) =>
    _sendVoidPoint(target, objcSelector(selector), point);

/// `[target selector:size]` - `setContentSize:`, `setContentMinSize:`.
void sendVoidSize(Pointer<ObjCObject> target, String selector, CGSize size) =>
    _sendVoidSize(target, objcSelector(selector), size);

/// `[target selector:rect word:]` - `setFrame:display:`.
void sendVoidRectWord(
        Pointer<ObjCObject> target, String selector, CGRect rect, int word) =>
    _sendVoidRectWord(target, objcSelector(selector), rect, word);

/// `[target selector:rect a:b:c:]` returning an object - the shape of
/// `initWithContentRect:styleMask:backing:defer:` and of
/// `initWithRect:options:owner:userInfo:`.
Pointer<ObjCObject> sendInitWithRect(Pointer<ObjCObject> target,
        String selector, CGRect rect, int a, int b, int c) =>
    _sendInitWithRect(target, objcSelector(selector), rect, a, b, c);

/// Declares that [cls] adopts [protocol]; UIKit and AppKit ask before they
/// call some delegate methods.
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

/// The UTF-8 contents of an `NSString`, or '' for nil.
String dartString(Pointer<ObjCObject> string) {
  if (string == nullptr) return '';
  final Pointer<ObjCObject> utf8 =
      objcSendPointer(string, objcSelector('UTF8String'));
  return utf8 == nullptr ? '' : objcReadCString(utf8.cast());
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
