# Visão geral da implementação

Este documento descreve **o que existe em `lib/`**, não o alvo. O alvo é o
[roteiro](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md); quando os dois
divergirem, o roteiro descreve a intenção e este arquivo descreve o código.

**Estado em 15 de agosto de 2026:** onze camadas comuns, **~2.400 testes** e
gate próprio rodando em push nas três plataformas (formato, análise, testes e
compilação AOT). O caminho **Widget → Element → RenderBox → layout → display
list → rasterização → framebuffer** está fechado e testado, e agora existe em
duas implementações: CPU e OpenGL. No Windows, o `Win32CpuPresenter` continua o
caminho até uma DIB e `BitBlt`, sem cópia intermediária do frame; o
`GlWindowTarget` apresenta por swap de buffers, sem readback por frame.

`runApp` monta tudo isso — seleção de backend, janela, superfície, renderer,
scheduler, árvore e roteamento de input — e é por onde uma aplicação entra.

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
| `WM_ERASEBKGND` | retorna 1 | metade da defesa contra o flash branco no resize; a outra metade é `hbrBackground = 0` na classe, e é por isso que as duas precisam continuar juntas — reintroduzir um brush de classe com este `case` ainda pintaria por cima do framebuffer entre o erase e o BitBlt. Fixado por teste |
| `WM_PAINT` | `WindowExposedEvent` | valida a região *antes* de reportar, senão `pumpEvents` vira spin |
| `WM_SIZE` | `WindowResizedEvent` + rebuild de surface | minimizado (0x0) só muda o estado |
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
| `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` | O Windows entra em laço modal próprio: `DispatchMessageW` não retorna enquanto a borda estiver sendo arrastada, então `Win32Dispatcher._pumpNative` nunca volta para `_drainQueues` / `_fireDueTimers` e o lado Dart — onde moram layout, paint e present — congela. `WM_PAINT` até chega, mas só empilha `WindowExposedEvent` num stream que ninguém está drenando. Resultado: a janela mostra pixels velhos durante todo o arraste. |

As duas primeiras correções ficam no mesmo lugar, `Win32Window._onPointerScroll`
e o `switch` de `handleMessage`; a terceira precisa também do backend, porque
quem tem de bombear um frame durante o laço modal é o dispatcher (um `SetTimer`
armado no `WM_ENTERSIZEMOVE`, morto no `WM_EXITSIZEMOVE`, com `WM_TIMER`
pedindo um frame). As constantes que faltavam já estão em
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
| `WM_XBUTTONDOWN` / `UP` / `DBLCLK` | `PointerButton.back` e `.forward` existem no contrato e o X11 já os emite (botões 8 e 9); o Win32 não. Nenhum widget consome ainda, então hoje é divergência entre backends, não regressão visível. O botão vem em `HIWORD(wParam)` (`XBUTTON1`/`XBUTTON2`), não no id da mensagem, e o retorno correto é TRUE. |
| `WM_GETMINMAXINFO` | Não há o que responder: `WindowOptions` não tem tamanho mínimo nem máximo. Consequência hoje: a janela encolhe até o layout quebrar. A correção começa em `platform/native_window.dart`, não no backend. |
| `WM_SETTINGCHANGE` / `WM_THEMECHANGED` | `ThemeData.highContrast` existe, mas todo exemplo escolhe o tema por `argv` (`example/gallery_shell.dart`) e `window_events.dart` não tem evento de tema. Tratar antes do evento existir seria um `case` que joga o argumento fora. |
| `WM_DISPLAYCHANGE` | Mudança de resolução que mexe na janela vem seguida de `WM_SIZE`/`WM_MOVE`/`WM_DPICHANGED`, que são tratadas. O que se perde é reler os limites dos monitores — e este backend ainda não tem módulo de telas nem fullscreen. |
| `WM_SHOWWINDOW` | Não há evento de visibilidade no contrato; `hide()` também não emite nada. |
| `WM_UNICHAR` | O protocolo pede responder TRUE a `UNICODE_NOCHAR`; o `DefWindowProcW` responde FALSE e quem envia cai de volta em `WM_CHAR`, que é tratada. É por isso que nada quebra. |
| `WM_POWERBROADCAST`, `WM_INPUTLANGCHANGE`, `WM_GETDPISCALEDSIZE` | Sem consequência aqui: retomada de suspensão invalida a janela e vira `WM_PAINT`; o texto vem do `WM_CHAR` já traduzido pelo layout; e responder FALSE ao `WM_GETDPISCALEDSIZE` pede escala linear, que é o certo para um layout independente de escala. |
| `WM_IME_*`, `WM_DROPFILES`, `WM_GETOBJECT`, `WM_POINTER*` / `WM_TOUCH` | Adiadas pelo roteiro (13.7, 13.9, 13.16 e Pointer API) e declaradas ausentes no `probe()`, que é a diferença entre uma lacuna e uma mentira. |

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

