# Estratégia D — rasterizador vetorial em compute

Estado em 26 de agosto de 2026, revisto com o estágio de binning de segmentos.
Complementa `doc/architecture/ACELERACAO_GPU_VETORIAL.md`, que descreve as
quatro estratégias, e `doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`, que
mediu o hardware.

O POC-23 nomeia o que faltava para D: *"flatten, binning, cobertura, ordenação e
composição na GPU"*. Cobertura e composição já rodavam no device desde
`d3d12_compute_tile_shader.dart`. Este documento cobre o flatten, o binning
grosso com a sua ordenação, e o binning de segmentos com os backdrops — que é o
estágio que faltava para que a comparação com a CPU seja como-por-como.

## Onde cada estágio roda hoje

| Estágio | Onde roda | Paridade provada contra |
|---|---|---|
| **Flatten** (curvas → segmentos) | **GPU** | `ComputeFlattenReference` — contagens e offsets exatos, coordenadas a 7,6e-6 px, cobertura idêntica à do `Path.flatten` |
| **Binning grosso** (draws → tiles) | **GPU** | `ComputeTileScene.build` — `bins`, `references` e `commands` byte a byte |
| **Ordenação** (draws dentro do tile) | **GPU** | idem — a ordem crescente por draw é parte da comparação acima |
| **Binning de segmentos + backdrops** | **GPU** | `ComputeTileScene.build` — `referenceSegments`, `tileSegments` e `referenceBackdrops` byte a byte |
| **Cobertura** | GPU | `ComputeTileCpuReference` (trabalho anterior) |
| **Composição** | GPU | `d3d12_compute_composite_parity_test.dart` (trabalho anterior) |
| **Flatten + binning grosso + binning de segmentos numa submissão só** | **GPU** | `d3d12_compute_raster_pipeline_test.dart` — byte a byte contra os executores não encadeados e contra `ComputeTileScene.build` |

## Por que Direct3D 12 e não Vulkan

O POC-23 recomenda "começar no Vulkan ou D3D12". A escolha foi D3D12, por três
razões concretas deste repositório:

1. **Vulkan aqui não tem caminho para compute.** `vulkan_spirv.dart` monta
   SPIR-V à mão e diz, no seu próprio comentário de biblioteca, que os shaders
   são "quarenta instruções de aritmética em linha reta **sem nenhum controle de
   fluxo**", e que o dia em que for preciso um laço é o dia de reconsiderar o
   `SpirvBuilder`. Um flatten precisa de laços; um scan precisa de laços,
   `groupshared` e barreiras. Seria preciso construir metade de um compilador
   antes da primeira linha de rasterizador.
2. **D3D12 já tem o compilador.** `d3dcompiler_47.dll` acompanha o Windows, e
   `d3d12_library.dart` já o carrega. Os kernels são HLSL legível e recompilado
   a cada execução, sem blob versionado.
3. **Já havia seam e oráculo.** `ComputeTileD3d12Driver` estabeleceu o formato de
   adaptador estreito e falsificável, e `ComputeTilePlan` é o oráculo exato do
   estágio de binning — não foi preciso inventar uma referência para ele.

Vulkan continua sendo o alvo portátil. O que este trabalho deixa pronto para
essa porta é o lado neutro: `compute_curve_scene.dart`,
`compute_flatten_reference.dart`, `compute_scan.dart` e os dois executores não
nomeiam Direct3D em lugar nenhum.

## Flatten

`compute_curve_scene.dart` fixa a especificação e a implementa duas vezes: em
Dart (`ComputeFlattenReference`) e em HLSL
(`d3d12_compute_flatten_shader.dart`).

- **Contagem de segmentos idêntica à do `Path.flattenTo`**, para que um path
  achatado na GPU seja o mesmo path, e não um parecido.
- **Avaliação direta em `t = j/n`** em vez de diferenças progressivas. É a forma
  paralela — a thread do segmento `j` nunca viu o `j-1` — e é *mais* exata, o que
  `compute_flatten_reference_test.dart` mede em vez de afirmar.
