# Visão geral da implementação

Este documento descreve **o que existe em `lib/`**, não o alvo. O alvo é o
[roteiro](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md); quando os dois
divergirem, o roteiro descreve a intenção e este arquivo descreve o código.

**Estado em 8 de agosto de 2026:** cinco camadas, **342 testes**, gate próprio
rodando em push nas três plataformas (formato, análise, testes e compilação
AOT). O caminho de display list até pixels está fechado.

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
platform     eventos de janela               (foundation, geometry)
rendering    contratos + renderer de CPU     (foundation, geometry, graphics)
```

A regra de dependência da seção 8.2 é imposta por onde o arquivo mora. Nenhuma
camada aqui importa um backend, e nenhum backend é citado por nome em código
comum.

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
base dos testes do framework e do futuro backend headless.

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

**Limites declarados onde o chamador esbarra neles:** sem antialiasing (a
costura é coverage-como-alpha entrando no mesmo `blendPixelOver`); retângulos
arredondados preenchem a caixa até o rasterizador ganhar um loop de canto;
`saveLayer` é um clip até existir buffer offscreen para compor; paths e texto
**lançam** em vez de desenhar algo plausível. O `probe()` do backend diz isso em
voz alta.

## O que ainda não existe

Nenhum backend de janela real, nenhuma árvore de layout, nenhum widget. O que
existe é a base sobre a qual essas coisas são escritas, com as invariantes já
travadas por teste — e agora com um caminho completo até pixels para testá-las
contra.

O caminho macOS tem POCs validados e uma decisão de arquitetura registrada
([ADR 0001](../adr/0001-worker-process-com-iosurface-no-macos.md)) mas ainda
não foi portado para `lib/` — os três backends vivem em
`poc/poc_20_macos_three_backends`.
