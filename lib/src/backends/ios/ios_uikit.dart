/// The few UIKit calls the iOS backend makes, over `dart:ffi`.
///
/// Everything here runs on the main thread: the iOS runtime (ADR 0010) handles
/// the main isolate's messages there, so UIKit is called directly and calls
/// back synchronously. The struct-returning sends rely on arm64's convention,
/// where a `CGRect` or `CGPoint` - two or four doubles - comes back in
/// floating-point registers from plain `objc_msgSend` (there is no `_stret`
/// variant on arm64).
library;

import 'dart:ffi';

import '../../ffi/objc_runtime.dart';

// The geometry structs, the struct-carrying sends, NSString and CGImage
// creation are shared with the macOS embedded backend.
export '../apple/cocoa_ffi.dart';

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

final UIEdgeInsets Function(Pointer<ObjCObject>, Pointer<ObjCSelector>)
    _sendInsets = _objc.lookupFunction<
        UIEdgeInsets Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        UIEdgeInsets Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>)>('objc_msgSend');

/// `[target selector]` returning `UIEdgeInsets`.
UIEdgeInsets sendInsets(Pointer<ObjCObject> target, String selector) =>
    _sendInsets(target, objcSelector(selector));

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