- **Segmentos de comprimento zero são mantidos.** Compactar o fluxo na GPU é um
  scan a mais, e um segmento degenerado não contribui para o winding de amostra
  nenhuma: `y0 <= y && y1 > y` é falso para todo `y` quando `y0 == y1`. O teste
  compara as duas coberturas em vez de deixar o argumento no papel.

A referência arredonda para float32 **depois de cada operação**, e isso não é
purismo: a primeira saída do estágio é uma *contagem inteira*, e uma curva
contada como 9 de um lado e 10 do outro não desloca um pixel — desloca todos os
segmentos seguintes do buffer. `segmentCountMargin` reporta a que distância cada
curva está da fronteira do `ceil`, e o teste sem GPU exige margem > 1e-4 nas
cenas que a paridade usa, para que a comparação exata seja um teste justo e não
uma moeda.

### Paridade medida (Intel UHD, feature level 12_1)

| cena | curvas | segmentos | pior desvio de coordenada | pixels diferentes do `Path.flatten` |
|---|---:|---:|---:|---:|
| retângulo | 4 | 4 | 0 | 0 |
| painel arredondado | 8 | 24 | 0 | 0 |
| elipse | 4 | 28 | 7,63e-6 px | 0 |
| curva em S | 4 | 39 | 7,63e-6 px | 0 |
| arco quadrático rotacionado | 2 | 16 | 3,81e-6 px | 0 |
| painel ampliado 4× | 8 | 24 | 0 | 0 |

Contagens e offsets bateram **exatamente** em todas. O desvio máximo de
coordenada, 7,63e-6 px, é `2^-17` — um ulp de float32 na magnitude dessas cenas,
e o resto da contração `a*b+c` que nenhuma flag de HLSL proíbe. A superfície
rasterizada é **idêntica**: nenhum pixel difere.

## Binning grosso e ordenação

`d3d12_compute_binning_shader.dart` produz `bins`, `references` e `commands` a
partir do mesmo `bounds` que `ComputeTilePlan` carrega.

A dificuldade real é a **ordem**. Contar quantos draws tocam um tile é livre de
ordem — `InterlockedAdd` soma igual em qualquer sequência. Colocá-los não é: o
consumidor precisa das referências de cada tile em ordem crescente de draw, e um
cursor atômico entrega slots na ordem em que as threads terminaram. Três saídas
foram consideradas e a escolhida foi **scatter atômico seguido de rank sort por
tile**: os índices de draw dentro de um tile são distintos, então o rank de cada
elemento é a contagem de menores, todo rank é único, e o resultado é a corrida
ordenada independentemente do que os atômicos produziram. O custo é `O(n²)` no
comprimento da corrida — o número de draws que se sobrepõem num tile.

O teste `a repeated scene is deterministic` existe exatamente para isso: o
buffer intermediário genuinamente difere entre execuções, e a asserção é que a
saída não.

Duas somas de prefixo são necessárias — uma sobre contagens por tile, para o
índice CSR, e outra sobre *ocupação*, para compactar os comandos. Os mesmos três
kernels são despachados duas vezes sobre o mesmo trio de buffers.

### Paridade medida

Sete cenas, comparação **exata, sem tolerância**: retângulo em grade par, grade
que não divide, dois draws sobrepostos, draw inteiramente fora da superfície
(que o planejador da CPU descarta sem deslocar os índices seguintes), bounds
fracionários exatamente sobre a borda do tile, tile size que não é potência de
dois, e vinte draws pequenos com corridas de três ou mais. Todas passaram.

Não há tolerância porque não há arredondamento: `floorTile`/`ceilTile` corrigem
a divisão em float32 com duas comparações exatas, de modo que os dois lados
calculam o piso matemático verdadeiro em vez de concordarem por sorte.

## Binning de segmentos e backdrops

`d3d12_compute_segment_shader.dart` produz as três matrizes por referência que
faltavam: `referenceSegments` (o índice CSR), `tileSegments` (os índices de
segmento, em ordem crescente dentro de uma referência) e `referenceBackdrops`
(`winding, parity`). A especificação é `ComputeTileScene._binSegments`, e o
shader a transcreve em vez de reargumentá-la — a partição em três casos
(segmento à esquerda do tile, à direita e cobrindo a altura inteira, e o resto)
já está provada exaustiva e exata lá.

