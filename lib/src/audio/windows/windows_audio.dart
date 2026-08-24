/// Native Windows audio implementation.
library;

export 'media_foundation_audio_decoder.dart';
export 'wasapi_backend.dart';
export 'wasapi_bindings.dart'
    show
        WasapiWaveFormat,
        chooseWasapiPeriod,
        iidAudioClient3,
        iidAudioRenderClient;
export 'wasapi_render_stream.dart';
export 'wasapi_shared_parameter_block.dart';
export 'wasapi_shared_ring_buffer.dart';
export 'wasapi_shared_telemetry_block.dart';
export 'wasapi_shared_trigger_block.dart';
