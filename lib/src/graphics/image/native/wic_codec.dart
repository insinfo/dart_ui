/// Windows Imaging Component decoder, reached only from the IO resolver.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../decoded_image.dart';
import '../image_errors.dart';
import '../raster_codec.dart';

final Guid _clsidWicImagingFactory =
    Guid.parse('cacaf262-9370-4615-a13b-9f5539da4c0a');
final Guid _iidWicImagingFactory =
    Guid.parse('ec5ec8a9-c395-4314-9c77-54d7a935ff70');
final Guid _pixelFormat32bppPbgra =
    Guid.parse('6fddc324-4e03-4bfe-b185-3d77768dc910');

const int _rpcEChangedMode = -2147417850; // 0x80010106
const int _clsctxInprocServer = 1;
const int _wicDecodeMetadataCacheOnDemand = 0;
const int _wicBitmapDitherTypeNone = 0;
const int _wicBitmapPaletteTypeCustom = 0;

typedef _CoInitializeExNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeExDart = int Function(Pointer<Void>, int);
typedef _CoUninitializeNative = Void Function();
typedef _CoUninitializeDart = void Function();
typedef _CoCreateInstanceNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Void>,
  Uint32,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _CoCreateInstanceDart = int Function(
  Pointer<Uint8>,
  Pointer<Void>,
  int,
  Pointer<Uint8>,
  Pointer<Pointer<Void>>,
);
typedef _ShCreateMemStreamNative = Pointer<Void> Function(
  Pointer<Uint8>,
  Uint32,
);
typedef _ShCreateMemStreamDart = Pointer<Void> Function(Pointer<Uint8>, int);

final class _WicApi {
  _WicApi._(DynamicLibrary ole32, DynamicLibrary shlwapi)
      : coInitializeEx =
            ole32.lookupFunction<_CoInitializeExNative, _CoInitializeExDart>(
                'CoInitializeEx'),
        coUninitialize =
            ole32.lookupFunction<_CoUninitializeNative, _CoUninitializeDart>(
                'CoUninitialize'),
        coCreateInstance = ole32.lookupFunction<_CoCreateInstanceNative,
            _CoCreateInstanceDart>('CoCreateInstance'),
        shCreateMemStream = shlwapi.lookupFunction<_ShCreateMemStreamNative,
            _ShCreateMemStreamDart>('SHCreateMemStream');

  static _WicApi? tryLoad() {
    try {
      return _WicApi._(
        DynamicLibrary.open('ole32.dll'),
        DynamicLibrary.open('shlwapi.dll'),
      );
    } on Object {
      return null;
    }
  }

  final _CoInitializeExDart coInitializeEx;
  final _CoUninitializeDart coUninitialize;
  final _CoCreateInstanceDart coCreateInstance;
  final _ShCreateMemStreamDart shCreateMemStream;
}

// Library loading and symbol lookup are process-wide work, not image work.
// Null is cached too so a damaged installation falls back without repeating
// two LoadLibrary calls for every asset.
final _WicApi? _wicApi = _WicApi.tryLoad();

typedef _CreateDecoderFromStreamNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _CreateDecoderFromStreamDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _CreateFormatConverterNative = Int32 Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _CreateFormatConverterDart = int Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

final class _WicFactory extends ComObject {
  _WicFactory(super.pointer) : super(interfaceName: 'IWICImagingFactory');

  late final _CreateDecoderFromStreamDart _createDecoderFromStream =
      comMethod<_CreateDecoderFromStreamNative>(pointer, 4).asFunction();
  late final _CreateFormatConverterDart _createFormatConverter =
      comMethod<_CreateFormatConverterNative>(pointer, 10).asFunction();

  int createDecoderFromStream(
    Pointer<Void> stream,
    Pointer<Pointer<Void>> out,
  ) =>
      _createDecoderFromStream(
        pointer,
        stream,
        nullptr.cast<Uint8>(),
        _wicDecodeMetadataCacheOnDemand,
        out,
      );

  int createFormatConverter(Pointer<Pointer<Void>> out) =>
      _createFormatConverter(pointer, out);
}

typedef _GetFrameNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _GetFrameDart = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Void>>,
);

final class _WicDecoder extends ComObject {
  _WicDecoder(super.pointer) : super(interfaceName: 'IWICBitmapDecoder');

  late final _GetFrameDart _getFrame =
      comMethod<_GetFrameNative>(pointer, 13).asFunction();

  int getFrame(int index, Pointer<Pointer<Void>> out) =>
      _getFrame(pointer, index, out);
}

typedef _GetSizeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _GetSizeDart = int Function(
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Uint32>,
);
typedef _CopyPixelsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Uint8>,
);
typedef _CopyPixelsDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Uint8>,
);