Quatro decisões são deste estágio e não vieram de lá:

**A ordem dos laços é a da CPU, transposta.** A CPU percorre draw, linha de
tiles, segmento. Aqui a *thread* é um par (draw, segmento) e o laço de linhas
fica dentro, porque os segmentos de um draw são o único eixo com paralelismo
suficiente numa cena de algumas centenas de draws. Os mesmos trios
(draw, segmento, linha) são visitados; só a ordem muda, e nada aqui depende de
ordem.

**Achar o índice de referência sem construir um segundo índice.** A CPU sabe o
índice da referência (tile, draw) porque anda em ordem de draw com um cursor por
tile. Uma thread não tem cursor. O que ela tem é a saída do estágio grosso:
`uReferences` guarda a corrida de cada tile **ordenada por draw**, que é
exatamente a propriedade que `csSortReferences` existe para garantir. Então o
índice é `bins[tile].x` mais a posição de `draw` na corrida, achada por busca
binária em `log2` do comprimento da corrida. A alternativa — um mapa
(tile, draw) → referência — custa `tiles * draws` entradas.

**O backdrop é um array de diferenças, e as referências são as suas células.**
A CPU acumula, por linha de tiles, um array de diferenças de `columns + 1` e o
soma por prefixo uma vez. Uma thread não pode guardar esse array, mas não
precisa: **cada referência pertence a exatamente um par (draw, linha)**, então o
array de diferenças *é* o buffer de backdrops, indexado por referência.
`csSegmentCounts` soma `+delta` na referência da primeira coluna e `-delta` na
coluna onde a corrida para, com `InterlockedAdd`; `csBackdropScan` roda uma
thread por (draw, linha) que soma por prefixo, **no lugar**, as referências
daquela linha. Um buffer, sem reset, e a mesma aritmética.

**O rank sort é uma thread por referência, não um grupo.** O estágio grosso
ordena a corrida de *draws* de um tile com um grupo, e há alguns milhares de
tiles. Aqui a unidade é uma referência (tile, draw), e há muito mais delas:
26 561 na cena de 256 draws, com 63 003 segmentos entre elas — **2,37 segmentos
por referência**. Um grupo de 256 threads despachado para ordenar dois elementos
é 254 threads que leem a guarda e saem. As duas formas estão compiladas e o
teste mede as duas na mesma execução:

| cena | refs | segs de tile | segs/ref | thread por ref | grupo por ref |
|---|---:|---:|---:|---:|---:|
| 8 draws, 256×256 | 81 | 388 | 4,79 | **336 µs** | 354 µs |
| 64 draws, 512×512 | 1 967 | 6 430 | 3,27 | **466 µs** | 490 µs |
| 256 draws, 1024×1024 | 26 561 | 63 003 | 2,37 | **1 774 µs** | 2 069 µs |

O trabalho total é o mesmo — continua sendo a soma de `n²` sobre as corridas —
só está distribuído de outro jeito, e as duas formas produzem a ordem da CPU
byte a byte (o teste verifica antes de cronometrar; uma resposta errada mais
rápida não é resultado).

### O primeiro estágio que consome outro, e o que isso custou descobrir

Este é o primeiro par produtor/consumidor real do pipeline: o estágio de
segmentos lê `uBins` e `uReferences`, que o estágio grosso escreveu, na mesma
lista de comandos e sem readback no meio. `D3d12ComputeAlias` é como — o
consumidor liga o buffer do produtor **por endereço**, e os dois slots são
`RWStructuredBuffer` dos dois lados de propósito: um root SRV exige
`NON_PIXEL_SHADER_RESOURCE`, e esses buffers vivem em `UNORDERED_ACCESS` da
criação até a liberação. Ler como UAV não precisa de transição nenhuma, e a
barreira UAV que a cadeia já grava entre cada despacho é exatamente a ordenação
de que uma leitura aliasada precisa.

