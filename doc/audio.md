# Áudio nativo e tempo real

O `dart_ui` toca áudio por Dart FFI, sem wrapper C/C++: WASAPI compartilhado
(`IAudioClient3`) no Windows e Audio Queue (AudioToolbox) no macOS e no iOS.

## API portável — comece por aqui

Uma aplicação não escolhe backend. Três entradas cobrem os casos comuns, iguais
em todas as plataformas:

| Preciso de… | Use | Windows | macOS / iOS |
|---|---|---|---|
| decodificar um arquivo para PCM | `MediaAudioTracks.decodeFile(path)` | Media Foundation | ExtAudioFile |
| tocar um clipe ou arquivo com relógio de mídia | `PcmAudioPlayers.open(pcm)` / `.openFile(path)` | WASAPI | Audio Queue |
| DSP em tempo real (sintetizador, equalizador, analisadores) | `AudioProcessorOutput.open(builder, controls:)` | WASAPI num isolate dedicado | Audio Queue num isolate dedicado |

`null` é sempre uma resposta normal ("não há saída de áudio aqui"), nunca uma
exceção. No Linux as três devolvem `null` por enquanto.

```dart
import 'package:dart_ui/audio.dart';

final controls = AudioControlBlock.allocate(parameters: 1, telemetry: 1);
final output = await AudioProcessorOutput.open(
  (context) => MeuSintetizador(context.sampleRate, context.channels,
      context.controls!),
  controls: controls,
);
controls.setParameter(0, 0.5);   // o processador lê no próximo bloco
print(controls.telemetry(0));    // e publica de volta
await output?.close();
```

- O **builder** roda no isolate de áudio, já sabendo a taxa e os canais do
  dispositivo; ele decodifica, converte e monta o grafo DSP lá. Por isso precisa
  ser uma função enviável (top-level, estática, ou closure que só captura
  valores simples como um caminho). O que ele puser em `context.details` chega
  como `output.details`.
- O **`AudioControlBlock`** é memória nativa compartilhada sem lock: parâmetros
  (a aplicação escreve), gatilhos (contadores que a aplicação incrementa) e
  telemetria (o processador escreve). Cada valor é uma palavra de 32 bits
  alinhada, então o áudio nunca espera pela interface.
- A latência difere: o WASAPI acorda num período de poucos milissegundos; a
  Audio Queue é alimentada pelo laço de eventos de um isolate e mantém três
  buffers de no mínimo 512 quadros (≈32 ms a 48 kHz). Serve para música e
  análise; para um instrumento no macOS o caminho seria um AudioUnit.

O `music_player_demo` usa só essa API: o mesmo código toca no Windows e no
macOS.

## Camadas

- `lib/src/audio`: formatos PCM, dispositivos, streams e contratos de codecs
  independentes de plataforma.
- `lib/src/audio/windows`: COM/WASAPI, eventos, MMCSS e ring buffer em memória
  nativa.
