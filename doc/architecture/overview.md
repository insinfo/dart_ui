# Visão geral da implementação

Este documento descreve **o que existe em `lib/`**, não o alvo. O alvo é o
[roteiro](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md); quando os dois
divergirem, o roteiro descreve a intenção e este arquivo descreve o código.

**Estado em 23 de agosto de 2026:** onze camadas comuns, **5.562 testes** e
gate próprio rodando em push nas três plataformas (formato, análise, testes e
compilação AOT). O caminho **Widget → Element → RenderBox → layout → display
list → rasterização → framebuffer** está fechado e testado, e existe agora em
sete implementações de renderização: CPU, OpenGL, Direct3D 11, Direct3D 12,
Direct2D, Vulkan e Metal, mais WebGL2 e WebGPU no navegador — em graus de
maturidade muito diferentes, que a tabela da seção seguinte separa. No Windows,
o `Win32CpuPresenter` continua o caminho até uma DIB e `BitBlt`, sem cópia
intermediária do frame; o `GlWindowTarget` apresenta por swap de buffers, sem
readback por frame.

> A frase acima é a de sempre; a **seção seguinte é a que responde "isso
> funciona?"** em dois minutos, por plataforma, e nomeia o que não funciona.
> O restante deste arquivo foi escrito ao longo de agosto e ainda descreve, em
> alguns pontos, uma árvore anterior; onde ele e o *Estado executivo*
> divergirem, o executivo é o mais novo e foi conferido no código.

`runApp` monta tudo isso — seleção de backend, janela, superfície, renderer,
scheduler, árvore e roteamento de input — e é por onde uma aplicação entra.

---

## Estado executivo — 23 de agosto de 2026

Esta é a tabela de dois minutos. Cada célula foi conferida no código nesta data;
o que não foi conferido está escrito como **não verificado**, e não como sim.

**Medido nesta máquina hoje** (Windows 11 build 26200, Dart 3.6.2, Intel UHD),
e a primeira coisa a dizer sobre a medição é que **ela se move**: numa passada
`dart analyze` deu 38 issues, todos `info`; numa passada minutos depois deu 21
issues incluindo **três `error`** — os três da frente de swapchain do Vulkan
(`setClientSize`, `physicalSize`, `blendModeSrcOver`). `dart test` roda **5.562
testes** com 28 `skip`, e o número de falhas também mudou entre duas execuções
da mesma tarde (5, depois 12).