O que isso trouxe junto foi um modo de falha novo, e ele **removeu o device**
antes de ser entendido. Quando o estágio grosso estoura o seu orçamento de
referências, os seus `uBins` continuam carregando as contagens exatas — é isso
que faz o *seu* retry funcionar — então `bins[tile].x + bins[tile].y` pode
apontar para além do fim de um buffer de referências que só tinha o orçamento. E
**todo buffer aqui é um root descriptor, e um root descriptor não carrega
tamanho**: não existe a checagem de limites que descartaria a escrita numa
descriptor table, e um índice fora de faixa é um acesso de memória de verdade.
Por isso `referenceOf` limita a busca a `uReferenceSlots` e devolve
`uReferenceSlots` quando a corrida do tile começa depois do fim, e todo chamador
descarta uma referência que não seja estritamente menor. A saída dessa submissão
é lixo, o que está certo: o pipeline está prestes a notar o estouro do estágio
grosso, crescer os dois orçamentos e ressubmeter. O que a guarda compra é que ele
sobreviva para fazer isso.

### `uReferenceSlots` é um orçamento, não uma contagem

Todo kernel aqui é indexado por referência, e o número de referências é
resultado do estágio *anterior*. Uma submissão encadeada não pode lê-lo — é
justamente a cerca que se está removendo. Então o despacho cobre um número de
**slots** que o chamador escolheu, que é o mesmo orçamento de bump allocator com
que o estágio grosso rodou. Slots além da contagem real foram zerados,
contribuem zero para o scan, ordenam uma corrida vazia e não são nomeados por
nenhuma entrada de `uBins` — as saídas são idênticas às de um despacho
dimensionado exatamente, e a forma não encadeada simplesmente passa a contagem
exata como orçamento.

### Paridade medida

Sete cenas, comparação **exata, sem tolerância**, nas três matrizes ao mesmo
tempo: retângulo em grade par; uma forma larga em que colunas inteiras de tiles
são só backdrop; uma elipse, cujos segmentos cobrem linhas de tiles pela metade;
dois draws sobrepostos que compartilham referências, um deles even-odd;
geometria recortada de modo que os segmentos correm para fora da superfície (que
é onde `low` fica negativo e `high` passa da grade); um tile size que não é
potência de dois; e vinte draws pequenos. Todas passaram.

Não há tolerância porque não há arredondamento. Tudo o que o estágio produz é
inteiro: uma contagem é uma soma de uns, um offset é uma soma de prefixo, uma
referência de segmento é um índice, e um backdrop é uma soma de `+1` e `-1`. O
único passo em ponto flutuante é decidir *quais* tiles um segmento toca, e essa
decisão é o mesmo par `floorTile`/`ceilTile` corrigido que o estágio grosso usa —
com a diferença de que aqui o valor pode ser negativo, porque um path recortado
guarda a geometria que caiu fora da superfície.

O teste também verifica as *cenas*, sem GPU: se nenhuma tivesse backdrop
diferente de zero, ou nenhuma referência tivesse mais de um segmento, a
comparação exata estaria comparando zeros.

Uma cena a mais é verificada encadeada, contra o planejador da CPU **e** contra
o executor não encadeado: as três cenas do benchmark, incluindo a de 256 draws
em 1024×1024, com 26 561 referências e 63 003 segmentos de tile.

## O custo honesto, como estava medido antes deste trabalho

**O diagnóstico da frente anterior era que o gargalo não é a GPU: é a leitura de
volta.** Cada passe fecha sua própria lista de comandos e espera uma cerca,
porque é assim que um oráculo lê o resultado. Medido nesta máquina:

| draws | superfície | tiles | referências | `ComputeTileScene.build()` na CPU | passe de binning na GPU |
|---:|---|---:|---:|---:|---:|
| 8 | 256×256 | 256 | 135 | 143 µs | 831 µs |
| 64 | 512×512 | 1 024 | 1 115 | 498 µs | 942 µs |
| 256 | 1024×1024 | 4 096 | 4 456 | 419 µs | 1 053 µs |

