/// Optional Linux libjpeg-turbo decoder. Absence is an ordinary fallback.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../decoded_image.dart';
import '../image_errors.dart';
import '../raster_codec.dart';

const int _tjPixelFormatBgra = 8;

typedef _TjInitNative = Pointer<Void> Function();
typedef _TjInitDart = Pointer<Void> Function();
typedef _TjDestroyNative = Int32 Function(Pointer<Void>);
typedef _TjDestroyDart = int Function(Pointer<Void>);
typedef _TjHeaderNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _TjHeaderDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Int32>,
);
typedef _TjDecompressNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  UintPtr,
  Pointer<Uint8>,
  Int32,
  Int32,
  Int32,
  Int32,
  Int32,
);
typedef _TjDecompressDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  int,
);

final class _TurboJpegApi {
  _TurboJpegApi._(DynamicLibrary library)
      : init = library.lookupFunction<_TjInitNative, _TjInitDart>(
          'tjInitDecompress',
        ),
        destroy = library.lookupFunction<_TjDestroyNative, _TjDestroyDart>(
          'tjDestroy',
        ),
        header = library.lookupFunction<_TjHeaderNative, _TjHeaderDart>(
          'tjDecompressHeader3',
        ),
        decompress =
            library.lookupFunction<_TjDecompressNative, _TjDecompressDart>(
          'tjDecompress2',
        );

  static _TurboJpegApi? tryLoad() {
    for (final String name in <String>[
      'libturbojpeg.so.0',
      'libturbojpeg.so',
    ]) {
      try {
        return _TurboJpegApi._(DynamicLibrary.open(name));
      } on Object {
        // Try the next soname. Minimal/headless systems commonly have none.
      }
    }
    return null;
  }

  final _TjInitDart init;
  final _TjDestroyDart destroy;
  final _TjHeaderDart header;
  final _TjDecompressDart decompress;
}

final _TurboJpegApi? _turboJpegApi = _TurboJpegApi.tryLoad();

RasterDecodeResult? tryDecodeTurboJpeg(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  if (format != RasterImageFormat.jpeg) return null;
  final _TurboJpegApi? api = _turboJpegApi;
  if (api == null) return null;
  final Pointer<Void> handle = api.init();
  if (handle == nullptr) return null;
  final NativeArena arena = NativeArena();
  try {
    final Pointer<Uint8> encoded = arena.allocate<Uint8>(bytes.length);
    encoded.asTypedList(bytes.length).setAll(0, bytes);
    final Pointer<Int32> widthOut = arena.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Int32> heightOut = arena.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Int32> subsamplingOut =
        arena.allocate<Int32>(sizeOf<Int32>());
    final Pointer<Int32> colorSpaceOut = arena.allocate<Int32>(sizeOf<Int32>());
    if (api.header(
          handle,
          encoded,
          bytes.length,
          widthOut,
          heightOut,
          subsamplingOut,
          colorSpaceOut,
        ) !=
        0) {
      return null;
    }
    final int width = widthOut.value;
    final int height = heightOut.value;
    limits.checkDimensions(width, height, format);
    final int stride = width * 4;
    final int byteLength = stride * height;
    final Pointer<Uint8> output = arena.allocate<Uint8>(byteLength);
    if (api.decompress(
          handle,
          encoded,
          bytes.length,
          output,
          width,
          stride,
          height,
          _tjPixelFormatBgra,
          0,
        ) !=
        0) {
      return null;
    }
    final DecodedImage decoded = DecodedImage(
      width: width,
      height: height,
      order: ImageChannelOrder.bgra,
      pixels: Uint8List.fromList(output.asTypedList(byteLength)),
      hasAlpha: false,
    ).inOrder(order);
    return RasterDecodeResult(
      image: decoded,
      codecName: 'libjpeg-turbo',
      isNative: true,
    );
  } on ImageBudgetException {
    rethrow;
  } on Object {
    return null;
  } finally {
    arena.dispose();
    api.destroy(handle);
  }
}
