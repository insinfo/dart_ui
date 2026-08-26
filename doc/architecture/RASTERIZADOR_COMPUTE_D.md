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
| **Binning de segmentos + backdrops** | CPU | — (não portado) |
| **Cobertura** | GPU | `ComputeTileCpuReference` (trabalho anterior) |
| **Composição** | GPU | `d3d12_compute_composite_parity_test.dart` (trabalho anterior) |

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

## O que ainda falta, e o custo honesto

**O gargalo hoje não é a GPU: é a leitura de volta.** Cada passe fecha sua
própria lista de comandos e espera uma cerca, porque é assim que um oráculo lê o
resultado. Medido nesta máquina:

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

**A conclusão legítima é que os dois estágios estão corretos e ainda não são um
ganho**, e não serão até que os buffers deixem de voltar para a CPU. As três
coisas que faltam, em ordem:

1. **Manter os buffers no device.** Uma segunda entrada nos executores que
   encadeia flatten → binning → cobertura numa lista só, sem cerca no meio. O
   seam foi desenhado para que isso seja um método ao lado do atual, e não uma
   reescrita dele.
2. **Binning de segmentos por tile e backdrops na GPU.** É o estágio sobre
   segmentos que corresponde a `ComputeTileScene._binSegments`, e é o que o
   `containsPoint` do shader de cobertura realmente lê. Enquanto ele estiver na
   CPU, o flatten da GPU tem de voltar para ser binado.
3. **`ExecuteIndirect`.** O emit do flatten despacha um grupo por curva porque a
   contagem de segmentos é um resultado da GPU e a CPU não pode dimensionar o
   despacho sem lê-lo. Isso desperdiça faixas em cenas de curvas curtas. Este
   backend ainda não liga `ExecuteIndirect`.

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
- `d3d12_compute_binning_shader.dart`, `d3d12_compute_binning_executor.dart`.

Lado Direct3D 12, em `lib/src/backends/win32/d3d12/`:

- `d3d12_compute_pass.dart` — root signature, cadeia de kernels, barreira UAV,
  zero-fill, readback seccionado e a espera de cerca, uma vez para os dois
  estágios;
- `d3d12_compute_flatten_driver.dart`, `d3d12_compute_binning_driver.dart`.

Testes, em `test/rendering/gpu/compute/` (80 no total; os quatro arquivos sem
GPU rodam em qualquer runner):

- `compute_scan_test.dart`, `compute_flatten_reference_test.dart`,
  `compute_flatten_executor_test.dart`, `compute_binning_executor_test.dart`;
- `d3d12_compute_flatten_parity_test.dart`,
  `d3d12_compute_binning_parity_test.dart`.