A coluna da CPU faz **estritamente mais** trabalho — inclui o binning de
segmentos e os backdrops, que a GPU ainda não faz — e mesmo assim ganha, porque
o passe da GPU tem um piso de ~0,8 ms de espera de cerca e readback que quase
não varia com o tamanho da cena. O mesmo vale para o flatten: 813 µs de passe
contra 76 µs de `Path.flatten` no painel arredondado.

## O piso de submissão, medido e desmontado

A versão anterior deste documento registrou o achado honesto de que nenhum dos
dois estágios era ganho, porque cada passe fecha sua própria lista de comandos e
espera uma cerca — um piso de ~0,8 ms que quase não variava com a cena, contra
0,14–0,5 ms do planejador de CPU fazendo *estritamente mais* trabalho. O item 1
da lista era encadear os estágios numa lista só, e a pergunta era se o custo era
da **cerca** ou da **submissão**, porque otimizar o errado dos dois é otimizar
nada.

`d3d12_compute_raster_pipeline_test.dart` mede as três formas na mesma execução,
na mesma máquina e no mesmo estado térmico. O número reportado é o **mínimo** de
quatro lotes de oito iterações, e não a média: a primeira versão do arquivo
reportava média e a mesma linha se moveu por um fator de sete entre duas
execuções com um minuto de diferença — uma GPU integrada divide orçamento de
energia com os núcleos, e esta máquina tem outro trabalho em cima dela. Um
mínimo não pode ficar *abaixo* do custo real e a interferência só pode piorar um
lote, então comparar mínimos compara as formas e não quem foi escalonado.

| cena | draws | tiles | refs | segs | `build()` na CPU | 2 passes sem encadear | encadeado + readback | encadeado, sem readback |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 draws, 256×256 | 8 | 256 | 81 | 160 | 150 µs | 838 µs | 604 µs | **236 µs** |
| 64 draws, 512×512 | 64 | 1 024 | 1 967 | 1 536 | 694 µs | 859 µs | 603 µs | **260 µs** |
| 256 draws, 1024×1024 | 256 | 4 096 | 26 561 | 8 192 | 3 640 µs | 1 179 µs | 1 166 µs | **546 µs** |

As colunas são a mesma cena em três formas: dois passes independentes (duas
listas, duas cercas, dois `Map`), um passe encadeado que ainda lê tudo de volta
(uma lista, uma cerca, um `Map`), e um passe encadeado que não lê nada e é
fechado por um único `finish()` ao fim da corrida.

**A decomposição, na cena de 8 draws:** tirar a segunda submissão e a segunda
cerca custou 838 → 604 µs; tirar a cerca e o `Map` que sobraram custou
604 → 236 µs. Ou seja, **a cerca e a leitura de volta são a metade maior do
piso**, mas uma submissão nua ainda custa ~236 µs — mais do que os 150 µs que o
planejador de CPU leva na mesma cena. Encadear derrubou o piso; não o eliminou.

## O que sobrou de uma submissão nua: o zero-fill

O que resta depois que a cerca sai não é o custo de gravar dezessete despachos.
O segundo experimento do mesmo arquivo varia a única coisa que muda *bytes* sem
mudar *trabalho*: os orçamentos do bump allocator. Todo tamanho de despacho
deriva de contagens de curvas, draws e tiles, e nunca de um orçamento — então
quadruplicar os orçamentos grava exatamente os mesmos despachos sobre quatro
vezes a memória.

| cena | zero-fill | 1× buffers | 4× buffers | por byte |
|---|---|---:|---:|---:|
| 8 draws, 256×256 | upload | 282 µs | 465 µs | 651 µs/MB |
| 8 draws, 256×256 | **device** | 205 µs | 232 µs | **95 µs/MB** |
| 64 draws, 512×512 | upload | 317 µs | 503 µs | 662 µs/MB |
| 64 draws, 512×512 | **device** | 234 µs | 276 µs | **150 µs/MB** |
| 256 draws, 1024×1024 | upload | 822 µs | 1 584 µs | 775 µs/MB |
| 256 draws, 1024×1024 | **device** | 527 µs | 571 µs | **45 µs/MB** |