- `lib/src/audio/apple`: Audio Queue e ExtAudioFile do AudioToolbox.
- `lib/src/audio/realtime`: `AudioProcessorOutput` e `AudioControlBlock`, a
  saída em tempo real portável sobre os dois.
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
cd examples/wasapi_audio_demo && dart run main.dart 3
```

O exemplo negocia o formato real, cria o stream no isolate de áudio, compartilha
o ring buffer por endereço e produz um tom de 440 Hz no isolate principal.

## DSP direto no buffer WASAPI

`WasapiRenderStream.runWithProcessor` entrega o ponteiro float32 do próprio
`IAudioRenderClient` a um `NativeFloat32AudioProcessor`. Esse caminho serve a
sintetizadores, mixers e efeitos que não precisam de um produtor separado e
remove a cópia intermediária pelo ring buffer.

`NativeSchroederReverb` implementa um reverb simples inteiramente em Dart: cada
canal usa quatro comb filters amortecidos em paralelo e dois filtros all-pass
em série. As linhas de atraso são `Pointer<Float>` alocados uma vez fora do
loop realtime.

`WasapiSharedParameterBlock` permite que a UI controle gates, volumes e efeitos
por memória nativa. A UI toma o SRW lock para escrever; o áudio apenas tenta
obter o lock e conserva o snapshot anterior em caso de contenção.

O teclado musical demonstra esse caminho:

```powershell
cd examples/wasapi_audio_demo && dart run main.dart
```

Mouse e teclado físico controlam duas oitavas polifônicas; reverb, sala,
amortecimento e volume são atualizados em tempo real sem mensagens dentro do
pump de áudio.

## WAV, samples e bateria digital

`WaveDecoder` analisa RIFF/WAVE sem biblioteca nativa e converte PCM 8, 16, 24
ou 32 bits e IEEE float32/float64 em `NativePcmAudioBuffer`. Chunks de metadados,
padding RIFF e `WAVE_FORMAT_EXTENSIBLE` são aceitos. O buffer resultante vive
fora do heap do Dart, tem descarte explícito e pode ser convertido antecipadamente
para a taxa de amostragem e o número de canais do endpoint.

`NativeSampleMixer` reproduz clips preparados com um pool fixo de vozes. O
caminho realtime não decodifica, reamostra nem aloca. Grupos de choke permitem
relações como hi-hat aberto/fechado, e `WasapiSharedTriggerBlock` preserva
disparos repetidos por contadores monotônicos em memória compartilhada.

```powershell
cd examples/drumer && dart run main.dart
```

O exemplo carrega os 12 WAV mono/24-bit/44,1 kHz de `drum_sounds`, converte-os
para o formato WASAPI e permite tocá-los por pads, arraste ou teclado físico.

## Player WAV/MP3 e equalizador

No Windows, `MediaFoundationAudioDecoder` usa `MFCreateSourceReaderFromURL` e
interfaces COM diretamente por Dart FFI para converter MP3 em PCM float32. WAV
continua usando o decoder Dart portável. `NativePcmClipPlayer` fornece cursor,
pause, busca e volume sem alocação no pump, e `WasapiSharedTelemetryBlock`
publica posição e nível para a UI sem bloquear o áudio.

Cada bloco retornado por `IMFMediaBuffer::Lock` é copiado antes de
`Unlock`/`Release`; o PCM acumulado nunca conserva uma visão de memória que
continua pertencendo ao Media Foundation. Isso é indispensável em músicas
longas, nas quais os buffers internos são reutilizados pelo decoder.

`NativeGraphicEqualizer` encadeia filtros biquad peaking constant-Q em qualquer
quantidade de bandas. Coeficientes são atualizados apenas quando um ganho muda
e coeficientes, ganhos e estados dos filtros ficam em ponteiros `Double`
nativos. O exemplo usa dez bandas (31 Hz a 16 kHz) de -12 a +12 dB, processadas
inteiramente em Dart e sem alocação por amostra. `NativeThreeBandEqualizer`
continua disponível para interfaces compactas de graves, médios e agudos.

```powershell
cd examples/music_player_demo && dart run main.dart
cd examples/music_player_demo && dart run main.dart "C:\musicas\faixa.mp3"
cd examples/music_player_demo && dart run main.dart ~/Music/faixa.m4a   # macOS
```

O player também abre arquivos pelo seletor nativo, aceita vários WAV/MP3
arrastados do gerenciador de arquivos e mantém uma lista de reprodução
selecionável com anterior, próxima, avanço automático, aleatório, repetição,
remoção e limpeza. A interface inspirada no Windows Media Player demonstra
play/pause, seek, volume, peak meter e o equalizador gráfico durante a
reprodução.

`NativeSpectrumAnalyzer` acrescenta uma telemetria espectral sem alterar o
buffer: um banco logarítmico de filtros constant-Q mantém coeficientes, estados,
acumuladores e níveis suavizados em memória nativa. O player publica 40 bandas
para a UI por telemetria lock-free e oferece uma visualização de barras reativa,
que pode ser alternada com a capa sem interferir no pump WASAPI.

`NativeWaveformAnalyzer` mantém uma janela circular mono das amostras PCM
recentes e publica 160 pontos para um osciloscópio em tempo real. Todo o
histórico vive em ponteiros `Float` e o processamento não aloca. Na camada de
widgets, `SpectrumBars` desenha todas as bandas em um único `RenderObject` e
`SignalPlot` grava a waveform em um único path. Os dois aceitam listas mutadas
in-place com um contador `revision`, portanto uma atualização visual apenas
repinta o gráfico: não executa layout de uma árvore de barras.

O exemplo amostra essa telemetria em um subtree próprio pelo `AnimationClock`
do framework (até a frequência de apresentação), enquanto posição, tempo e
playlist usam o mesmo relógio com leitura limitada a 80 ms. Isso é intencional:
um `Timer.periodic` do isolate da UI não consegue interromper uma espera
síncrona do pump nativo e poderia ficar mais rápido quando eventos de mouse
acordassem a janela. Os botões de barras e waveform alternam entre os dois
modos; clicar
novamente no modo selecionado retorna à capa.

## Próximos backends

A entrega atual cobre renderização WASAPI `IAudioClient3` e Media Foundation no
Windows, Audio Queue e ExtAudioFile no macOS e no iOS, e WAV portável. Faltam
PipeWire/ALSA no Linux, um AudioUnit de baixa latência no macOS (que depende de
`NativeCallable.isolateGroupBound`, ainda experimental no Dart), captura e
encode. Os exemplos `drumer` e `wasapi_audio_demo` continuam só no Windows
porque falam com o WASAPI diretamente para medir latência.
