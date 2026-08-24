/// Native Windows audio implementation.
library;

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