`upload` é a forma antiga: cada execução reservava memória de upload e a CPU a
zerava com `fillRange`. Os ~700 µs/MB são a velocidade de um memset em memória
*write-combined*, cerca de 1 GB/s, e nada além disso. Na cena maior isso eram
dois terços de tudo que uma submissão custava.

`device` é a forma atual: `D3d12ComputePass` mantém **um** buffer de zeros na
default heap, preenchido uma vez quando cresce, e toda execução copia dele. A
CPU não toca em nada por execução e a cópia é device-local. O custo por byte cai
de ~700 para ~45–150 µs/MB — dentro do ruído da medição — e a cena de 1024×1024
cai de 822 para 527 µs por submissão nos orçamentos reais.

A forma antiga continua selecionável por `D3d12ComputePass.deviceZeroFill`, e
existe exatamente para que essa tabela possa ser produzida numa execução só, em
vez de exigir que se acredite num comentário.

## Onde a estratégia D está agora, com a CPU fazendo o mesmo trabalho

Esta é a razão de o item 2 ter vindo antes do 3. Todas as tabelas acima foram
medidas com uma coluna de CPU fazendo **estritamente mais** trabalho do que a de
GPU: `ComputeTileScene.build` produz as listas de segmentos por tile e os
backdrops, e nada no device os produzia. Agora produz, então o mesmo benchmark
roda duas vezes na mesma execução — sem o estágio de segmentos e com ele — e a
diferença entre as duas tabelas é o preço do trabalho que a GPU não estava sendo
cobrada.

**Antes** — dois estágios na GPU (flatten + binning grosso), a coluna de CPU
fazendo mais:

| cena | draws | tiles | refs | segs | `build()` na CPU | 2 passes sem encadear | encadeado + readback | encadeado, sem readback |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 draws, 256×256 | 8 | 256 | 81 | 160 | **55 µs** | 492 µs | 396 µs | 161 µs |
| 64 draws, 512×512 | 64 | 1 024 | 1 967 | 1 536 | 551 µs | 544 µs | 436 µs | **203 µs** |
| 256 draws, 1024×1024 | 256 | 4 096 | 26 561 | 8 192 | 2 854 µs | 998 µs | 902 µs | **518 µs** |

**Depois** — três estágios na GPU, as duas colunas computando a mesma função:

| cena | draws | tiles | refs | segs de tile | `build()` na CPU | 3 passes sem encadear | encadeado + readback | encadeado, sem readback |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 draws, 256×256 | 8 | 256 | 81 | 388 | **38 µs** | 798 µs | 654 µs | 312 µs |
| 64 draws, 512×512 | 64 | 1 024 | 1 967 | 6 430 | **390 µs** | 1 070 µs | 802 µs | 480 µs |
| 256 draws, 1024×1024 | 256 | 4 096 | 26 561 | 63 003 | 3 290 µs | 3 996 µs | 3 121 µs | **1 764 µs** |

**O número, dito como ele é.** O ganho de 6,7× que a versão anterior deste
documento registrou era, em boa parte, o handicap. Com as duas colunas fazendo o
mesmo trabalho, a cena de 256 draws em 1024×1024 fica em **1 764 µs contra
3 290 µs** — a GPU ainda ganha, por **cerca de 1,9×** em vez de 6,7×. E nas duas
cenas menores a CPU **ganha**: 38 µs contra 312 µs, e 390 µs contra 480 µs.

Três ressalvas, todas na direção conservadora contra a GPU:

1. **A coluna da GPU continua fazendo mais, não menos.** Ela também acha as
   curvas, e `build()` não — `appendPath` já tinha feito isso antes do relógio
   começar. Na cena grande o flatten + binning grosso sozinhos custam 518 µs, de
   modo que binning grosso + segmentos na GPU custa **no máximo** 1 764 µs
   contra os 3 290 µs que a CPU leva para o mesmo par.
