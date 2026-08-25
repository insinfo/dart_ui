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
