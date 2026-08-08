import 'dart:ffi';

/// `CGPoint` — two CGFloats, which are doubles on every 64-bit Apple target.
final class CGPointNative extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

/// `CGRect` — origin followed by size, flattened for FFI.
final class CGRectNative extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double width;
  @Double()
  external double height;
}