2. **A coluna da CPU é a ruidosa.** `build()` aloca nove arrays tipados por
   chamada e o GC cai onde cai: a mesma linha variou entre 2 734 µs e 5 412 µs
   entre execuções, enquanto as colunas de GPU ficaram dentro de ~10 %. As
   razões acima são de *uma* execução, como todas as outras deste documento.
3. **O estágio de segmentos é o mais caro dos três, e por larga margem.** Ele
   sozinho responde por cerca de 1,25 ms dos 1,76 ms da cena grande.

O que a tabela de antes provava era que a *forma* tinha deixado de ser o
gargalo. O que a tabela de depois prova é que, feita a comparação como-por-como,
D fica à frente apenas na cena grande e apenas por um fator pequeno. Isso é o
resultado, e é ele que diz onde vale otimizar em seguida.

## O que ainda falta

1. ~~**Manter os buffers no device.**~~ **Feito para flatten + binning.**
   `ComputeRasterPipeline` é a segunda entrada que os comentários dos dois
   executores prometiam: `run()` grava as duas cadeias numa lista só e espera uma
   vez; `submit()` não espera nada e `finish()` é a cerca única no fim.
   `d3d12_compute_raster_pipeline_test.dart` compara a saída encadeada byte a
   byte com a dos executores não encadeados **e** com `ComputeTileScene.build`,
   sem tolerância, nas três cenas.

   **A cobertura não entrou na cadeia, e a razão não é de agenda.**
   `D3d12ComputeTileDriver` lê `scene.segments` e `scene.referenceBackdrops` —
   as listas de segmentos por tile que `ComputeTileScene._binSegments` produz na
   CPU. Enquanto o item 2 não existir, encadear a cobertura significaria
   encadear um estágio cuja entrada precisa voltar para a CPU no meio, o que é a
   cerca que se estava tentando remover. Além disso aquele driver usa descriptor
   heaps para a textura de saída, e `D3d12ComputePass` só declara root
   descriptors; portá-lo é trabalho real e não uma linha.

   Duas coisas que o encadeamento **não** pode fazer, declaradas por nome:
   `submit()` não pode crescer um orçamento, porque o total está no device até
   alguém esperar — quem usa `submit()` carrega o `ComputeRasterBudget` do frame
   anterior. E `D3d12ComputePass.reserve` roda para *todos* os passes antes da
   lista abrir, porque crescer um buffer espera idle e uma espera dentro de uma
   lista aberta se lê como se a própria lista estivesse sendo esperada.

2. ~~**Binning de segmentos por tile e backdrops na GPU.**~~ **Feito.**
   `d3d12_compute_segment_shader.dart`, `d3d12_compute_segment_executor.dart` e
   `d3d12_compute_segment_driver.dart`, encadeados como terceiro passe de
   `ComputeRasterPipeline`. Paridade exata contra `ComputeTileScene.build` nas
   três matrizes, encadeado e não encadeado, e a tabela de antes/depois acima.

   **A cobertura agora pode ser encadeada, e o motivo que a barrava caiu.**
   `D3d12ComputeTileDriver` lê `scene.segments` e `scene.referenceBackdrops`;
   os dois estão no device ao fim desta cadeia, e `D3d12ComputeAlias` é o
   mecanismo pelo qual o consumidor os lê sem cópia. O que sobra é o segundo
   motivo que a frente anterior declarou e que continua verdadeiro: aquele
   driver usa descriptor heaps para a textura de saída, e `D3d12ComputePass` só
   declara root descriptors. Portá-lo continua sendo trabalho real.

3. **`ExecuteIndirect`.** Inalterado, e agora com um segundo cliente. O emit do
   flatten despacha um grupo por curva porque a contagem de segmentos é um
   resultado da GPU; o estágio de segmentos despacha sobre `referenceSlots` em
   vez de sobre a contagem real de referências pela mesma razão, e paga o scan e
   o sort sobre os slots vazios. Um despacho indireto tornaria os dois exatos.

