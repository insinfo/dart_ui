# Relatório POC-23 — Intel UHD e estratégias 2D A/B/C/D

Data da medição: 22 de agosto de 2026.

## Resposta curta

A GPU desta máquina suporta as quatro abordagens propostas.

- **A — atlas analítico:** é a melhor base para UI comum e já é o caminho de
  produção mais completo do `dart_ui`.
- **B — tesselação na CPU:** o executor está integrado ao replay de produção e é
  alcançável de uma aplicação real por `RenderPolicy.routes`. O nicho que este
  relatório lhe atribuía — “SVG/ícone estático” — **não é dele**; ver a seção
  “Correção de 26 de agosto de 2026”.
- **C — stencil-then-cover:** funciona no hardware, está integrado e é
  alcançável pela mesma política. É uma rota estreita: só dentro de camadas com
  stencil e quatro amostras, e só para paths grandes e não cacheados. Ligá-la
  numa UI comum **custa 9% e não desenha nada** — ver a mesma seção.
- **D — compute:** a GPU e os runtimes nativos têm compute suficiente para um
  pipeline no estilo Vello. A POC executa um microkernel em tiles 16×16, mas o
  rasterizador vetorial completo ainda precisa de flatten, binning, cobertura,
  ordenação e composição na GPU.

## Hardware e APIs confirmados nesta máquina

| Item | Resultado observado | Consequência |
|---|---|---|
| GPU | Intel(R) UHD Graphics, PCI `8086:46B3` | iGPU Intel UHD de 12ª geração |
| Driver Windows | `32.0.101.7088` | versão efetivamente usada nos testes |
| Direct3D 11 | dispositivo Intel, feature level `11_1` | A, B e C; compute também existe na API |
| Direct3D 12 | dispositivo Intel, feature level `12_1` | A–D, sujeito à consulta das features opcionais |
| OpenGL | `4.6.0`, Intel, build `32.0.101.7088` | A–D; compute é core desde OpenGL 4.3 |
| Vulkan | dispositivo Intel integrado, API `1.4.323` | A–D e melhor candidato portátil para D |
| Compute OpenGL | 1.024 invocações por workgroup; 32 KiB compartilhados | tiles 8×8 ou 16×16 são adequados |
| Direct2D | disponível sobre o stack Direct3D do Windows | alternativa nativa para A/B, não arquitetura portátil |
| OpenCL / Level Zero | família suportada pela Intel, mas não havia `clinfo`/`ze_info` no teste | não usar como requisito do renderizador sem nova consulta runtime |
| WebGPU | viável por uma implementação sobre D3D12 | API de software/browser, não uma feature PCI independente |

Feature level, versão da API e Shader Model não são a mesma coisa. O teste
confirmou D3D12 feature level 12_1, mas não deve transformar isso em “Shader
Model 6.6” por inferência. A consulta correta é
`ID3D12Device::CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, ...)`.

A tabela genérica da Intel ainda lista Vulkan 1.3 para algumas linhas de UHD
de 12ª geração. Nesta máquina, o `vulkaninfo` do driver instalado retornou
Vulkan 1.4.323 e `conformanceVersion 1.4.0.0`; para decidir em runtime, essa
resposta local prevalece sobre uma tabela de família.

Fontes de referência:

