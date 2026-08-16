/// macOS ImageIO/CoreGraphics decoder, dynamically linked from system frameworks.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/native_memory.dart';
import '../decoded_image.dart';
import '../image_errors.dart';
import '../raster_codec.dart';

const int _bitmapByteOrder32Little = 2 << 12;
const int _imageAlphaPremultipliedFirst = 2;

final class _CgPoint extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class _CgSize extends Struct {
  @Double()
  external double width;
  @Double()
  external double height;
}

final class _CgRect extends Struct {
  external _CgPoint origin;
  external _CgSize size;
}

typedef _CfDataCreateNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
);
typedef _CfDataCreateDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
);
typedef _CfReleaseNative = Void Function(Pointer<Void>);
typedef _CfReleaseDart = void Function(Pointer<Void>);
typedef _SourceFromDataNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
);
typedef _SourceFromDataDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
);
typedef _ImageAtIndexNative = Pointer<Void> Function(
  Pointer<Void>,
  IntPtr,
  Pointer<Void>,
);
typedef _ImageAtIndexDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  Pointer<Void>,
);
typedef _ImageDimensionNative = UintPtr Function(Pointer<Void>);
typedef _ImageDimensionDart = int Function(Pointer<Void>);
typedef _ColorSpaceNative = Pointer<Void> Function();
typedef _ColorSpaceDart = Pointer<Void> Function();
typedef _BitmapContextNative = Pointer<Void> Function(
  Pointer<Void>,
  UintPtr,
  UintPtr,
  UintPtr,
  UintPtr,
  Pointer<Void>,
  Uint32,
);
typedef _BitmapContextDart = Pointer<Void> Function(
  Pointer<Void>,
  int,
  int,
  int,
  int,
  Pointer<Void>,
  int,
);
typedef _TranslateNative = Void Function(Pointer<Void>, Double, Double);
typedef _TranslateDart = void Function(Pointer<Void>, double, double);
typedef _ScaleNative = Void Function(Pointer<Void>, Double, Double);
typedef _ScaleDart = void Function(Pointer<Void>, double, double);
typedef _DrawImageNative = Void Function(
  Pointer<Void>,
  _CgRect,
  Pointer<Void>,
);
typedef _DrawImageDart = void Function(Pointer<Void>, _CgRect, Pointer<Void>);

final class _ImageIoApi {
  _ImageIoApi._(
    DynamicLibrary coreFoundation,
    DynamicLibrary imageIo,
    DynamicLibrary coreGraphics,
  )   : dataCreate = coreFoundation
            .lookupFunction<_CfDataCreateNative, _CfDataCreateDart>(
          'CFDataCreate',
        ),
        release = coreFoundation
            .lookupFunction<_CfReleaseNative, _CfReleaseDart>('CFRelease'),
        sourceFromData =
            imageIo.lookupFunction<_SourceFromDataNative, _SourceFromDataDart>(
                'CGImageSourceCreateWithData'),
        imageAtIndex =
            imageIo.lookupFunction<_ImageAtIndexNative, _ImageAtIndexDart>(
                'CGImageSourceCreateImageAtIndex'),
        imageWidth = coreGraphics.lookupFunction<_ImageDimensionNative,
            _ImageDimensionDart>('CGImageGetWidth'),
        imageHeight = coreGraphics.lookupFunction<_ImageDimensionNative,
            _ImageDimensionDart>('CGImageGetHeight'),
        createRgb =
            coreGraphics.lookupFunction<_ColorSpaceNative, _ColorSpaceDart>(
                'CGColorSpaceCreateDeviceRGB'),
        createContext = coreGraphics.lookupFunction<_BitmapContextNative,
            _BitmapContextDart>('CGBitmapContextCreate'),
        translate =
            coreGraphics.lookupFunction<_TranslateNative, _TranslateDart>(
                'CGContextTranslateCTM'),
        scale = coreGraphics.lookupFunction<_ScaleNative, _ScaleDart>(
          'CGContextScaleCTM',
        ),
        drawImage =
            coreGraphics.lookupFunction<_DrawImageNative, _DrawImageDart>(
                'CGContextDrawImage');

  static _ImageIoApi? tryLoad() {
    try {
      return _ImageIoApi._(
        DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
        ),
        DynamicLibrary.open(
          '/System/Library/Frameworks/ImageIO.framework/ImageIO',
        ),
        DynamicLibrary.open(
          '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
        ),
      );
    } on Object {
      return null;
    }
  }

  final _CfDataCreateDart dataCreate;
  final _CfReleaseDart release;
  final _SourceFromDataDart sourceFromData;
  final _ImageAtIndexDart imageAtIndex;
  final _ImageDimensionDart imageWidth;
  final _ImageDimensionDart imageHeight;
  final _ColorSpaceDart createRgb;
  final _BitmapContextDart createContext;
  final _TranslateDart translate;
  final _ScaleDart scale;
  final _DrawImageDart drawImage;
}

final _ImageIoApi? _imageIoApi = _ImageIoApi.tryLoad();

RasterDecodeResult? tryDecodeImageIo(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  final _ImageIoApi? api = _imageIoApi;
  if (api == null) return null;
  final NativeArena arena = NativeArena();
  final List<Pointer<Void>> objects = <Pointer<Void>>[];
  try {
    final Pointer<Uint8> encoded = arena.allocate<Uint8>(bytes.length);
    encoded.asTypedList(bytes.length).setAll(0, bytes);
    final Pointer<Void> data = api.dataCreate(nullptr, encoded, bytes.length);
    if (data == nullptr) return null;
    objects.add(data);
    final Pointer<Void> source = api.sourceFromData(data, nullptr);
    if (source == nullptr) return null;
    objects.add(source);
    final Pointer<Void> image = api.imageAtIndex(source, 0, nullptr);
    if (image == nullptr) return null;
    objects.add(image);
    final int width = api.imageWidth(image);
    final int height = api.imageHeight(image);
    limits.checkDimensions(width, height, format);

    final int stride = width * 4;
    final int byteLength = stride * height;
    final Pointer<Uint8> output = arena.allocate<Uint8>(byteLength);
    final Pointer<Void> colorSpace = api.createRgb();
    if (colorSpace == nullptr) return null;
    objects.add(colorSpace);
    final Pointer<Void> context = api.createContext(
      output.cast<Void>(),
      width,
      height,
      8,
      stride,
      colorSpace,
      _bitmapByteOrder32Little | _imageAlphaPremultipliedFirst,
    );
    if (context == nullptr) return null;
    objects.add(context);

    api.translate(context, 0, height.toDouble());
    api.scale(context, 1, -1);
    final Pointer<_CgRect> rect = arena.allocate<_CgRect>(sizeOf<_CgRect>());
    rect.ref
      ..origin.x = 0
      ..origin.y = 0
      ..size.width = width.toDouble()
      ..size.height = height.toDouble();
    api.drawImage(context, rect.ref, image);

    final Uint8List pixels = Uint8List.fromList(output.asTypedList(byteLength));
    var hasAlpha = false;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 255) {
        hasAlpha = true;
        break;
      }
    }
    final DecodedImage decoded = DecodedImage(
      width: width,
      height: height,
      order: ImageChannelOrder.bgra,
      pixels: pixels,
      hasAlpha: hasAlpha,
    ).inOrder(order);
    return RasterDecodeResult(
      image: decoded,
      codecName: 'macOS ImageIO',
      isNative: true,
    );
  } on ImageBudgetException {
    rethrow;
  } on Object {
    return null;
  } finally {
    for (final Pointer<Void> object in objects.reversed) {
      api.release(object);
    }
    arena.dispose();
  }
}