Isso não é ruído de medição: é o estado real de uma árvore em edição enquanto
os testes rodam, e o commit anterior (`cbe2497`, "wip: snapshot das frentes em
andamento") já dizia isso no próprio texto. **Trate a lista nomeada de *Falhas
abertas*, abaixo, como a medição — não o número.**

### O que funciona hoje, por plataforma

Legenda: **sim** existe e tem teste; **parcial** existe com limite nomeado;
**não** não existe; **—** não se aplica.

| | Windows (Win32) | Linux X11 | Linux Wayland | macOS (AppKit) | Web | Headless |
|---|---|---|---|---|---|---|
| janela + múltiplas janelas | sim | sim | sim | sim | sim (canvas) | sim |
| apresentação CPU | sim, DIB + `BitBlt` | sim, `PutImage` | sim, `wl_shm` com swapchain de até 3 buffers | sim, IOSurface/CoreGraphics | — | sim, memória |
| apresentação GPU | sim: D3D11, OpenGL/WGL, Direct2D | parcial: entrada EGL registrada e **nunca executada** | **não** | não (Metal só offscreen) | sim: WebGL2 e WebGPU | — |
| mouse + roda | sim | sim | sim | sim | parcial | sim (injetado) |
| **teclado** | sim | **não** | sim (subconjunto xkb) | sim | não verificado | sim |
| **IME / composição** | sim, IMM32 | **não** | sim, `text-input-v3` | não | não | não |
| teclas mortas / Compose | o SO compõe | não (tabela pronta, desligada) | sim, quando não há IME | — | o navegador compõe | — |
| clipboard de texto | sim | **não** | sim | não | não | sim (falso) |
| drag-and-drop | sim, OLE, dois sentidos | sim, XDND, dois sentidos | sim, `wl_data_device`, dois sentidos | não | não | não |
| popups | sim | sim | sim, `xdg_positioner` | não verificado | — | sim |
| DPI por monitor | sim | parcial: escala resolvida no probe | parcial: escala inteira, a maior dos outputs | não verificado | sim, `devicePixelRatio` | sim |
| decoração de janela | sim, nativa | sim, nativa | parcial: negocia SSD e **não desenha CSD** | sim, nativa | — | — |
| cursores | sim | sim | sim, parser XCursor próprio, animado | não verificado | sim | — |
| acessibilidade exposta ao SO | parcial (ponte UIA) | não | não | não | não | não |

A árvore semântica do framework existe e é testada; a linha acima mede outra
coisa — se algum backend a **expõe ao sistema operacional**. Nenhum reivindica
`Capability.accessibility` hoje.

### APIs de sistema operacional

| | Windows | Linux | macOS | Web |
|---|---|---|---|---|
| `StandardPaths` | sim, `SHGetKnownFolderPath` | sim, XDG + `user-dirs.dirs` | parcial: só convenção, sem `NSSearchPathForDirectoriesInDomains` | lança |
| `Shell.openUrl` | sim, `ShellExecuteW` | sim, `xdg-open`/`gio`/`kde-open5` | sim, `/usr/bin/open` | sim, `window.open` |
| `Shell.openPath` / revelar | sim | sim; revelar por D-Bus `FileManager1` | sim, `open -R` | lança |
| `Trash` | sim, `SHFileOperationW` com `FOF_ALLOWUNDO` | parcial: spec freedesktop, **só a lixeira do home** | parcial: move para `~/.Trash`, sem "Put Back" | lança |
| `SystemInfo` + tema escuro | sim, registro | sim, `gsettings` | sim, `defaults` | sim, `matchMedia` |
| `NativeMessageBox` | sim, `MessageBoxW` | parcial: subprocesso `zenity`/`kdialog` | parcial: `osascript` | lança |
| `FileWatcher` | sim, via `dart:io` | sim, via `dart:io` | sim, via `dart:io` | `isSupported == false` |
| `FilePicker` (**só abrir**) | sim, `GetOpenFileNameW` | parcial: `zenity`/`kdialog`/`yad`, **sem portal XDG** | parcial: `osascript` | sim, `<input type=file>` |
| fontes do sistema | sim, varredura executada | varredura escrita, **nunca executada** | varredura escrita, **nunca executada** | não: o arquivo importa `dart:io` |

Não existem, e nenhum deles está começado: diálogo de salvar, seletor de
diretório, seleção múltipla de arquivos, bandeja do sistema, notificações,
portais XDG.

### Renderização vetorial acelerada

O documento canônico é
[`ACELERACAO_GPU_VETORIAL.md`](ACELERACAO_GPU_VETORIAL.md); o que segue é só o
estado, conferido no código, para quem precisa decidir sem abrir aquele:

- o enum real é `GpuPathStrategy`, com seis valores — `analyticPrimitive`,
  `coverageAtlas`, `sparseStrips`, `tessellatedMesh`, `stencilThenCover`,
  `computeTiles`. **A–D são rótulos de documentação**, não identificadores;
- o seletor `GpuPathStrategySelector.select` decide por **cruzamentos de tile
  contra área**, com a taxa de câmbio medida em
  `kDefaultSparseCrossingCostInDensePixels = 50`;
- **sparse strips estão promovidas no OpenGL**: `GlSparseStripsPolicy.auto` é o
  padrão de `GlRenderDevice.adoptContext`, e o antigo booleano passou a
  significar `required`. Em **D3D12, WebGPU e WebGL2 continuam opt-in**
  (`enableExperimentalSparseStrips = false`);
- só o OpenGL tem B (tesselação retida) e C (stencil-then-cover); só o D3D12
  tem D (compute tiles), e ali **o binning é de CPU** — o compute converte em
  cobertura uma cena que já chegou binada, com supersampling em vez de área
  analítica;
- portes existentes do layout sparse: HLSL (D3D12), SPIR-V (Vulkan, emitido em
  Dart por `SpirvBuilder`), WGSL (WebGPU) e WebGL2. **Não há MSL** — o
  diretório `metal/` não contém uma linha de sparse.

### Falhas abertas nesta árvore

1. **Vulkan, frente de swapchain/WSI.** `test/rendering/gpu/vulkan/vulkan_window_test.dart`
   e `.../zz_smoke_test.dart` **não compilam**: pedem `Win32Window.setClientSize`,
   `Win32Window.physicalSize` e `blendModeSrcOver`, que não existem;
2. **Camadas.** `test/architecture/layering_test.dart` acusa quatro arestas
   novas: `geometry/bezier.dart`, `geometry/contour.dart` e
   `geometry/shaping.dart` importam `graphics`, e
   `graphics/vector/serialization/vector_pdf_exporter.dart` importa `pdf`. O
   motor vetorial entrou em `geometry/` e trouxe a dependência junto;
3. **Identificador de plataforma no núcleo.** O mesmo teste acusa
   `crypto/windows/windows_certificate_store_platform_io.dart` por nomear
   `kernel32` fora de `lib/src/backends`;
4. **Dois testes que tinham ficado velhos, não dois bugs — corrigidos em
   24/08/2026.** `test/rendering/gpu/gl_device_test.dart` exigia
   `experimentalSparseStripsEnabled == false` "porque o renderer denso precisa
   continuar sendo o padrão"; hoje afirma a política real,
   `GlSparseStripsPolicy.auto` — sparse em todo driver que exporta os símbolos,
   denso no resto. `test/rendering/text/text_rendering_test.dart` deixou de
   exigir que o renderer de CPU **recuse** uma transformação rotacionada;
5. **Editor vetorial.** `test/examples/vector_editor_interaction_test.dart` não
   compila: pede `SelectionManager.handleGrabPixels` e
   `VectorCanvasState.isEditingText`, que ainda não existem;
6. **Regressões de métrica.** `test/widgets/controls_test.dart` (largura de
   botão 65,28 onde esperava 61,28) e `test/widgets/data_grid_test.dart`
   (o clique seleciona a linha 1 onde esperava a 2) — deslocamento de uma linha
   e quatro pixels de padding, ambos em cima de edições em curso;
7. **Dependente de tempo.** `test/app/application_test.dart` — "native event
   waits are capped while a spinner is active" — falhou numa execução e passou
   noutra.

### Limitações que valem repetir

- **X11 tem teclado e clipboard desde 26/08/2026**, e não tem IME.
  `x11_keyboard.dart` decodifica `GetKeyboardMapping`/`GetModifierMapping` do
  core protocol, `X11EventTranslator.translateKey` emite `KeyEvent` e
  `TextInputEvent`, teclas mortas compõem pela tabela Compose da máquina, e
  `x11_clipboard.dart` fala selections nos dois sentidos. O probe reivindica
  `Capability.keyboardInput` e `Capability.clipboardText` quando o servidor
  responde. **Nada disso rodou contra um X server real**: a prova é por testes
  sobre bytes numa máquina Windows, e a metade FFI nunca foi executada. Fora,
  nomeado: XIM (logo, CJK), três ou mais grupos de layout,
  `DetectableAutoRepeat`, dono `INCR` no clipboard e `PRIMARY`;
- **texto rotacionado**: os **três** rasterizadores aceitam. Quando a matriz não
  cabe em máscara, a CPU e o `GpuRasterSink` caem na rota de contorno
  (`_drawGlyphRunAsOutlines`) e o **Direct2D** preenche o contorno com
  `FillGeometry`. O critério (`glyphMasksFit`) e a matriz
  (`glyphOutlineTransform`) são uma função só, compartilhada pelos três. CPU e
  OpenGL têm paridade de desvio 0; o Direct2D, que usa o rasterizador do
  `d2d1.dll`, tem tolerância declarada e medida;
- Wayland **não tem GPU** — nem EGL, nem `linux-dmabuf`, nem Vulkan. Também não
  tem touch, escala fracionária, seleção primária, ícone de arraste, nem
  desenho de decoração própria quando o compositor recusa SSD;
- Metal **não apresenta**: sem `CAMetalLayer`, sem atlas de máscara, sem atlas
  de glifos e sem pilha de layers, então path, rrect, texto e layer são
  recusados por nome. `supportsSurface` só aceita `MemorySurfaceDescriptor`;
- Vulkan tem `VulkanWindowTarget` completo — semáforos por imagem, recriação
  por `VK_ERROR_OUT_OF_DATE_KHR` — e **desde 26/08/2026 está no
  `default_platform_resolver`**, atrás de D3D11/GL/D2D/D3D12 e marcado
  `experimental: true`. A bandeira é o fato, não cautela: aquele alvo monta o
  `GpuRasterSink` sem atlas de glifos e sem `GpuFontResolver`, então o primeiro
  `drawGlyphRun` é recusado pelo nome — verificado em janela real. Ele é
  alcançável por `--presentation=vulkan` com
  `ApplicationOptions.allowExperimentalBackends`, e nunca por *fallback*.
  **D3D12 entrou sem a bandeira**, porque tem atlas de glifos e resolver:
  105 frames com texto numa janela real em Intel UHD, `errors=0`. As
  **validation layers não estão instaladas nesta máquina**, então os testes
  que as pedem provaram pixels, não validação;
- vídeo é **contrato de plumbing**: `lib/src/graphics/video/` não decodifica
  nada, e o único allocator (`GlVideoDevice`) não é referenciado por ninguém em
  `lib/`. `RendererCapabilities.supportsExternalTextures` é falso em todos os
  backends;
- o laço de tempo real (`lib/src/app/frame_loop.dart` — `FrameLoopController`,
  `FrameLoopMode.continuous`, acumulador de passo fixo, telemetria de pacing)
  existe inteiro e **continua não referenciado em `lib/`**. O arquivo passou a
  dizer isso de si mesmo e a nomear a costura que o ligaria; a política de
  espera duplicada (`pumpTimeout`, que respondia com um `idleTimeout` plano
  onde `Application.run` usa espera adaptativa com back-off) foi **removida**,
  e `test/app/frame_loop_test.dart` fixa o resto. Ver §68.2 do roteiro;
- a política de renderização **está ligada**: `RenderPolicy.restrict(...)` é
  aplicado em `GpuPathPlanningTelemetry.plan`, o único ponto onde as
  capacidades do dispositivo encontram o seletor, e por onde passam os três
  backends de GPU deste repositório. `RenderPolicyScope` continua sendo um
  escopo e não um parâmetro, mas agora o parâmetro existe (`policy:`) e o
  escopo é apenas o padrão;
- `ADR 0007` — citado por `cpu_renderer.dart`, `gpu_raster_sink.dart` e
  `text/glyph_raster.dart` — **passou a existir em 23/08/2026**
  (`doc/adr/0007-contorno-transformado-para-texto-nao-alinhado.md`), e registra
  a decisão de preencher o glifo pelo contorno sob a matriz completa quando a
  máscara em cache não serve, em vez de reamostrar o bitmap.

## Por que um package só

A seção 7 do roteiro descreve um monorepo de dezenas de packages como alvo
final, e a seção 7.1 autoriza começar em um. É o que está feito: o package é
`dart_ui`, na raiz, e `lib/src` é dividido pelas fronteiras de camada. Separar
depois é mecânico — cada diretório vira package quando tiver contrato estável,
consumidor real e testes próprios.

## Camadas existentes

```text
foundation   diagnostics, lifecycle          (não depende de nada)
geometry     Offset, Size, Rect, Transform2D (não depende de nada)
scheduler    prioridades, dispatcher         (foundation)
graphics     display list                    (foundation, geometry)
platform     eventos de janela, fontes       (foundation, geometry, scheduler)
text         Unicode, OpenType, parágrafo    (foundation, geometry, graphics)
rendering    contratos + CPU + OpenGL        (foundation, geometry, graphics, text)
layout       árvore de render                (foundation, geometry, graphics)
animation    relógio, curvas, simulações     (foundation, geometry, scheduler)
widgets      reconciliação + estado          (layout, animation)
app          runApp, WindowHost              (tudo acima, nenhum backend)
backends     adaptadores Win32/X11/macOS     (platform, rendering)
```

A regra de dependência da seção 8.2 é imposta por onde o arquivo mora. Nenhuma
camada comum importa um backend, e nenhum backend é citado por nome no núcleo.

### `foundation/`

**`diagnostics.dart`** — a seção 6.6 proíbe capturar exceção em silêncio e
apenas escolher outro backend. `BackendProbeResult` nomeia a biblioteca, o
símbolo, o dispositivo ou a permissão que faltou; `BackendSelectionError`
carrega **todas** as tentativas. `Capability` é o vocabulário abstrato: um
controle pergunta por `cpuPresentation`, nunca por Direct3D ou Metal.

**`lifecycle.dart`** — três regras que o spike macOS pagou para aprender.
`dispose` é idempotente. `DisposableBag` libera em **ordem inversa de
aquisição**, porque handles nativos formam cadeia de dependência e liberar a
dependência primeiro transforma teardown em crash. `GenerationToken` compara
dois inteiros, porque código nativo continua entregando callbacks de janelas já
fechadas e um null check não distingue "ainda não pronto" de "já morreu".

### `geometry/`

Quatro tipos de valor. `Rect` guarda quatro arestas, não origem+extensão.
`Transform2D` é afim com 6 doubles — desvio documentado do `Matrix4` da seção
9.6, justificado no [ADR 0002](../adr/0002-transform-2d-afim-em-vez-de-matrix4.md).

Decisões que um leitor precisa conhecer, todas documentadas na definição:
`intersect` devolve retângulo vazio em vez de `null`, para não espalhar `Rect?`
por toda assinatura de clip e cull; `invert()` testa `det == 0` exatamente, sem
epsilon, porque um epsilon significativo depende da magnitude das coordenadas
de quem chama; `multiply` é "this **depois** de other"; e a rotação é a do
sentido matemático padrão, que aparece horária na tela porque sistemas de
janela são y-para-baixo.

### `scheduler/`

As sete prioridades da seção 9.4, declaradas da mais urgente para a menos, cada
uma documentando seu lugar no pipeline de frame: input torna o frame atual,
animação lê o que o input escreveu, layout consome os dois, render consome
geometria pronta.

`ManualDispatcher` tem relógio virtual próprio — **nada nesta camada chama
`DateTime.now`**, então nenhum teste pode ficar intermitente por tempo. É a
base dos testes do framework e do backend headless.

Políticas, todas testadas: erros propagam com a pilha original e nunca corrompem
a fila, porque todo callback é desenfileirado e todo timer marcado como disparado
**antes** da invocação; `post` e `cancel` de dentro de um callback são o idioma
normal e são legais; `drain`/`advance`/`run` reentrantes lançam, porque um pump
aninhado quebraria a garantia de não-preempção.

**Correção ao roteiro:** a seção 9.4 escreve `post()` com parâmetro nomeado
não-anulável e sem default, o que não compila. Aqui ele tem default.

### `graphics/`

Display list em dois buffers paralelos: um `Uint32List` de palavras e um
`Float32List` de coordenadas. Cada comando tem uma palavra de cabeçalho que
carrega o opcode e a quantidade de slots int e float que ele consome — essa
redundância existe para que o leitor recuse um buffer dessincronizado em vez de
ler além do fim. O opcode 0 é inválido por definição, então memória zerada nunca
lê como comando.

Recursos são internados pela representação **armazenada**, então dois paints que
diferem só abaixo da precisão de float32 viram um id só. `reset()` mantém os
buffers e descarta apenas cursores e tabelas — a arena da seção 9.6.

O encoder recebe doubles crus, porque um `Offset` por comando contrariaria a
seção 6.5. A camada tipada por geometria é uma extension em arquivo próprio, e
tem testes só dela: é o único lugar que decide qual slot posicional significa o
quê, e uma troca de par ali é invisível em todo o resto da suíte — a lista faria
round-trip perfeito e só ficaria errada na tela.

### `platform/`

Eventos de janela são **o que o SO disse que aconteceu**, não input para
widgets. Hit test, foco e reconhecimento de gestos ficam acima e consomem
isto, o que significa que um backend nunca precisa saber o que é um widget.
Todo evento carrega geração.

`NativeWindowId` é um extension type sobre `int`, deliberadamente **não** o
handle nativo: `HWND`, `xcb_window_t` e `CGSWindowID` têm larguras e tempos de
vida diferentes, e deixá-los vazar para código comum é como suposições
específicas de backend se espalham.

### `rendering/`

Os contratos da seção 9.5 separam **backend** (a API existe nesta máquina),
**device** (conexão aberta, que pode ser *perdida* — reset de GPU, atualização
de driver; recriar um device não pode significar recriar a janela) e **target**
(os pixels de uma superfície, morre com ela). `Frame` carrega geração, então um
present que chega depois de um resize é rejeitado em vez de desenhado num
buffer que mudou de lugar.

`Framebuffer` carrega `bytesPerRow` junto com os pixels porque **não** é sempre
`width * 4` — uma superfície compartilhada arredonda o stride para cima. O
teste que sustenta isso constrói um buffer com padding e verifica que os bytes
entre linhas ficam intocados.

O renderer de CPU liga as duas metades que foram construídas sem se conhecerem:
`DisplayListPlayer` resolve transform e clip para espaço de dispositivo e emite
para um `RasterSink`; `CpuRasterizer` transforma primitivas de dispositivo em
bytes. `MemoryRenderTarget` é o que torna testável tudo que vier acima — um
teste golden não precisa de janela, GPU nem display server.

A próxima geração vetorial está especificada em
[`ACELERACAO_GPU_VETORIAL.md`](ACELERACAO_GPU_VETORIAL.md): sparse strips
híbridos como piso vertex/fragment, máscaras densas como fallback/cache e
tesselação ou compute como modos escolhidos por custo e capacidade.

O custo de texto no backend Direct2D — o que foi medido, por que o gargalo era
o rebind de bitmap e não a contagem de chamadas, e a conclusão fechada sobre
DirectWrite (opção explícita de aparência nativa, nunca o padrão) — está em
[`TEXTO_DIRECT2D.md`](TEXTO_DIRECT2D.md).

O arredondamento do blend (`mul255`) foi verificado exaustivamente nos 65536
pares contra `(v * a + 127) ~/ 255`: idêntico bit a bit, sem divisão. A
equivalência é teste, não afirmação.

**Antialiasing** está ligado por padrão. Spans interiores rodam com cobertura
255, o que pula o escalonamento e toma o mesmo loop do preenchimento duro — o
custo fica nos pixels de borda. `paint.antiAlias` existe para desligar.

O clip guarda o retângulo **duas vezes**, inteiro e exato. Desenhos de borda
dura leem o inteiro; o preenchimento AA lê o exato. A alternativa — aceitar
borda dura no clip — falharia justamente no caso comum de uma forma desenhada
exatamente sobre os limites em que é recortada (um cartão pintando o próprio
fundo): ela sairia suave nas bordas que o clip não toca e dura nas que toca, e
*quais* bordas dependeria de onde o layout sub-pixel caiu. Artefato que aparece
e some conforme o layout é o que vira "às vezes o cartão fica errado" e nunca
reproduz.

Consequência que um chamador precisa saber: **existem duas noções de vazio**.
Um clip mais estreito que um pixel não admite pixel inteiro nenhum mas ainda
admite parte de um, então um preenchimento AA pode pintar onde o duro não
pinta. Culling por `clip.isEmpty` só é correto para desenhos de borda dura.

Meia cobertura divide 127/128, não 128/128: as *posições* são quantizadas, não
as larguras, então coberturas adjacentes se encaixam e a soma de um span é
exatamente sua área (verificado em 200 mil spans aleatórios). Como 255 é ímpar,
não dá para dividir simetricamente **e** conservar; conservar ganha, porque a
alternativa deixa costura visível onde duas metades de pixel se encontram.

**Paths** preenchem por área assinada exata, não por supersampling: cada aresta
deposita sua contribuição trapezoidal num acumulador por pixel e a soma
corrente dá o winding fracionário. Sem contagem de amostras para calibrar e sem
banding em arestas quase horizontais; verificado contra uma referência
amostrada 64×64 independente, com divergência ≤ 1/255 em todo pixel. Regras
`nonZero` e `evenOdd`, ambas testadas contra uma estrela auto-intersectante,
que é onde elas diferem visivelmente.

Curvas achatam por contagem de segmentos calculada a priori pelo limite de erro
da segunda derivada, depois diferenças progressivas — sem pilha e sem corte de
profundidade silencioso. O transform é aplicado **durante** o achatamento,
então um path ampliado ganha mais segmentos em vez de facetas visíveis.

O span sink não precisou de compositor novo: um span já é pixel inteiro com o
antialiasing carregado como byte de cobertura, então dobrar esse byte no alpha
do paint — com o mesmo `mul255` que o filler usou — e pedir preenchimento duro
em fronteira inteira é exatamente certo. É por isso que um span de cobertura
total compõe bit a bit igual a um preenchimento de retângulo, e o primeiro
teste exige justamente isso.

**Limites declarados onde o chamador esbarra neles.** Stroke, caps, joins e
dash existem (`rendering/path/stroker.dart`), e texto desenha — as duas coisas
que esta seção dizia não existirem. O que resta declarado: retângulos
arredondados via `drawRRect` preenchem a caixa (via `Path` saem corretos), e
`clipPath` ainda é recusado, com clip retangular apenas. O `probe()` do backend
diz isso em voz alta, e a regra é sempre a mesma — recusar por nome é melhor
que aproximar, porque preencher a região que um contorno encerra desenharia um
bloco sólido onde se pediu uma borda.

### `layout/`

A árvore de render da seção 8: restrições entram, tamanhos e offsets saem,
pintura vai para uma `DisplayList` e hit test volta. `RenderColoredBox`,
`Padding`, `Align`, `ConstrainedBox`, `Flex` e `Stack`, dirigidos por um
`PipelineOwner` que faz flush de layout e depois de pintura.

**Relayout boundaries** são a parte que importa. Um nó é sua própria fronteira
quando não tem pai, quando o pai passou `parentUsesSize: false`, ou quando as
restrições que chegam são justas; `markNeedsLayout` sobe só até ali. O Flutter admite uma
quarta alternativa, `sizedByParent` — um nó cujo tamanho depende só das
restrições, nunca dos filhos —, deixada de fora de propósito: ela exige partir
`performLayout` em dois (`performResize` + `performLayout`) em **toda**
subclasse, para comprar fronteira num caso que restrições justas já cobrem na
maior parte. Omiti-la não afeta a saída; apenas faz um `markNeedsLayout` subir
mais alto que o necessário nesse caso específico.

**Overflow no `Flex` não corta nem lança.** Ele se dimensiona pelas restrições,
deixa os filhos passarem visivelmente da borda e registra o excesso. Cortar
esconde o bug; lançar transforma um frame transitório de resize ou animação em
crash. O corte continua disponível como nó envolvente, não como flag.

Ler `size` de um pai que passou `parentUsesSize: false` **lança** — verificação
de runtime, não `assert`, então sobrevive ao AOT, ao custo de uma comparação
com null fora do layout. Esse engano produz layouts obsoletos em silêncio.

Adiado, sempre anotado onde o chamador esbarra: sizing intrínseco, baselines,
RTL, repaint boundaries (o `flushPaint` hoje repercorre a árvore inteira).

### Teste de ponta a ponta

`test/end_to_end_test.dart` exercita as seis camadas juntas. As suítes por
camada já provam cada peça contra o próprio contrato; esse arquivo existe para
a falha que elas não pegam — duas camadas cada uma correta e **discordando
entre si** sobre coordenadas, ordem de canais ou bordas. Um padding de 4 tem
que colocar a fronteira de cor exatamente em `x=4` nos pixels; um flex 1:3 tem
que cair em `x=4` de 16. Cada uma dessas afirmações vira falsa se duas camadas
divergirem por um pixel.

O caso de hit test é o que vale além disso: uma árvore pode renderizar
perfeitamente e ainda rotear cliques para o nó errado, então o teste exige que
o acerto caia na mesma caixa cuja cor está sob aquele pixel.

### `text/`

A camada mais densa do repositório, e a que mais depende de dados externos
serem verificáveis. As tabelas Unicode não são escritas à mão: saem de
`tool/generate_unicode_tables.dart`, que lê `referencias/unicode/ucd.nounihan.flat.xml`
(UCD 17.0.0) e cobre U+0000..U+10FFFF **sem lacuna** — o gerador se recusa a
emitir uma tabela cuja cobertura não seja exatamente 1.114.112 code points.
`--verify-existing` re-deriva as tabelas já comitadas e compara byte a byte,
então "gerado do UCD" deixou de ser uma alegação e virou um comando.

BiDi (UAX #9), grapheme clusters (UAX #29), quebra de linha (UAX #14) e
itemização de script (UAX #24) têm conformance contra os arquivos de teste do
próprio UCD. **Normalização (UAX #15) e word break não têm** — `NormalizationTest.txt`
e `WordBreakTest.txt` não estão em `referencias/unicode/`, e os casos são
escritos à mão citando a fonte. Essa assimetria é deliberada e está registrada
aqui porque, de fora, as quatro suítes parecem ter o mesmo grau de garantia.

Fontes: TrueType (`glyf` + interpretador de hinting) e CFF/CFF2 (charstrings
Type 2). GSUB e GPOS têm **todos os 8 tipos de lookup cada**. O shaping despacha
por script; árabe tem máquina de joining própria. Um script cujo modelo não
existe — devanágari, tailandês — **lança** em vez de ser moldado pelo caminho
default, porque o default produz glifos em ordem errada e não um erro; a
contenção de `widgets/errors.dart` transforma isso num placeholder naquela
subárvore, não numa janela morta.

`Paragraph` é onde tudo se encontra, na ordem que a UAX #9 exige: resolver BiDi
do parágrafo inteiro → itemizar → segmentar → moldar → quebrar → **reordenar
visualmente por linha, depois da quebra**. Inverter as duas últimas dá texto
bidi errado apenas em parágrafos que quebram, que é o bug que passa em todo
teste de uma linha.

### `rendering/gpu/`

OpenGL, via WGL no Windows e EGL no Linux. `GlWindowTarget` apresenta por swap;
`_readPixels` continua privado de propósito, para que o caminho de janela seja
*estruturalmente* incapaz de herdar o readback por frame que a seção 23 proíbe.

Três atlas, todos com a mesma disciplina: chave que inclui tudo que muda os
pixels, eviction LRU que nunca despeja algo que o frame corrente já desenhou, e
"cheio" como **sinal de flush**, não como falha do frame. O de glifos é
persistente entre frames (o de máscaras não podia servir: ele reseta o packer
em `beginFrame`, e um glifo é justamente a coisa que se repete). Um run de
texto vira **um** batch — medido em teste, porque um draw call por glifo não
seria aceleração nenhuma.

## Cobertura de mensagens do Win32

Três bugs de produção seguidos tiveram a mesma raiz: uma mensagem que o
`WndProc` não traduzia, com o widget certo já esperando do outro lado.
`WM_CHAR` não era tratado, então o campo de texto derivava o caractere do
virtual-key e `VK_NUMPAD1` (0x61) digitava `a`. `WM_LBUTTONDBLCLK` não era
tratado, e como a classe usa `CS_DBLCLKS` o Windows manda essa mensagem **no
lugar** do segundo `WM_LBUTTONDOWN` — o duplo clique não existia, por mais
correta que fosse a contagem no `RenderTextField`. `WM_MBUTTONDOWN` não era
tratado, então o botão do meio não tinha nem clique simples.

Nenhum dos três foi pego por 2733 testes, e o motivo é estrutural: os testes de
widget injetam `PointerDownEvent` / `KeyDownEvent` prontos, ou seja, injetam
exatamente o passo que estava faltando. A única camada em que "o backend nunca
produziu esse evento" é uma afirmação testável é o próprio `WndProc`, com um
HWND real — que é o que `test/backends/win32/win32_mouse_input_test.dart`,
`win32_text_input_test.dart` e `win32_message_coverage_test.dart` fazem.

Esta seção é o levantamento completo, para que a próxima pessoa não precise
redescobrir a lista. **Tratada** significa que há um `case` em
`Win32Window.handleMessage`; o resto cai no arm `default`, que devolve
`DefWindowProcW` — o que às vezes é a resposta certa e às vezes é o bug.

### Tratadas

| Mensagem | O que produz | Observação |
| --- | --- | --- |
| `WM_NCCREATE` | associa o token do `CREATESTRUCT` ao HWND | em `win32_window_class.dart`, antes de `GWLP_USERDATA` existir |
| `WM_ERASEBKGND` | pinta a faixa ainda não desenhada e retorna 1 | metade da defesa contra o flash branco no resize; a outra metade é `hbrBackground = 0` na classe, e é por isso que as duas precisam continuar juntas — reintroduzir um brush de classe com este `case` ainda pintaria por cima do framebuffer entre o erase e o BitBlt. Fixado por teste |
| `WM_PAINT` | `WindowExposedEvent` | valida a região *antes* de reportar, senão `pumpEvents` vira spin |
| `WM_SIZE` | `WindowResizedEvent` + rebuild de surface + **frame síncrono ou fundo do tema** | minimizado (0x0) só muda o estado; ver "Resize ao vivo" abaixo |
| `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` | marcam o laço modal do SO | é a única coisa que distingue um `WM_SIZE` de dentro do laço - onde nada mais roda - de um de fora |
| `WM_GETMINMAXINFO` | escreve `ptMinTrackSize` / `ptMaxTrackSize` de `WindowOptions.minimumSize` / `maximumSize` | só os campos configurados; o resto continua sendo o padrão da plataforma |
| `WM_XBUTTONDOWN` / `UP` / `DBLCLK` | `PointerDownEvent` / `PointerUpEvent` com `PointerButton.back` / `.forward` | o botão vem em `HIWORD(wParam)`, não no id da mensagem, e o retorno é TRUE |
| `WM_MOVE` | `WindowMovedEvent` | |
| `WM_DPICHANGED` | `WindowScaleChangedEvent` + `SetWindowPos` | **usa o retângulo sugerido pelo SO**; fixado por teste |
| `WM_ACTIVATE` | `WindowActivationEvent` | também dá `reset()` no `TextInputAssembler` |
| `WM_SETFOCUS` / `WM_KILLFOCUS` | `WindowActivationEvent`, deduplicado com o `WM_ACTIVATE` | acrescentado junto com múltiplas janelas: ativação e foco de teclado não são o mesmo evento quando duas janelas do mesmo aplicativo trocam o caret |
| `WM_SETCURSOR` | `SetCursor` + retorna 1 para `HTCLIENT` | a classe registra `hCursor = 0` de propósito; o frame fica com o `DefWindowProcW`. Está ligado e fixado por teste |
| `WM_CLOSE` | `WindowCloseRequestedEvent` | pedido, não ordem |
| `WM_QUERYENDSESSION` / `WM_ENDSESSION` | `onSessionEnding` | |
| `WM_DESTROY` / `WM_NCDESTROY` | `WindowClosedEvent`, solta o token | |
| `WM_MOUSEMOVE` | `PointerMoveEvent` (+ `TrackMouseEvent` na primeira) | |
| `WM_MOUSELEAVE` | `WindowPointerLeaveEvent` | |
| `WM_CAPTURECHANGED` | `PointerCancelEvent` se havia botão preso | |
| `WM_L/R/MBUTTONDOWN` / `UP` | `PointerDownEvent` / `PointerUpEvent` | com `SetCapture` no primeiro botão |
| `WM_L/R/MBUTTONDBLCLK` | `PointerDownEvent(clickCount: 2)` | substitui o segundo down, não o acompanha |
| `WM_MOUSEWHEEL` | `PointerScrollEvent` em linhas | coordenadas de tela convertidas com `ScreenToClient`; **o sinal está invertido**, ver abaixo |
| `WM_KEYDOWN/UP`, `WM_SYSKEYDOWN/UP` | `KeyDownEvent` / `KeyUpEvent` | |
| `WM_CHAR` | `TextInputEvent` | par surrogate remontado, controle descartado |
| `WM_SYSCHAR`, `WM_DEADCHAR`, `WM_SYSDEADCHAR` | nada, de propósito | mnemônico de menu e metade morta de dead key não são texto |
| `WM_QUIT` | encerra o pump | no laço do backend, não no `WndProc` |

### Não tratadas, com consumidor esperando — são bugs

| Mensagem | Consequência observável |
| --- | --- |
| `WM_MOUSEHWHEEL` (0x020E) | Um `ScrollViewer` com `ScrollAxis.horizontal` lê `event.scrollDelta.dx` (`widgets/controls.dart`). No Windows `dx` só é diferente de zero com Shift segurado, então roda inclinável e swipe lateral de trackpad **não rolam nada**. O X11 já preenche esse eixo (botões 6 e 7). |
| `WM_MOUSEWHEEL`, sinal | `HIWORD(wParam)` positivo significa roda girada **para longe** do usuário, que rola **para cima**. O contrato do framework diz o contrário e diz em três lugares: `PointerScrollEvent.scrollDelta` documenta positivo como "toward increasing coordinates", `RenderScrollViewer` mapeia seta para baixo como `applyDelta(+lineExtent)`, e o X11 traduz botão 5 (roda para baixo) como `Offset(0, +1)`. `_onPointerScroll` não nega o valor, então **no Windows a roda rola ao contrário** de todo o resto do framework. |


As duas correções ficam no mesmo lugar, `Win32Window._onPointerScroll` e o
`switch` de `handleMessage`. **As duas estão feitas.** O fundo preto no resize,
que era o terceiro item, virou a seção "Resize ao vivo" abaixo: um `SetTimer`
não resolveria, porque `WM_TIMER` também é entregue *pelo laço modal* e o
callback do timer é Dart — ele iria para a fila que ninguém drena. As constantes que faltavam já estão em
`win32_constants.dart` (`wmMousehwheel`, `wmXbuttondblclk`, `wmEntersizemove`,
`wmExitsizemove`, `wheelDelta`, `xbutton1`/`xbutton2`). O sinal é uma negação:

```dart
// WHEEL_DELTA positivo é roda para longe do usuário, que rola para cima; o
// contrato aqui chama isso de negativo. WM_MOUSEHWHEEL já é positivo-para-a-
// direita, que é o mesmo sinal do contrato, então só o vertical é negado.
final raw = win32SignedHiWord(wParam) / wheelDelta;
final delta = horizontal ? raw : -raw;
final sideways = horizontal || (wParam & mkShift) != 0;
```

Vale fazer `WM_XBUTTON*` na mesma passada — ele é lacuna e não bug (ver abaixo),
mas é o mesmo `switch` e três linhas. Ele deve devolver TRUE (1), não 0, e o
botão vem de `HIWORD(wParam)`: `XBUTTON1` é `PointerButton.back` e `XBUTTON2` é
`PointerButton.forward`, que é a mesma convenção dos botões 8 e 9 do X11.

Os testes que pegam as duas primeiras vão em
`test/backends/win32/win32_message_coverage_test.dart`, no mesmo padrão do
resto do arquivo, e **foram executados contra o código atual: falham** com
`Actual: <-1.0>` e com `Bad state: No element`.

```dart
test('the wheel scrolls the same way the Down arrow does', () async {
  // Roda para perto do usuário é WHEEL_DELTA negativo e quer dizer "rolar
  // para baixo", que é applyDelta(+lineExtent), que é dy positivo aqui.
  await send(wmMousewheel, (-wheelDelta & 0xFFFF) << 16, 0);
  expect(
    events.whereType<PointerScrollEvent>().single.scrollDelta.dy,
    greaterThan(0),
  );
});

test('the horizontal wheel produces a horizontal scroll', () async {
  await send(wmMousehwheel, wheelDelta << 16, _at(10, 10));
  final PointerScrollEvent scroll =
      events.whereType<PointerScrollEvent>().single;
  expect(scroll.scrollDelta.dx, greaterThan(0));
  expect(scroll.scrollDelta.dy, 0.0);
});

test('the side buttons press and release', () async {
  await send(wmXbuttondown, xbutton1 << 16, _at(10, 10));
  expect(
    events.whereType<PointerDownEvent>().single.button,
    PointerButton.back,
  );
  await send(wmXbuttonup, xbutton2 << 16, _at(10, 10));
  expect(
    events.whereType<PointerUpEvent>().single.button,
    PointerButton.forward,
  );
});
```

### Não tratadas, sem consumidor — são lacunas

| Mensagem | Por que ainda não dói, e o que falta |
| --- | --- |
| `WM_SETTINGCHANGE` / `WM_THEMECHANGED` | `ThemeData.highContrast` existe, mas todo exemplo escolhe o tema por `argv` (`example/gallery_shell.dart`) e `window_events.dart` não tem evento de tema. Tratar antes do evento existir seria um `case` que joga o argumento fora. |
| `WM_DISPLAYCHANGE` | Mudança de resolução que mexe na janela vem seguida de `WM_SIZE`/`WM_MOVE`/`WM_DPICHANGED`, que são tratadas. O que se perde é reler os limites dos monitores — e este backend ainda não tem módulo de telas nem fullscreen. |
| `WM_SHOWWINDOW` | Não há evento de visibilidade no contrato; `hide()` também não emite nada. |
| `WM_UNICHAR` | O protocolo pede responder TRUE a `UNICODE_NOCHAR`; o `DefWindowProcW` responde FALSE e quem envia cai de volta em `WM_CHAR`, que é tratada. É por isso que nada quebra. |
| `WM_POWERBROADCAST`, `WM_INPUTLANGCHANGE`, `WM_GETDPISCALEDSIZE` | Sem consequência aqui: retomada de suspensão invalida a janela e vira `WM_PAINT`; o texto vem do `WM_CHAR` já traduzido pelo layout; e responder FALSE ao `WM_GETDPISCALEDSIZE` pede escala linear, que é o certo para um layout independente de escala. |
| `WM_DROPFILES`, `WM_POINTER*` / `WM_TOUCH` | Adiadas pelo roteiro (13.9 e Pointer API) e declaradas ausentes no `probe()`, que é a diferença entre uma lacuna e uma mentira. |
| `WM_IME_REQUEST` | **Tratada como "não é minha"**, e a consequência tem nome: `IMR_DOCUMENTFEED` é como um IME IMM32 obtém o texto ao redor do cursor para conversão contextual, e `IMR_RECONVERTSTRING` é reconversão. Nenhuma das duas é respondida, então `TextInputBackend.usesSurroundingText` reporta `false` no Win32 e um IME japonês converte cada frase sem saber o que veio antes. É uma lacuna real, não um esquecimento. |

### Não tratadas de propósito

`WM_NCHITTEST`, `WM_NCCALCSIZE`, `WM_SYSCOMMAND` e `WM_MOUSEACTIVATE` são do
`DefWindowProcW` e devem continuar sendo: a moldura aqui é a da plataforma
(`WS_OVERLAPPEDWINDOW`), e é a resposta padrão que faz arrastar a barra de
título, redimensionar pela borda e ativar a janela no primeiro clique
funcionarem. Isso torna o arm `default` de `handleMessage` uma peça estrutural,
não uma formalidade — um `default` que devolvesse 0 mataria a moldura inteira
para o mouse sem que nenhuma outra mensagem parasse de funcionar. Há teste
justamente para isso.

O único efeito colateral visível é o *ding* do sistema em acordes Alt sem menu
para casar, que é o que `SC_KEYMENU` faz com uma barra de menus vazia.

### Resize ao vivo, e por que ele é opcional

O bug relatado: arrastar a borda deixava a área nova **preta** até soltar o
mouse. Não é lentidão. Entre `WM_ENTERSIZEMOVE` e `WM_EXITSIZEMOVE` o Windows
roda um laço modal **dentro do SO**; `DispatchMessageW` não retorna, então o
`Win32Dispatcher` nunca volta de `_pumpNative` para `_drainQueues`, o loop de
eventos do Dart não roda *nenhuma* vez, e todo listener de todo evento de
janela mora exatamente lá. `WM_SIZE` chega, o `WindowResizedEvent` é enfileirado
num broadcast stream que ninguém está drenando, e o frame que preencheria os
pixels novos é desenhado depois do arraste.

A correção tem duas metades, e as duas são obrigatórias:

**1. Um frame síncrono, chamado de dentro do handler.** É o que o POC-01 faz em
doze linhas. Aqui a mesma ideia é `LiveResizeWindow` (em
`platform/native_window.dart`): a janela chama um callback de dentro de
`_onSize`, e `ApplicationWindow.drawFrameSynchronously` faz build, layout,
paint e present **sem nenhum `await`**. `drawFrame` não serve: é `async`, e
tudo depois do primeiro `await` roda numa microtask que não será agendada até o
arraste acabar — inclusive o `finally` que limpa `_inFrame`, o que deixaria a
janela recusando frames pelo resto do processo. Por isso existe
`SynchronousSurfacePresenter` / `WindowHost.presentNow`: o caminho do
`Win32CpuPresenter` já era todo síncrono por baixo, mas nada no *tipo* dizia
isso, e "por acaso não tem await" não é contrato.

O frame síncrono só roda dentro do laço modal (`_inSizeMove`), não é reentrante
(`_inLiveFrame`, com as mensagens recusadas contadas em
`liveResizeFramesSuppressed`) e respeita a geração: cada `WM_SIZE` invalida o
`GenerationToken`, e `presentNow` recusa um frame começado antes dela
exatamente como o caminho assíncrono recusa.

**2. Uma cor onde nenhum frame chegou.** `ApplicationOptions.liveResize: false`
tem de ser melhor que o estado anterior, não igual. A conclusão da investigação
de `WM_ERASEBKGND` + `hbrBackground` é que **o lugar óbvio não funciona**:
`WM_ERASEBKGND` não é enviado pelo despacho de `WM_PAINT`, é enviado por
`BeginPaint`, e `Win32Window._onPaint` deliberadamente não chama `BeginPaint` —
lê o retângulo de update e valida, porque a apresentação aqui é assíncrona e não
passa pelo DC do paint. Uma correção que morasse só ali seria código morto que
passa no próprio teste. Então a faixa é pintada em `WM_SIZE`, no momento em que
ela é criada, com `GetDC` + `FillRect` e um brush por janela vindo de
`WindowOptions.backgroundColor`; `WM_ERASEBKGND` faz a mesma coisa e continua
respondendo 1, para os caminhos que realmente o enviam (`RedrawWindow` com
`RDW_ERASENOW`, `ScrollWindow`). Nunca a área toda: só o que está fora do
retângulo já apresentado, senão seria o flash de cor chapada que o
`hbrBackground = 0` existe para evitar.

**O custo, medido.** `example/benchmark_live_resize.dart`, árvore da galeria,
200 mensagens sintéticas pelo `WndProc` real, `dart run` (JIT):

```
liveResize=on   5883 us por WM_SIZE   200 frames   ~170 fps
liveResize=off    49 us por WM_SIZE     0 frames
```

O frame é a diferença inteira. O número que decide não é a razão e sim o
absoluto: 5,8 ms cabe folgado num quadro de 16,7 ms, então arrastar essa árvore
desenha todos os passos e continua acima de 60 fps. Por isso o default é
**ligado**. Uma árvore de 30 ms de layout faria o mesmo arraste parecer 30 fps,
e é para essa aplicação que a opção existe.

Verificado no laço modal real do SO (`WM_SYSCOMMAND`/`SC_SIZE`), lendo os
pixels da janela com `GetPixel` logo depois: com a opção ligada, os pontos da
faixa nova trazem o conteúdo desenhado; com ela desligada, trazem a cor de
fundo do tema (`0xF3F3F3`); com o `_paintExposedRegion` removido, trazem
`0x000000` — o preto do relato.

### Armadilhas menores — fechadas

Duas estavam em `Win32Window._keyLocation`, erradas do jeito que só aparece
quando alguém for depender delas, e as duas estão corrigidas:

  * o ramo `extended && virtualKey >= 0x60 && virtualKey <= 0x69` era **código
    morto**: o extended-key flag não é setado para `VK_NUMPAD0`-`VK_NUMPAD9` —
    ele marca AltGr, Ctrl direito, as setas cinzas, NumLock, Divide e o Enter
    do teclado numérico. Os próprios `VK_NUMPAD*` já identificam o bloco
    numérico sem ajuda, então a condição só impedia a resposta certa.
    Agora o bloco inteiro `VK_NUMPAD0`..`VK_DIVIDE` é `KeyLocation.numpad`,
    incondicionalmente, mais o `VK_RETURN` extended, que é o Enter do teclado
    numérico;
  * o mesmo flag era usado para separar Shift esquerdo de direito, e o Windows
    não o seta para Shift: a distinção está no scan code (0x2A contra 0x36).
    `KeyLocation.right` para Shift nunca era reportado. Agora vem do scan code.
    Ctrl e Alt continuam usando o flag, que para eles é o critério certo.

E uma no relógio dos eventos, também fechada. `PlatformInputEvent.timestamp`
está documentado como "monotonic timestamp of the event, as reported by the OS",
e o Win32 usava `DateTime.now()` — que não é monotônico, não é do SO, e não é
sequer sobre *aquela mensagem*: era o instante em que o handler por acaso
rodou. Os quatro caminhos (ponteiro, teclado, scroll, texto) agora carimbam
`Duration(milliseconds: GetMessageTime())`, que é o carimbo do próprio SO para
a mensagem em despacho. Quatro eventos derivados de uma mensagem passam a ter
timestamps **iguais**, não apenas próximos, e o valor é tempo desde o boot em
vez de tempo desde 1970 — o que o `_countClick` de `controls.dart` compara faz
sentido nas duas pontas. `GetMessageTime` é um contador de 32 bits com sinal e
dá a volta a cada ~24,8 dias de uptime; quem subtrai dois deles através da volta
vê intervalo negativo, que é exatamente o caso que o `since >= Duration.zero`
do `_countClick` já trata.

## O que ainda não existe

> **Três parágrafos desta seção envelheceram e foram corrigidos em 23 de agosto
> de 2026.** Ficam registrados com a correção ao lado, e não apagados, porque
> saber *quando* uma lacuna fechou é parte do valor deste arquivo.

**~~Vulkan, Metal, Direct3D 11 e DirectComposition existem apenas nos POCs.~~**
**Corrigido:** D3D11, D3D12, Direct2D, Vulkan e Metal existem em `lib/`, com
testes. **DirectComposition continua não existindo.** A ordem original era
deliberada — OpenGL ganhou janela, layers, atlas e paridade com a CPU **antes**
de uma segunda API entrar, porque até então `MemorySurfaceDescriptor` era o
único `NativeSurfaceDescriptor` que existia, e uma abstração de superfície
validada por zero backends com janela real não é uma abstração, é um palpite.
A **distância entre existir e ser escolhível** encolheu em 26/08/2026:
`default_platform_resolver.dart` oferece, no Windows, D3D11 → OpenGL →
Direct2D → **D3D12** → **Vulkan** (experimental) → DIB. O que resta da
distância é o Metal, que não apresenta.

**~~Recuperação de perda de device: `GpuDeviceState.recover()` existe e nunca é
chamado.~~** **Corrigido:** `lib/src/rendering/gpu/gpu_recovery.dart` é o
orquestrador que faltava, e `recover()` é chamado pelos backends GL, D3D11,
WebGL e WebGPU. `_checkError` já distinguia `GL_CONTEXT_LOST` de erro
recuperável, que era a metade difícil.

**~~Texto na GPU está implementado e não está ligado.~~** **Corrigido:** o
atlas é construído e passado ao sink em GL (`gl_backend.dart`,
`gl_window_target.dart`), D3D11, D3D12, WebGL2 e WebGPU. A recusa por nome que
o teste diferencial afirmava não existe mais nesses caminhos.

**Três divergências CPU↔GPU conhecidas, todas medidas.** Blend mode por
primitiva foi corrigido e agora concorda com desvio 0 (retângulos `plus`
sobrepostos, `src` translúcido, path com `plus`). Restam:

  * **`src` sobre forma baseada em máscara** (path, rrect, glifo): desvio até
    255. A GPU desenha o quad inteiro da máscara e o `ONE, ZERO` apaga os
    pixels de cobertura zero **dentro** dele; a CPU não os toca. É semântica do
    lado da GPU, em `gpu_raster_sink._drawMask`.
  * **Retângulos antialiasados, qualquer modo**: desvio 1. Pré-existente e não
    relacionado a blend — `raster/coverage.dart` quantiza posições em 1/255
    enquanto o shader mantém float, o que `gl_shaders.dart` já documenta como
    "limitado a um nível de cobertura por eixo". É por isso que toda cena de
    retângulo da suíte diferencial usa `antiAlias: false`.
  * **Alfa do paint em imagens**: `drawFramebuffer` na CPU ignora, a GPU
    modula. Invisível nas cenas atuais porque todas usam `0xFFFFFFFF`.

A suíte em `test/differential/` só contém cenas em que os dois concordam com
tolerância **0**. As três acima estão de fora **por estarem erradas**, não por
serem ruído, e é essa distinção que faz a tolerância 0 valer alguma coisa.

**`Frame.framebuffer` é não-anulável**, e um target GPU com janela não tem
pixels visíveis pela CPU. O `GlWindowTarget` carrega um placeholder 1×1 nunca
lido. A correção é tornar o campo anulável ou partir o `Frame`; está anotada
porque um placeholder é exatamente o tipo de coisa que vira permanente.

**Do texto:** COLR/CPAL, CBDT e sbix (emoji colorido), fontes variáveis
(`fvar`/`gvar`/`avar`), shaping índico/USE, escrita vertical CJK, `BASE`, e
hinting de CFF — os parâmetros de hint são parseados e nunca aplicados, então
texto CFF sai sem hinting em todo tamanho.

## Composição de texto (IME), por plataforma

O contrato é `lib/src/platform/text_input.dart`: `TextInputClient` é o campo em
que o método de entrada compõe, `TextInputConnection` é a associação viva com
uma janela, e `TextInputBackend` é o que cada plataforma implementa. Segue a
forma do porte de drag-and-drop, inclusive nas assimetrias — que estão
modeladas, não suavizadas.

| | Win32 (IMM32) | Wayland (`zwp_text_input_v3`) | X11 | headless / web |
| --- | --- | --- | --- | --- |
| pré-edição | sim, desenhada pelo framework | sim | **não** | não |
| estilo por cláusula | sim (`GCS_COMPATTR`) | **não existe no v3** | — | — |
| texto ao redor | **não** (`WM_IME_REQUEST` não respondida) | sim | — | — |
| `delete_surrounding_text` | não existe no protocolo | sim | — | — |
| retângulo do cursor | `ImmSetCandidateWindow` | `set_cursor_rectangle` | — | — |
| teclas mortas | o SO compõe (`WM_DEADCHAR` → `WM_CHAR`) | tabela Compose do X11, quando não há IME | **sim**, tabela Compose do X11, sempre (não há IME aqui) | o navegador compõe |
| `Capability.textComposition` | quando `imm32` carrega | quando o compositor anuncia o protocolo | **não** (XIM não implementado) | nunca |

Três consequências que valem repetir porque cada uma já foi bug em algum
toolkit:

* **O `serial` do `done` do Wayland é uma contagem de `commit`s**, não um token.
  Um `done` atrasado descreve um estado que o cliente já substituiu, e o
  `delete_surrounding_text` dele está medido em bytes contra um texto ao redor
  que não vale mais. `WaylandTextInputManager` descarta a deleção e aplica as
  strings, que são absolutas. Errar isso parece um IME que come uma letra de
  vez em quando.
* **`ImmGetCompositionStringW` só vale dentro do `WM_IME_COMPOSITION`.** O
  bridge Win32 lê tudo dentro do `WndProc` e empurra um valor imutável para
  cima; nada devolve acessor preguiçoso e nada faz `await`.
* **A pré-edição não entra em `set_surrounding_text`.** Os caracteres
  provisórios são do método de entrada, não do documento; devolvê-los faz o
  método ver a própria saída como contexto e no Wayland é violação de
  protocolo.

### X11: a decisão, com a evidência

**Revisado em 26/08/2026.** A razão registrada aqui era que não havia
teclado. Isso caiu: `x11_keyboard.dart` lê o mapa do core protocol e
`X11EventTranslator.translateKey` emite `KeyEvent` e `TextInputEvent`. O
backend reivindica `Capability.keyboardInput` quando o servidor respondeu — e
não reivindica quando ele recusou, caso em que os `KeyEvent` continuam saindo
com o keycode físico e texto nenhum é inventado.

**O backend X11 continua sem IME**, e agora pela razão que sempre foi a
verdadeira para o IME em si: XIM é um protocolo próprio sobre `ClientMessage` e
propriedades, com negociação de ordem de bytes e um servidor externo que pode
morrer no meio, e **não tem equivalente em XCB** — precisaria de Xlib e de um
input context. O que isso custa está nomeado: **CJK indisponível neste
backend**.

O que **não** custa é acentuação. `lib/src/platform/compose_sequences.dart` lê
as tabelas Compose do próprio X11 (`$XCOMPOSEFILE`, `~/.XCompose`,
`/usr/share/X11/locale/<locale>/Compose`, com `include` e `%L`/`%H`/`%S`) e
resolve teclas mortas. Está ligado no **Wayland** — só quando o compositor não
oferece `zwp_text_input_v3`, porque rodar os dois aplicaria o acento duas vezes
— e está ligado no **X11 sem condicional**, porque aqui não há método de
entrada que já pudesse compor.

**A rota escolhida foi o core protocol, não XKB nem `libxkbcommon`**, e o topo
de `x11_keyboard.dart` registra por quê e o que ela não cobre: só dois grupos
de layout, sem grupo por evento e sem `DetectableAutoRepeat`. `libxcb-xkb`
continua sendo a resposta para esses três.

**Fica de fora no X11, explicitamente:** CJK (chinês, japonês, coreano),
qualquer pré-edição, e a acentuação por tecla morta — esta última só até o
teclado XKB do backend chegar, quando é ligar o `ComposeEngine` no mesmo ponto
em que o Wayland liga.

**~~Do layout: Grid, Wrap~~** — **corrigido em 23/08/2026:** `RenderGrid`,
`RenderWrap`, `Grid` e `Wrap` existem. Continuam faltando **medição
intrínseca, baselines e damage tracking**; `RenderRepaintBoundary` existe
(`render_proxy_box.dart`), mas o `flushPaint` ainda repercorre a árvore
inteira, então a fronteira ainda não economiza a caminhada.

**Dos backends** (revisto em 23/08/2026): X11 **foi** executado sob Xvfb no CI
(apresentação `PutImage`, depth 24/BGRA8888) e macOS **foi** executado num
runner `macos-14` arm64. O que continua sem nunca ter rodado é o **caminho EGL
de janela no X11** — `x11_gl_surface.dart`, cujo teste diz por escrito "has
never been executed" — e o **backend Wayland contra um compositor real**: toda
a sua suíte roda contra um compositor falso em memória, e a camada FFI
(`sendmsg`/`recvmsg`/`SCM_RIGHTS`/`memfd`) não tem cobertura automatizada
nenhuma. Trate a primeira execução desses dois como bring-up, não como
regressão.

Pelo roteiro, a ordem imediata deixou de ser "device loss e `PaintContext`":
device loss fechou, e as frentes abertas hoje estão listadas em *Falhas
abertas*, acima.
