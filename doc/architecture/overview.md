# Visão geral da implementação

Este documento descreve **o que existe em `lib/`**, não o alvo. O alvo é o
[roteiro](../ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md); quando os dois
divergirem, o roteiro descreve a intenção e este arquivo descreve o código.

**Estado em 8 de agosto de 2026:** seis camadas, **575 testes**, gate próprio
rodando em push nas três plataformas (formato, análise, testes e compilação
AOT). O caminho **restrições → layout → display list → rasterização → pixels**
está fechado e testado ponta a ponta, sem janela, GPU ou display server.

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
layout       árvore de render                (foundation, geometry, graphics)
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

**Limites declarados onde o chamador esbarra neles:** stroke, caps, joins e
dash **não existem** — um path com paint de stroke é **recusado**, não
preenchido, porque preencher a região que o contorno encerra desenharia um
bloco sólido onde se pediu uma borda; retângulos arredondados via `drawRRect`
preenchem a caixa (via `Path` eles saem corretos); `saveLayer` é um clip até
existir buffer offscreen para compor; texto **lança**. O `probe()` do backend
diz isso em voz alta.

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

## O que ainda não existe

Nenhum backend de janela real e nenhum widget. O que existe é a base sobre a
qual essas coisas são escritas, com as invariantes travadas por teste e um
caminho completo de restrições a pixels para testá-las contra.

O que falta para virar framework de fato, em ordem: uma camada declarativa de
widgets/elements acima do layout (reconciliação e estado — a segunda das quatro
árvores da seção 8.1), e portar o backend macOS de `poc/poc_20` para `lib/`
atrás dos contratos de plataforma.

O caminho macOS tem POCs validados e uma decisão de arquitetura registrada
([ADR 0001](../adr/0001-worker-process-com-iosurface-no-macos.md)) mas ainda
não foi portado para `lib/` — os três backends vivem em
`poc/poc_20_macos_three_backends`.