4. **O despacho esparso dos dois kernels mais caros.** `csSegmentCounts` e
   `csScatterSegments` cobrem um retângulo (draw, segmento) tão largo quanto o
   draw mais largo, com `numthreads(256)`. Na cena de 256 draws cada draw tem 32
   segmentos, ou seja **224 das 256 threads de cada grupo saem na primeira
   guarda**. É a maior ineficiência conhecida do estágio, é medida e não
   suposta, e as duas saídas — um grupo menor, ou uma soma de prefixo sobre as
   contagens de segmento por draw e uma busca por thread — são exatamente o
   trade que `D3d12ComputeStage.groupsY` documenta.

5. **O teto de 65 535 referências.** Todo kernel do estágio de segmentos é
   indexado por referência, e tanto o scan de dois níveis quanto o despacho de
   uma dimensão param aí. A cena de 256 draws em 1024×1024 usa 26 561; uma cena
   quatro vezes maior é recusada por nome
   (`referenceCountExceedsScan`), não truncada. Um terceiro nível de scan é a
   extensão.

Limites declarados e recusados por nome, não descobertos em runtime:

- 65 536 elementos por scan (dois níveis), 65 535 grupos por despacho — e o
  estágio de segmentos herda os dois sobre a contagem de *referências*, não de
  tiles;
- orçamento de segmentos, de referências e de segmentos por tile no estilo *bump
  allocator*: quem estoura é recontado e reexecutado, com o total exato — nunca
  truncado em silêncio. O terceiro pode custar uma **terceira** submissão, e
  isso é uma dependência e não uma dúvida: o estágio de segmentos lê as
  referências do estágio grosso, então um orçamento de referências estourado
  torna o total dele sem sentido, e só depois de crescer aquele é que este pode
  faltar por si.

## Arquivos

Lado neutro, em `lib/src/rendering/gpu/compute/`:

- `compute_curve_scene.dart` — encoding de curvas e a especificação do flatten;
- `compute_flatten_reference.dart` — o oráculo em Dart, em float32;
- `compute_scan.dart` — a soma de prefixo, em Dart e como gerador de HLSL;
- `d3d12_compute_flatten_shader.dart`, `d3d12_compute_flatten_executor.dart`;
- `d3d12_compute_binning_shader.dart`, `d3d12_compute_binning_executor.dart`;
- `d3d12_compute_segment_shader.dart`, `d3d12_compute_segment_executor.dart`;
- `compute_raster_pipeline.dart` — a entrada encadeada, o orçamento carregado
  entre frames e a política de retry que uma submissão sem leitura não pode ter.

Lado Direct3D 12, em `lib/src/backends/win32/d3d12/`:

- `d3d12_compute_pass.dart` — root signature, cadeia de kernels, barreira UAV,
  zero-fill device-local, readback seccionado e a espera de cerca;
  `D3d12ComputeChain`, que grava vários passes numa lista com uma cerca só; e
  `D3d12ComputeAlias`, que liga um slot read-write ao buffer de *outro* passe,
  que é como um consumidor lê um produtor sem cópia e sem cerca;
- `d3d12_compute_flatten_driver.dart`, `d3d12_compute_binning_driver.dart`,
  `d3d12_compute_segment_driver.dart` — cada um expõe seu passe, seus tamanhos
  de buffer e sua cadeia de kernels como funções (`D3d12FlattenPass`,
  `D3d12BinningPass`, `D3d12SegmentPass`), de modo que a forma encadeada e a não
  encadeada despacham literalmente a mesma coisa;
- `d3d12_compute_raster_driver.dart` — os três passes e a cadeia, juntos.

Testes, em `test/rendering/gpu/compute/` (89 no total; os quatro arquivos sem
GPU rodam em qualquer runner):

- `compute_scan_test.dart`, `compute_flatten_reference_test.dart`,
  `compute_flatten_executor_test.dart`, `compute_binning_executor_test.dart`;
- `d3d12_compute_flatten_parity_test.dart`,
  `d3d12_compute_binning_parity_test.dart`,
  `d3d12_compute_segment_parity_test.dart`;
- `d3d12_compute_raster_pipeline_test.dart` — paridade do encadeamento, incluindo
  a do estágio de segmentos contra o passe não encadeado e contra o planejador
  de CPU, e as quatro tabelas acima.