- [Intel — especificações do Core i3-1215U](https://www.intel.com/content/www/us/en/products/sku/226269/intel-core-i31215u-processor-10m-cache-up-to-4-40-ghz-with-ipu/specifications.html)
- [Intel — APIs suportadas pelas famílias de gráficos](https://www.intel.com/content/www/us/en/support/articles/000005524/graphics.html)
- [Microsoft — feature levels do Direct3D](https://learn.microsoft.com/en-us/windows/win32/direct3d12/hardware-feature-levels)
- [Microsoft — consulta de capacidades D3D12](https://learn.microsoft.com/en-us/windows/win32/direct3d12/capability-querying)
- [Khronos — especificação OpenGL 4.3](https://registry.khronos.org/OpenGL/specs/gl/glspec43.core.pdf)

## Benchmark final do Windows

Comando:

```powershell
dart run poc/poc_23_gpu_2d_strategies/bin/main.dart `
  --samples=7 --gpu-frames=120
```

Cada valor é a mediana. Cada submissão GPU termina em `glFinish`, portanto os
tempos não são apenas custo de enfileiramento assíncrono.

### Preparação na CPU

Carga: 128 paths curvos.

| Operação | Tempo por path/operação |
|---|---:|
| A: scanline e escrita R8, cache frio | 10,898 µs |
| A: lookup retido no atlas | 0,286 µs |
| B: flatten e ear clipping, cache frio | 37,063 µs |
| B: lookup da malha retida | 0,142 µs |
| C: flatten e plano clear/accumulate/cover | 11,992 µs |

### Execução no OpenGL 4.6 da Intel

Target 1.024×1.024; um `glFinish` por quadro.

| Abordagem | Carga medida | Tempo por quadro |
|---|---|---:|
| A | 1.024 retângulos analíticos em um batch/draw | 0,835 ms |
| B | malha indexada retida de 128 paths | 0,440 ms |
| C | stencil-then-cover de 128 paths | 4,100 ms |
| D | microkernel compute RGBA8 em tiles 16×16 | 0,646 ms |

## Como interpretar sem criar uma comparação falsa

Essas quatro linhas não executam a mesma quantidade de trabalho visual:

- A mede o caso comum de UI: 1.024 caixas com cobertura analítica. O custo de
  rasterizar paths no atlas aparece separadamente na tabela CPU.
- B mede 128 paths já tessellados e residentes. Não inclui feathering/MSAA e,
  portanto, ainda não entrega antialiasing equivalente ao atlas.
- C resolve os 128 paths, mas executa três comandos por draw e foi medido sem
  MSAA porque o target é single-sample. O custo elevado é coerente com a
  largura de banda e a multiplicidade de passes desta abordagem.
- D apenas escreve uma imagem por compute. É prova de execução e um limite
  inferior; não inclui o trabalho vetorial que faria o resultado comparável a
  Vello.

Por isso, “B foi 1,9× mais rápido que A” não é uma conclusão válida sobre o
renderizador completo: B desenhou menos primitivas, com geometria retida e sem
AA equivalente. A conclusão válida é que manter malhas estáticas na GPU é
barato nesta Intel e merece um executor de produção.

## Arquitetura recomendada para esta GPU

1. **A como padrão:** retângulos analíticos, glifos e masks cacheadas atendem à
   maioria da UI com qualidade previsível.
2. **B e C como rotas declaradas, não como padrão:** ver a seção “Correção de
   26 de agosto de 2026”, que substitui as recomendações originais destes dois
   itens. O que estava escrito aqui — B para “SVG/ícone estático”, C como
   “fallback especializado” — foi medido depois da integração e **não
   acontece**.
3. **D como trilha moderna:** começar no Vulkan ou D3D12, com buffers de cena,
   flatten/binning/fine raster e composição em tiles. OpenGL compute serve à
   POC, mas Vulkan/D3D12 oferecem melhor modelo explícito de sincronização e
   recursos para o backend definitivo.

O seletor deve escolher por workload, não apenas por API disponível: frequência
de deformação, complexidade, sobreposição, estabilidade do cache, fill rule e
custo de upload determinam a abordagem vencedora.

## Correção de 26 de agosto de 2026 — o que B e C fazem de verdade

Esta seção corrige o item 2 e o item 3 da lista acima. As recomendações
originais foram escritas a partir dos microbenchmarks da POC, antes de B e C
existirem dentro do `GpuPathStrategySelector`. Medidas feitas depois da
integração mostram que o nicho atribuído a B é tomado por outras rotas, e que o
de C é bem mais estreito do que o texto sugeria.

### Por que B nunca vê o “SVG/ícone estático”

Duas travas do seletor, ambas anteriores ao ramo de tesselação em
`gpu_path_strategy.dart`:

- **as sparse strips são consultadas antes**, e são analiticamente exatas.
  `GlVectorReplay.capabilities` só declara `sparseStrips` para draws
  antialiased, e o seletor promove sempre que
  `cruzamentos × 50 < bytes da máscara densa`. Ou seja: todo path antialiased
  cujos cruzamentos de tile custem menos que a área já foi decidido antes de B
  ser perguntado;
- **a trava de repetição manda todo draw repetido para o atlas denso.**
  `GpuPathRepetitionTracker` existe justamente para impedir que uma rota
  promovida mate o cache que ela mesma esvaziou, e um ícone estático é, por
  definição, um draw que repete. É exatamente o caso “SVG/ícone estático” que a
  recomendação original entregava a B.

### Os nichos reais de B no OpenGL

Medidos com `RenderDiagnosticsMode.counters` — os contadores por estratégia,
que passaram a ser alimentados nesta frente — em janela real e em alvo
offscreen:

1. **fills aliased.** `sparseStrips` é recusada quando `paint.antiAlias` é
   falso, então B é a única rota promovida possível. Vale registrar o preço:
   as demais rotas deste renderizador ignoram a flag e desenham o fill com
   cobertura analítica, então promover um fill aliased para B **muda a
   figura** — 454 pixels e até 92 níveis numa cena de 512×512. É uma das
   razões de B não estar ligado por padrão;
2. **paths convexos densos em borda sobre camadas MSAA.** Quando as strips
   perdem a comparação de cruzamentos contra área, B é a rota seguinte, e ela
   só é correta para um draw antialiased num passe multiamostrado — que é
   precisamente a camada que o próprio C faz existir (`glLayerAttachmentsFor`,
   camadas a partir de 128 px). Isso significa que **este nicho de B depende de
   C estar ligado**, e a janela real confirma: com
   `tool/gl_vector_routes_smoke.dart --no-c`, B é construído e desenha **zero**
   draws em 120 quadros, porque sem C não existe camada multiamostrada e a
   superfície é single-sample;
3. **conteúdo declarado `ContentMotionHint.transforming`.**
   `GpuPathWorkload.withContentHint` grava, para esse hint, o par
   `geometryStable: true` + `denseMaskLikelyCacheable: false`: a geometria
   local repete e só a matriz anda, então a malha retida sobrevive a todo
   quadro enquanto a máscara densa, que é chaveada em espaço de dispositivo,
   erra em todos. É o único nicho em que B ganha *por declaração* e não por
   sobra.

### O nicho real de C, e o que ele custa quando não é usado

C só pode ser escolhido num passe que carregue stencil **e** pelo menos quatro
amostras. O framebuffer default de uma janela Win32 tem 8 bits de stencil e uma
amostra, então **C nunca é escolhido na superfície**: ele existe dentro de
camadas de 128 px ou mais, para paths grandes, não cacheados e não vencidos
pelas strips.

Medidas em Intel UHD Graphics, OpenGL 4.6, driver `32.0.101.7088`, alvo
offscreen 512×512, medianas de 41 quadros intercalados no mesmo processo e
sobre o mesmo dispositivo:

| cena | rotas construídas | tempo por quadro |
|---|---|---:|
| painel estático com `saveLayer` de 260×250 | nenhuma | **3,82 ms** |
| a mesma | C | 4,21 ms (**0,91×**) |
| path grande animando dentro de camada | nenhuma | **4,72 ms** |
| a mesma | C | 3,89 ms (**1,21×**) |
| a mesma | B e C | 3,75 ms (**1,33×**) |

A primeira linha é o custo de C simplesmente existir: os contadores registram
**zero** draws em `stencilThenCover` naquele quadro, e ele ainda assim perdeu
9% — porque toda camada a partir de 128 px passa a ser alocada com stencil e
quatro amostras, e o quadro paga alocação e resolve independentemente de
alguém usar.

Por isso **B e C não são ligados por padrão**. A ligação existe e é uma
declaração da aplicação: `RenderPolicy.routes`, lida por
`lib/src/backends/default_platform_resolver.dart` no momento em que o
dispositivo GL é aberto. `GpuRouteAvailability.measuredDefaults` é o padrão e
reproduz a figura e o tempo de quadro de todas as versões anteriores;
`GpuRouteAvailability.largeAnimatedPaths` constrói os dois executores.

### A mesma coisa em janela real

`tool/gl_vector_routes_smoke.dart` abre um `HWND` de 720×540 com contexto WGL,
`RenderingPolicy.gpuOnly`, `requestedPresentation: 'opengl'` e `onError`
instalado — sem `onError`, uma falha de pintura fecha a janela com exit 0 e
nenhum diagnóstico. Um path de 90 pontas com raio contínuo (nunca cacheável)
dentro de uma camada de 696×516, 120 quadros:

| configuração | draws promovidos | mediana do quadro |
|---|---|---:|
| `--baseline` | nenhum; 120 no atlas denso | 5,52 ms |
| `--no-b` (só C) | **72** em `stencilThenCover` | **4,34 ms** |
| B e C | **81** em `tessellatedMesh` | 5,29 ms |
| `--no-c` (só B) | **0** — ver o nicho 2 acima | 5,79 ms |

Os tempos de janela são ruidosos nesta máquina (a mesma configuração variou
entre 5,2 e 11,0 ms entre execuções) e servem para confirmar a ordem de
grandeza; os números de decisão são os da tabela offscreen intercalada. O que a
janela prova sem ruído é o que ela existe para provar: as rotas **executam**
fora de teste, com os contadores nomeando cada uma.

### B preempta C na carga que era de C

Com os dois construídos, o ramo de tesselação é alcançado antes de qualquer um
dos dois ramos de stencil, então a malha retida leva o draw que este relatório
atribuía ao cover pass: 49 draws em `tessellatedMesh` e **zero** em
`stencilThenCover` na cena de path grande animado. Não é defeito — B foi a mais
rápida das duas ali, 1,33× contra 1,21× —, mas é o oposto do que a recomendação
original descrevia, e está fixado por teste em
`test/rendering/gpu/gl_route_availability_test.dart`.

### O que continua verdadeiro do texto original

O agrupamento de clears e covers, apontado ali como “a próxima otimização
relevante”, foi feito: **4,100 ms → 1,157 ms por quadro** na cena da POC, com
identidade de pixel provada em GPU real. Esse número compara C com C, antes e
depois do agrupamento — não é uma comparação de C contra o atlas denso, e são
as tabelas acima que respondem essa segunda pergunta.

### Nenhuma das duas é idêntica ao atlas quando dispara

Vale dizer sem rodeio, porque o relatório original não dizia: as duas rotas
trocam a cobertura analítica que o resto do renderizador compartilha por uma
cobertura quantizada pelo hardware. Para C, contra o mesmo quadro desenhado sem
ela: **24 757 pixels de borda e até 55 níveis** com quatro amostras, interior
exato. `RenderQualityPreference.exact` e os kill switches de
`GpuStrategySwitches` continuam removendo qualquer uma das duas — e agora
removem alguma coisa, o que antes desta frente não era verdade.

## Artefatos

- `poc/poc_23_gpu_2d_strategies/bin/main.dart`: probe e benchmark executável.
- `poc/poc_23_gpu_2d_strategies/README.md`: comandos e definição de cada medida.
- `tool/gl_vector_routes_smoke.dart`: a prova em **janela real** — `HWND`,
  contexto WGL, `RenderingPolicy.gpuOnly`, `onError` instalado e os contadores
  por estratégia impressos ao final. `--baseline`, `--no-b` e `--no-c` cobrem
  as quatro combinações.
- `test/rendering/gpu/gl_route_availability_test.dart`: os mesmos fatos em
  alvo offscreen, incluindo o limite de desvio da borda do cover pass.

O código continua executável em Linux para conferir portabilidade, mas este
relatório e seus números de decisão referem-se ao Windows nativo, conforme o
foco definido para esta medição.