### Armadilhas menores, todas sem consumidor hoje

Duas em `Win32Window._keyLocation` — nada lê `KeyEvent.location` além do
backend — erradas do jeito que só aparece quando alguém for depender delas:

  * o ramo `extended && virtualKey >= 0x60 && virtualKey <= 0x69` é **código
    morto**: o extended-key flag não é setado para `VK_NUMPAD0`-`VK_NUMPAD9` —
    ele marca AltGr, Ctrl direito, as setas cinzas, NumLock, Divide e o Enter
    do teclado numérico. Os próprios `VK_NUMPAD*` já identificam o bloco
    numérico sem ajuda, então a condição só impede a resposta certa;
  * o mesmo flag é usado para separar Shift esquerdo de direito, e o Windows
    não o seta para Shift: a distinção está no scan code (0x2A contra 0x36).
    `KeyLocation.right` para Shift, portanto, nunca é reportado.

E uma no relógio dos eventos. `PlatformInputEvent.timestamp` está documentado
como "monotonic timestamp of the event, as reported by the OS", e o Win32 usa
`DateTime.now()` — que não é monotônico nem é do SO (`GetMessageTime()` é). Pior,
usa **duas unidades**: ponteiro e teclado carimbam
`Duration(milliseconds: millisecondsSinceEpoch)` e scroll e texto carimbam
`Duration(microseconds: microsecondsSinceEpoch)`, então os dois grupos estão mil
vezes afastados um do outro. Ninguém compara entre grupos hoje — `_countClick`
em `controls.dart` só subtrai `PointerDownEvent` de `PointerDownEvent`, e o
`since >= Duration.zero` que ele já tem absorve um salto de relógio para trás —
mas o primeiro consumidor que cruzar os grupos vai encontrar isso.

## O que ainda não existe

**Vulkan, Metal, Direct3D 11 e DirectComposition** existem apenas nos POCs.
A ordem aqui é deliberada: OpenGL foi levado a ter janela, layers, atlas e
paridade com a CPU **antes** de uma segunda API entrar, porque até então
`MemorySurfaceDescriptor` era o único `NativeSurfaceDescriptor` que existia — uma
abstração de superfície validada por zero backends com janela real não é uma
abstração, é um palpite.

**Recuperação de perda de device.** `GpuDeviceState.recover()` existe e nunca é
chamado; não há orquestrador que descarte handles, recrie o contexto e repovoe
recursos, nem `RendererEvent`/`DeviceLost` da seção 23.12. `_checkError` já
distingue `GL_CONTEXT_LOST` de erro recuperável, então a metade difícil está
feita.

**Texto na GPU está implementado e não está ligado.** `GpuRasterSink` desenha
runs de glifos por atlas, e um run vira um batch — testado. Mas nenhum target
GL constrói um `GpuGlyphAtlas` e o passa ao sink, então por um device GL real
um run é recusado por nome. É uma ligação de construtor, não um algoritmo. O
teste diferencial afirma as duas metades — os pixels exatos da CPU e a recusa
da GPU — de propósito: no dia em que o atlas for ligado, aquela asserção falha
e obriga a comparação a entrar junto, em vez de a lacuna sumir em silêncio.

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
texto CFF sai sem hinting em todo tamanho. IME nativo não existe em nenhum
backend; o contrato (`TextEditingValue.composing`) está pronto e documentado
por plataforma.

**Do layout:** Grid, Wrap, medição intrínseca, baselines, `PaintContext`,
repaint boundaries e damage tracking. O `flushPaint` ainda repercorre a árvore
inteira.

**Dos backends:** X11 e macOS têm código escrito que **não foi executado** —
não há máquina Linux nem Mac aqui. O caminho EGL de janela, `x11_gl_surface.dart`
e as galerias X11/macOS compilam e analisam limpo, e nada além disso foi
provado. Trate a primeira execução como bring-up, não como regressão.

Pelo roteiro, a ordem imediata é fechar a recuperação de device e o
`PaintContext` antes de abrir uma segunda API de GPU.
