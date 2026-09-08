# Video player multiplataforma

O exemplo usa `VideoDecoders`, a abstração comum de decodificação da
`dart_ui`, e entrega cada quadro ao `VideoFrameView`. O adaptador abre primeiro
a API do próprio sistema: Media Foundation no Windows, GStreamer no Linux e
AVFoundation/CoreVideo no macOS. Essas camadas escolhem D3D11VA, VA-API/V4L2
ou VideoToolbox quando o sistema e o codec permitem.

FFmpeg não é uma dependência do caminho normal. Ele só é procurado se o
backend nativo não conseguir abrir o arquivo. Para habilitar esse último
recurso, instale `ffmpeg` e `ffprobe` no `PATH`, ou configure
`DART_UI_FFMPEG` e `DART_UI_FFPROBE` com os caminhos completos. Aplicações que
proíbem processos externos podem usar
`VideoDecoderOptions(enableFfmpegFallback: false)`.

```powershell
dart run .\examples\video_player_demo\main.dart "C:\Videos\exemplo.mp4"
```

Também é possível abrir o programa sem argumentos e selecionar o vídeo pela
interface.

### Se a janela demora segundos para aparecer, não é o vídeo

`dart run` sobre um arquivo `.dart` **compila o grafo de imports inteiro** a
cada execução, e para este pacote isso é o framework todo. Medido nesta
máquina com `tool/startup_cost.dart`, que imprime o tempo decorrido até a
primeira instrução de `main`:

| como é executado | antes de `main()` |
|---|---|
| `dart run` a partir do fonte | **6007–6750 ms** |
| `dart compile exe` e rodar o binário | **51–101 ms** |

Cento e vinte vezes. Nada disso aparece na instrumentação do reprodutor, que
mede a partir do `main` e reporta o próprio custo — tipicamente
`decode ate 1o quadro ~500 ms · ate pintar ~560 ms`. As duas medições estão
certas e são de coisas diferentes: os segundos que se sentem são do
*front-end* do Dart, e não do pipeline de vídeo.

Para medir o reprodutor como ele seria entregue, compile antes:

```powershell
dart compile exe -o build\video_player.exe .\examples\video_player_demo\main.dart
.\build\video_player.exe "C:\Videos\exemplo.mp4"
```

Para validar decoder e dependências sem abrir uma janela:

```powershell
dart run .\examples\video_player_demo\main.dart --smoke-test --native-only "C:\Videos\exemplo.mp4"
```

## Áudio, sincronismo e o laço de reprodução

A reprodução é conduzida por um `AnimationTicker` registrado no
`AnimationClock` da janela, e não por `Future.delayed`. O laço de
`Application.run` espera mensagens nativas de forma síncrona: enquanto há um
quadro de animação armado ele limita essa espera a um intervalo de quadro, e um
temporizador comum não consegue interromper essa espera. Por isso a versão
anterior só andava quando o mouse se mexia.

O relógio mestre é o áudio. `PcmAudioPlayers.openFile` devolve um player cuja
`position` é o que a placa de som já consumiu, e cada quadro é julgado contra
essa posição pelo `AvSynchronizer` — apresentar, descartar ou esperar. Um
arquivo sem trilha de áudio (ou uma plataforma sem saída de áudio) recebe um
relógio de parede com a mesma interface; a barra inferior mostra qual dos dois
está em uso, junto de quadros por segundo, drift e contagem de descartes.

A decodificação corre um quadro à frente da apresentação e nunca é aguardada
dentro do tick. O limite de um quadro de folga não é arbitrário: os
decodificadores emprestam fatias de um anel de três ou quatro slots, então no
máximo `slotCount - 1` quadros — o exibido mais o que espera — podem ficar
retidos.

```powershell
# toca sozinho e imprime uma linha de estatística por segundo
dart run .\examples\video_player_demo\main.dart --autoplay --stats "C:\Videos\exemplo.mp4"
```

### `--no-audio`, e por que ele existe

`--autoplay` abre o dispositivo de saída e **toca o arquivo em voz alta**. Numa
medição feita sem ninguém olhando isso vira um som sem origem visível para quem
está no teclado, e foi exatamente o que aconteceu enquanto este reprodutor era
perfilado. `--no-audio` deixa a saída fechada e põe o `_WallMasterClock` no
lugar do relógio de áudio.

Ele **muda o que está sendo medido** e por isso é um flag e não o padrão: o
custo do quadro não depende de qual relógio está atrás dele — o caminho da
imagem não sabe qual dos dois é — mas drift, descartes e esperas passam a ser
números de relógio de parede e têm de ser rotulados assim.

Com `--stats`, o fim da execução imprime também a divisão do quadro em
build/layout/paint/present vinda de `Application.statistics`. É a metade
`Stopwatch` da instrumentação, e é a que funciona em AOT, onde o `Timeline` de
`tool/frame_timeline_trace.dart` não tem serviço de VM para conversar.
