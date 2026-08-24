# Áudio nativo e tempo real

O primeiro backend de áudio do `dart_ui` é o WASAPI compartilhado dirigido por
evento, usando `IAudioClient3` diretamente por Dart FFI. Não há wrapper C/C++ e
não há callback nativo entrando na VM.

## Camadas

- `lib/src/audio`: formatos PCM, dispositivos, streams e contratos de codecs
  independentes de plataforma.
- `lib/src/audio/windows`: COM/WASAPI, eventos, MMCSS e ring buffer em memória
  nativa.
- `lib/audio.dart`: barrel explícito para aplicações desktop que usam FFI.
- `lib/dart_ui.dart`: exporta apenas os contratos portáveis.

O stream abre `IAudioClient3`, consulta os períodos aceitos pelo engine, escolhe
um múltiplo da periodicidade fundamental, inicializa
`InitializeSharedAudioStream(EVENTCALLBACK)` e obtém `IAudioRenderClient`.

## Regra para o caminho realtime

Crie, execute e descarte `WasapiRenderStream` dentro da mesma entrada síncrona
de um isolate dedicado. `runFromRing` não usa `Future`, `Timer`, porta de isolate
ou callback no loop de áudio. Ele espera dois eventos nativos: o evento do
WASAPI e o evento de parada.

O produtor pode viver em outro isolate. Envie somente:

1. `WasapiSharedRingBuffer.address` para anexar à memória compartilhada;
2. `WasapiRenderStream.stopHandle` para encerrar o pump.

O produtor pode esperar brevemente pelo SRW lock. O consumidor realtime usa
`TryAcquireSRWLockExclusive`; contenção resulta em silêncio, nunca em espera.
Buffers do WASAPI são zerados antes da leitura, portanto underrun e leitura
parcial não repetem memória antiga.

O Dart 3.6 usado pelo projeto ainda não expõe afinidade pública entre isolate e
thread nativa. O stream registra o ID da thread que inicializou COM e rejeita
uso em outra thread. Por isso não se deve aguardar um `Future` entre abrir,
executar o pump e descartar o stream.

## Teste audível

```powershell
dart run examples/wasapi_audio_demo/main.dart 3
```

O exemplo negocia o formato real, cria o stream no isolate de áudio, compartilha
o ring buffer por endereço e produz um tom de 440 Hz no isolate principal.

## Próximos backends

A API já separa os contratos necessários para adicionar captura WASAPI,
Media Foundation para codecs do Windows, AudioUnit/AudioToolbox no macOS e
PipeWire/ALSA com codecs do sistema no Linux. Essas partes ainda não estão
implementadas; a entrega atual cobre renderização PCM WASAPI `IAudioClient3`.
