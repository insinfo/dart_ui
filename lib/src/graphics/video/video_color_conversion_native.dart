/// The native-memory half of video colour conversion.
///
/// Split out of `video_color_conversion.dart` so that file stays portable.
/// `lib/dart_ui.dart` exports the conversion routines, and anything reachable
/// from there is compiled by `dart compile js` and `dart compile wasm`; a single
/// `import 'dart:ffi'` anywhere in that graph fails both. The ring buffer is
/// native memory by definition and cannot have a web implementation, so the one
/// function that touches it lives here, off the portable path, and is imported
/// only by decoders that are already platform-gated.
library;

import 'dart:typed_data';

import '../image/decoded_image.dart';
import 'video_color_conversion.dart';
import 'video_frame.dart';
import 'video_frame_ring_buffer.dart';

/// Converts into a reusable native ring slot without allocating pixel storage
/// in the Dart heap.
///
/// [NativeVideoFrameLease.bytes] is a cached external typed-data view over the
/// slot pointer. Keeping the inner loop on that view retains Dart's bounds
/// safety while every store lands in native memory; raw unchecked pointer
/// arithmetic would remove the safety without reducing garbage collection.
Uint8List convertVideoFrameToNativeRgba(
  VideoFrame frame,
  NativeVideoFrameLease destination, {
  VideoRegion? region,
  ImageChannelOrder order = ImageChannelOrder.rgba,
  int opacity = 255,
  int? bytesPerRow,
}) {
  destination.validate();
  return convertVideoFrameToRgba(
    frame,
    region: region,
    order: order,
    opacity: opacity,
    into: destination.bytes,
    bytesPerRow: bytesPerRow,
  );
}