class _WicSource extends ComObject {
  _WicSource(super.pointer, {super.interfaceName = 'IWICBitmapSource'});

  late final _GetSizeDart _getSize =
      comMethod<_GetSizeNative>(pointer, 3).asFunction();
  late final _CopyPixelsDart _copyPixels =
      comMethod<_CopyPixelsNative>(pointer, 7).asFunction();

  int getSize(Pointer<Uint32> width, Pointer<Uint32> height) =>
      _getSize(pointer, width, height);

  int copyPixels(int stride, int size, Pointer<Uint8> output) =>
      _copyPixels(pointer, nullptr, stride, size, output);
}

typedef _ConverterInitializeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Pointer<Void>,
  Double,
  Uint32,
);
typedef _ConverterInitializeDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Void>,
  double,
  int,
);

final class _WicConverter extends _WicSource {
  _WicConverter(super.pointer) : super(interfaceName: 'IWICFormatConverter');

  late final _ConverterInitializeDart _initialize =
      comMethod<_ConverterInitializeNative>(pointer, 8).asFunction();

  int initialize(Pointer<Void> source, Pointer<Uint8> format) => _initialize(
        pointer,
        source,
        format,
        _wicBitmapDitherTypeNone,
        nullptr,
        0,
        _wicBitmapPaletteTypeCustom,
      );
}

RasterDecodeResult? tryDecodeWic(
  Uint8List bytes, {
  required RasterImageFormat format,
  required ImageChannelOrder order,
  required RasterImageLimits limits,
}) {
  final _WicApi? api = _wicApi;
  if (api == null) return null;
  final NativeArena arena = NativeArena();
  final List<ComObject> objects = <ComObject>[];
  var uninitialize = false;
  try {
    final int initialized = hresult(api.coInitializeEx(nullptr, 0));
    if (failed(initialized) && initialized != _rpcEChangedMode) return null;
    uninitialize = initialized != _rpcEChangedMode;

    final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
    checkHresult(
      api.coCreateInstance(
        _clsidWicImagingFactory.allocateIn(arena),
        nullptr,
        _clsctxInprocServer,
        _iidWicImagingFactory.allocateIn(arena),
        out,
      ),
      'CoCreateInstance(CLSID_WICImagingFactory)',
    );
    final _WicFactory factory = _WicFactory(out.value);
    objects.add(factory);

    final Pointer<Uint8> encoded = arena.allocate<Uint8>(bytes.length);
    encoded.asTypedList(bytes.length).setAll(0, bytes);
    final Pointer<Void> streamPointer =
        api.shCreateMemStream(encoded, bytes.length);
    if (streamPointer == nullptr) return null;
    final ComObject stream = ComObject(streamPointer, interfaceName: 'IStream');
    objects.add(stream);

    out.value = nullptr;
    checkHresult(
      factory.createDecoderFromStream(stream.pointer, out),
      'IWICImagingFactory::CreateDecoderFromStream',
    );
    final _WicDecoder decoder = _WicDecoder(out.value);
    objects.add(decoder);

    out.value = nullptr;
    checkHresult(decoder.getFrame(0, out), 'IWICBitmapDecoder::GetFrame');
    final _WicSource frame =
        _WicSource(out.value, interfaceName: 'IWICBitmapFrameDecode');
    objects.add(frame);

    final Pointer<Uint32> widthOut = arena.allocate<Uint32>(sizeOf<Uint32>());
    final Pointer<Uint32> heightOut = arena.allocate<Uint32>(sizeOf<Uint32>());
    checkHresult(
        frame.getSize(widthOut, heightOut), 'IWICBitmapSource::GetSize');
    final int width = widthOut.value;
    final int height = heightOut.value;
    limits.checkDimensions(width, height, format);

    out.value = nullptr;
    checkHresult(
      factory.createFormatConverter(out),
      'IWICImagingFactory::CreateFormatConverter',
    );
    final _WicConverter converter = _WicConverter(out.value);
    objects.add(converter);
    checkHresult(
      converter.initialize(
        frame.pointer,
        _pixelFormat32bppPbgra.allocateIn(arena),
      ),
      'IWICFormatConverter::Initialize(32bppPBGRA)',
    );

    final int stride = width * 4;
    final int byteLength = stride * height;
    final Pointer<Uint8> output = arena.allocate<Uint8>(byteLength);
    checkHresult(
      converter.copyPixels(stride, byteLength, output),
      'IWICBitmapSource::CopyPixels',
    );
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
      codecName: 'Windows Imaging Component',
      isNative: true,
    );
  } on ImageBudgetException {
    rethrow;
  } on Object {
    return null;
  } finally {
    for (final ComObject object in objects.reversed) {
      object.dispose();
    }
    arena.dispose();
    if (uninitialize) api.coUninitialize();
  }
}
