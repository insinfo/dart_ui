# Estratégia D — rasterizador vetorial em compute

Estado em 26 de agosto de 2026. Complementa
`doc/architecture/ACELERACAO_GPU_VETORIAL.md`, que descreve as quatro
estratégias, e `doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`, que mediu
o hardware.

O POC-23 nomeia o que faltava para D: *"flatten, binning, cobertura, ordenação e
composição na GPU"*. Cobertura e composição já rodavam no device desde
`d3d12_compute_tile_shader.dart`. Este documento cobre as duas primeiras.

## Onde cada estágio roda hoje

| Estágio | Onde roda | Paridade provada contra |
|---|---|---|
| **Flatten** (curvas → segmentos) | **GPU** | `ComputeFlattenReference` — contagens e offsets exatos, coordenadas a 7,6e-6 px, cobertura idêntica à do `Path.flatten` |
| **Binning grosso** (draws → tiles) | **GPU** | `ComputeTileScene.build` — `bins`, `references` e `commands` byte a byte |
| **Ordenação** (draws dentro do tile) | **GPU** | idem — a ordem crescente por draw é parte da comparação acima |
| **Binning de segmentos + backdrops** | CPU | — (não portado; é o item 2 abaixo, e é o que falta para a comparação com a CPU ser como-por-como) |
| **Cobertura** | GPU | `ComputeTileCpuReference` (trabalho anterior) |
| **Composição** | GPU | `d3d12_compute_composite_parity_test.dart` (trabalho anterior) |
| **Flatten + binning numa submissão só** | **GPU** | `d3d12_compute_raster_pipeline_test.dart` — byte a byte contra os executores não encadeados e contra `ComputeTileScene.build` |

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

## Onde a estratégia D está agora

Na cena de 256 draws em 1024×1024, uma submissão encadeada sem readback custa
**546 µs contra 3 640 µs** do planejador de CPU. É a primeira configuração em
que D fica à frente, por cerca de 6,7×.

**E ainda não é um ganho como-por-como**, pela mesma razão que a versão anterior
deste documento dava: a coluna da CPU faz **estritamente mais** trabalho. Ela
inclui o binning de segmentos por tile e os backdrops, que a GPU continua não
fazendo. O que a tabela prova é que a *forma* deixou de ser o gargalo; o que
falta para a comparação ser justa é o item 2 abaixo.

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

2. **Binning de segmentos por tile e backdrops na GPU.** Inalterado, e agora é o
   item que decide tudo: é o estágio sobre segmentos que corresponde a
   `ComputeTileScene._binSegments`, é o que o shader de cobertura realmente lê, e
   é o que falta para que a coluna da CPU e a da GPU façam o mesmo trabalho.
   Enquanto ele estiver na CPU, o flatten da GPU tem de voltar para ser binado.

3. **`ExecuteIndirect`.** Inalterado. O emit do flatten despacha um grupo por
   curva porque a contagem de segmentos é um resultado da GPU e a CPU não pode
   dimensionar o despacho sem lê-lo. Este backend ainda não liga dispatch
   indireto.

Limites declarados e recusados por nome, não descobertos em runtime:

- 65 536 elementos por scan (dois níveis), 65 535 grupos por despacho;
- orçamento de segmentos e de referências no estilo *bump allocator*: quem
  estoura é recontado e reexecutado uma vez, com o total exato — nunca truncado
  em silêncio.

## Arquivos

Lado neutro, em `lib/src/rendering/gpu/compute/`:

- `compute_curve_scene.dart` — encoding de curvas e a especificação do flatten;
- `compute_flatten_reference.dart` — o oráculo em Dart, em float32;
- `compute_scan.dart` — a soma de prefixo, em Dart e como gerador de HLSL;
- `d3d12_compute_flatten_shader.dart`, `d3d12_compute_flatten_executor.dart`;
- `d3d12_compute_binning_shader.dart`, `d3d12_compute_binning_executor.dart`;
- `compute_raster_pipeline.dart` — a entrada encadeada, o orçamento carregado
  entre frames e a política de retry que uma submissão sem leitura não pode ter.

Lado Direct3D 12, em `lib/src/backends/win32/d3d12/`:

- `d3d12_compute_pass.dart` — root signature, cadeia de kernels, barreira UAV,
  zero-fill device-local, readback seccionado e a espera de cerca; e
  `D3d12ComputeChain`, que grava vários passes numa lista com uma cerca só;
- `d3d12_compute_flatten_driver.dart`, `d3d12_compute_binning_driver.dart` — cada
  um expõe seu passe, seus tamanhos de buffer e sua cadeia de kernels como
  funções (`D3d12FlattenPass`, `D3d12BinningPass`), de modo que a forma
  encadeada e a não encadeada despacham literalmente a mesma coisa;
- `d3d12_compute_raster_driver.dart` — os dois passes e a cadeia, juntos.

Testes, em `test/rendering/gpu/compute/` (89 no total; os quatro arquivos sem
GPU rodam em qualquer runner):

- `compute_scan_test.dart`, `compute_flatten_reference_test.dart`,
  `compute_flatten_executor_test.dart`, `compute_binning_executor_test.dart`;
- `d3d12_compute_flatten_parity_test.dart`,
  `d3d12_compute_binning_parity_test.dart`;
- `d3d12_compute_raster_pipeline_test.dart` — paridade do encadeamento e as duas
  tabelas acima.
