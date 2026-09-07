# Relatório POC-23 — Intel UHD e estratégias 2D A/B/C/D

Data da medição: 22 de agosto de 2026.

## Resposta curta

A GPU desta máquina suporta as quatro abordagens propostas.

- **A — atlas analítico:** é a melhor base para UI comum e já é o caminho de
  produção mais completo do `dart_ui`.
- **B — tesselação na CPU:** o executor está integrado ao replay de produção e é
  alcançável de uma aplicação real por `RenderPolicy.routes`. **Só no OpenGL
  até 06/09/2026**, quando o Direct3D 11 — o caminho padrão do Windows —
  finalmente ganhou o replay vetorial ordenado e os dois executores; ver a
  seção do fim. O nicho que este
  relatório lhe atribuía — “SVG/ícone estático” — **não é dele**; ver a seção
  “Correção de 26 de agosto de 2026”.
- **C — stencil-then-cover:** funciona no hardware, está integrado e é
  alcançável pela mesma política. É uma rota estreita: só dentro de camadas com
  stencil e quatro amostras, e só para paths grandes e não cacheados. Ligá-la
  numa UI comum **custa 9% e não desenha nada** — ver a mesma seção.
- **D — compute:** ~~a POC executa um microkernel em tiles 16×16, mas o
  rasterizador vetorial completo ainda precisa de flatten, binning, cobertura,
  ordenação e composição na GPU.~~ **Desatualizado nas duas direções, corrigido
  em 06/09/2026 — ver §"Estratégia D em 06/09/2026" no fim deste relatório. A
  junção flatten→segmentos, que aquela seção listava como lacuna, fechou em
  07/09/2026; só a composição encadeada continua de fora.**

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

## Estratégias B e C no Direct3D 11 — 06/09/2026

Até esta data B e C existiam **só no OpenGL**, e o OpenGL não é o caminho
padrão: o seletor escolhe `direct3d11` primeiro em toda máquina Windows comum.
Então as duas rotas que este relatório integrou eram inalcançáveis para
praticamente todo usuário real do framework.

**E o trabalho era maior do que "somar dois executores".** O Direct3D 11 não
tinha replay vetorial ordenado nenhum: sem fluxo de comandos, sem recorder, sem
telemetria de planejamento, sem `submitOrderedPaths`, sem alvos de camada com
MSAA e stencil, e o sink construído sem recorder. Foi o caminho de promoção
inteiro mais os dois executores.

**As diferenças com o OpenGL que uma transliteração literal erraria**, cada uma
um lugar onde o desenho sai errado e não falha:

- **não existe `glColorMask`.** A máscara de escrita de cor é campo do *blend
  state*, então limpar e acumular stencil exigem um segundo objeto de estado;
- **`ClearDepthStencilView` não aceita retângulo nem máscara de escrita**, e a
  capacidade `scissoredClear` não pode ser honrada pela chamada. A limpeza
  virou um **desenho**: um quad sobre os limites do grupo com `REPLACE` e o
  valor de limpeza como referência — um terceiro bloco de geometria que o
  executor do GL não tem;
- **o sentido de rotação inverte.** O GL usa `glFrontFace(GL_CW)` porque o
  espaço de janela dele é y-para-cima; no D3D11 a projeção inverte e o viewport
  inverte de volta, então área positiva é horária no alvo, que já é a face
  frontal padrão. Copiar o ajuste do GL inverteria todo preenchimento non-zero;
- **uma camada multiamostrada custa três recursos, não um**, porque um shader
  `Texture2D` não amostra textura MSAA: alvo de cor MSAA, `D24_UNORM_S8_UINT`
  com DSV, e uma textura de resolve de amostra única;
- **profundidade precisou ser desligada explicitamente.** Com um DSV ligado, o
  padrão do D3D11 é `DepthEnable = TRUE` contra um plano em que ninguém
  escreveu, o que rejeita tudo.

**Três bugs reais achados no caminho**, e os três são do tipo que não falha
onde nasce:

1. **estouro de buffer nativo.** O scratch de descritor tinha 256 bytes e
   `D3D11_BLEND_DESC` tem 264. Corrompia o heap do Dart e derrubava a VM
   minutos depois, dentro de iteração sem relação;
2. **`allocate<Float>(4)` são quatro *bytes*, não quatro floats.** Os fatores
   de blend escreviam 12 bytes além do fim;
3. **a rota C não desenhava nada no primeiro frame de cada dispositivo.** Ela
   escreve o constant buffer só no comando de cover, então no primeiro passe do
   processo o registrador de viewport tinha o que `CreateBuffer` tivesse
   deixado: a acumulação projetava fora da tela, o stencil ficava zero e o cover
   era mascarado. 74 508 pixels de um frame 512x512 não desenhavam, **uma vez**,
   e todo frame seguinte era exato.

**Paridade medida** contra a rota do atlas, 512x512, na Intel UHD: interiores
**exatos**, bit a bit, em todos os casos; todo desvio na franja, no máximo 55
níveis na estrela de 90 pontas. O OpenGL mediu 24 757 pixels e 55 níveis na
mesma cena — os dois portes independentes caem a **dois pixels** um do outro,
o que mostra que a franja é a cobertura de quatro amostras do hardware e não de
nenhum dos dois backends.

**E nenhum desenho de UI comum trocou de estratégia**, afirmado duas vezes: com
os dois executores construídos, zero desenhos escolhem B ou C numa cena de
painéis, chips e ícones, e o framebuffer contra o dispositivo de política
padrão difere em **0 pixels**. Com a política padrão o dispositivo não constrói
executor nenhum e não paga o plano MSAA, o `D24S8` nem o resolve.

**Não verificado:** não há `HWND` de verdade — `tool/gl_vector_routes_smoke.dart`
não tem equivalente Direct3D 11 —, os números de custo do POC-23 não foram
remedidos aqui, e o caminho de rebaixamento de contagem de amostras nunca rodou
porque este adaptador suporta quatro.

## Estratégia D em 06/09/2026 — mais pronta e mais inalcançável do que este relatório dizia

A frase original errava nos dois sentidos, e os dois importam.

**Está mais pronta.** Quatro dos cinco estágios rodam na GPU, e desde 06/09/2026
numa **única submissão**: flatten, binning grosso com ordenação, binning de
segmentos com backdrops, e agora **cobertura encadeada** — a cena binada não
volta mais para a CPU entre o binning e a cobertura. A paridade foi medida
nesta máquina, Intel UHD, feature level 12_1: **byte a byte, tolerância zero**,
contra a rota já provada, em seis cenas (retângulo, um tile de dezesseis, dois
desenhos sobrepostos, triângulo, elipse, gravata-borboleta even-odd). Mais
determinismo: a mesma cena duas vezes dá o mesmo buffer, e uma cena pequena
depois de uma grande não deixa tinta para trás.

Os quatro estágios continuavam, porém, **desligados entre o primeiro e o
terceiro**: o flatten escrevia segmentos que ninguém lia. Desde 07/09/2026 não —
ver §"A junção flatten→segmentos" abaixo, que é onde a paridade da rota
realmente encadeada está medida.

**Estava inalcançável, e passou a ser alcançável por opt-in em 06/09/2026.**
`GpuPathStrategy.computeTiles` depende de `experimentalComputeTilesEnabled`,
que depende de um executor, que depende de uma bandeira de construtor. Os
**dois** pontos de produção — `d3d12_backend.dart:81` e `:131` — chamavam
`D3d12RenderDevice.open` sem passá-la, e o **único** ponto de construção no
repositório inteiro era `D3d12Session.open(computeTiles: true)`, num arquivo de
teste. Um pipeline com paridade byte a byte que nenhum programa podia executar.

Entrou `GpuRouteAvailability.experimentalComputeTiles`, e
`D3d12RendererBackend.createDevice` lê a política pelo mesmo mecanismo que o
Direct3D 11 usa para B e C. **Valor próprio e não uma bandeira em
`largeAnimatedPaths`**, porque as duas coisas são de naturezas diferentes: B e
C são rotas terminadas com custo medido, esta é pesquisa, e dobrá-la na outra
habilitaria um pipeline incompleto para quem pediu só caminhos grandes
animados.

`test/rendering/gpu/compute/compute_route_reachability_test.dart` abre o
dispositivo pelo **caminho de produção** e pergunta se o executor voltou, que é
a única pergunta que uma aplicação consegue fazer — e é o teste que teria pego
a lacuna. O padrão continua não construindo nada, e o interruptor
`GpuStrategySwitches.computeTiles`, que existia e nunca podia agir sobre nada,
volta a tirá-lo.

Uma ressalva que continua valendo: mesmo com a rota pedida, o que se alcança é
a **metade planejada na CPU**.
`d3d12_vector_path_recorder.dart:386` monta o plano com `ComputeTileScene` **na
CPU**. Então o que a bandeira liga é a metade CPU-planejada, e a metade
GPU-encadeada — flatten, binning, segmentos, cobertura — não é tocada por
desenho nenhum, com ou sem bandeira.

**A lacuna que resta, nomeada:** a **composição encadeada**, que precisa da
porta para descriptor heaps.

A outra — a junção flatten→segmentos — foi fechada em 07/09/2026 e tem seção
própria abaixo.

**E uma correção de fato ao design.** `doc/architecture/RASTERIZADOR_COMPUTE_D.md`
dizia que encadear a cobertura estava bloqueado por descriptor heaps. Isso vale
só para o ponto de entrada de **textura**; o de buffer usa root descriptors, e
foi por ele que a cobertura encadeou.

**Sobre a tabela de custo**, que é onde um relatório de desempenho mente com
mais facilidade: o encadeamento fica à frente a partir de 16 desenhos e chega a
110 ms contra 41 ms em 64 desenhos, **mas essa razão não é atribuível ao
encadeamento**. Os dois lados leem de volta um `uint` por pixel por desenho — 64
MiB na maior linha — e zeram esse buffer por caminhos diferentes, um deles na
CPU a ~700 µs/MB. O que a tabela mostra honestamente é **onde fica o
cruzamento**, entre 4 e 16 desenhos, e não um ganho de 2,7×.

## A junção flatten→segmentos, fechada em 07/09/2026

Até aqui o flatten era um beco sem saída *dentro da própria cadeia*: escrevia
segmentos que ninguém lia, enquanto o estágio de segmentos recebia os segmentos
de um `ComputeTilePlan` e a tabela `firstSegment`/`segmentCount` construída na
CPU. Este relatório dizia, com razão, que ligar um no outro ingenuamente
amarraria uma numeração de segmentos a um índice construído para outra —
**arestas erradas, e não uma falha**. Nada lança; sai um desenho.

Eram dois problemas e não um, e foram resolvidos separadamente.

### 1. A aresta de fechamento de um contorno degenerado

Isto é uma questão de **especificação** antes de ser de código, e a resposta
está escrita uma vez, em `compute_curve_scene.dart`:

> um contorno emite uma linha de fechamento **se e somente se** emitiu ao menos
> um registro de curva e seu ponto corrente, *em espaço de origem*, difere do
> ponto inicial. Um contorno de um ponto só não emite nada; um contorno de dois
> pontos coincidentes emite o registro degenerado que o verbo pediu e nenhuma
> linha de fechamento, porque corrente já é igual a início.

A regra alternativa é a do sink de `ComputeTileScene`: emitir a aresta de
fechamento só quando o achatamento produziu uma aresta **não degenerada** em
espaço de dispositivo. Ela não é implementável aqui, e o motivo é estrutural e
não de gosto: é uma pergunta sobre o *resultado* do achatamento, e o resultado
do achatamento é produzido por threads que nunca viram o contorno. Decidi-la na
CPU significaria achatar na CPU primeiro, que é exatamente o trabalho que este
estágio existe para tirar de lá.

E as duas regras só divergem sobre arestas de **comprimento zero em espaço de
dispositivo**. O teste de cruzamento que consome um segmento é `y0 <= y && y1 >
y` (ou o espelho), falso para todo `y` quando `y0 == y1`: uma aresta degenerada
não contribui para o winding de amostra nenhuma. Logo o *desenho* é o mesmo e a
**numeração** não é — a regra escolhida pode dar a um desenho um segmento a mais
que a do sink, que é precisamente por que a tabela tem de vir da varredura do
próprio flatten e nunca de um `ComputeTilePlan`.

Uma correção de fato entrou junto: `ComputeCurveScene.appendPath` tratava um
verbo de curva sem contorno aberto mantendo o ponto inicial do contorno
*anterior*, o que fecharia o contorno com uma aresta atravessando o caminho até
um ponto que ele nunca tocou.

### 2. A tabela `firstSegment`/`segmentCount`

Um sexto kernel no estágio de flatten, `csDrawTable`, uma thread por desenho.
Não é uma segunda varredura: as curvas de um caminho são contíguas por
construção, então os segmentos do desenho são o intervalo
`[offsets[firstCurve], offsets[firstCurve + curveCount])` e as duas leituras
saem da mesma varredura que `compute_scan.dart` já produz. `uOffsets` tem
`curveCount + 1` entradas com o total no fim, então o último desenho não é caso
especial. O material e a regra de preenchimento viajam no registro de caminho —
`kComputeCurvePathStride` passou de 2 para 4 — e são copiados sem serem lidos,
de modo que a tabela sai já no layout `firstSegment, segmentCount, material,
fillRule` que os dois consumidores indexam.

### 3. A ligação em si

`uSegments` e `uDraws` saíram do lado **somente-leitura** para o lado
**leitura-escrita** nos estágios de segmentos e de cobertura. É o mesmo
argumento que `D3d12ComputeAlias` já fazia para `bins` e `references`: um root
SRV exige `NON_PIXEL_SHADER_RESOURCE` e os buffers do flatten vivem em
`UNORDERED_ACCESS` do nascimento à liberação, então bindá-los como SRV custaria
um par de transições por submissão em torno de um recurso que o produtor ainda
pode estar escrevendo. Como slots de leitura-escrita nunca escritos, eles aceitam
um alias, e a barreira UAV que a cadeia já grava entre despachos é toda a
ordenação de que uma leitura aliasada precisa.

As duas formas continuam alcançáveis — semeada da CPU e ligada ao flatten —
porque são os dois lados do argumento de paridade, e **o driver recusa a
mistura por argumento**: um índice de segmento resolvido pela tabela da outra
metade acha uma aresta que existe e pertence a outro desenho.

### O que continua na CPU, e por quê

As caixas por desenho. `ComputeCurveScene.deviceBounds` devolve a caixa do
**polígono de controle**, não a da polilinha achatada: não precisa de segmento
nem de varredura, é `O(pontos de controle)` da mesma transformação que o
codificador já percorre. Uma Bézier está dentro do fecho convexo do seu polígono
de controle, então essa caixa é um **superconjunto** da que `ComputeTileScene`
deriva de `Path.flattenTo`, e a área a mais não muda pixel: os tiles que ela
acrescenta não carregam segmento, e o backdrop da primeira referência de uma
linha é o winding líquido das arestas que atravessam a linha inteira à esquerda
dela, que é zero para um contorno fechado quer a linha comece um tile mais fora
ou não.

### O que a submissão encadeada não sabe

O desenho mais largo, em segmentos, que é a largura do despacho irregular do
estágio de segmentos. Na forma semeada isso é uma propriedade de um array que a
CPU tem; na forma ligada é **resultado da varredura**, e lê-lo é a cerca que
esta cadeia existe para remover. Virou orçamento — `ComputeRasterBudget.
drawSegments` — carregado de quadro a quadro como os outros três. Um orçamento
curto demais **não é um erro que o kernel possa levantar**: a guarda dele é
`local >= segmentCount`, então os segmentos além dela simplesmente não são
binados. `run()` recalcula o desenho mais largo a partir da varredura que leu de
volta e ressubmete; `submit()`, que não lê nada, exige o número.

### Paridade, medida nesta máquina

`test/rendering/gpu/compute/d3d12_compute_flatten_junction_test.dart` compara a
rota ligada com `ComputeTileD3d12Executor.submit(plan)` — a rota de cobertura já
provada contra `ComputeTileCpuReference` — **por pixel**. As duas não
compartilham array nenhum: só a geometria.

| cena | limite honesto | desvio observado |
|---|---:|---:|
| um retângulo | 0 | **0** |
| um desenho num tile de dezesseis | 0 | **0** |
| dois desenhos partilhando tiles | 0 | **0** |
| um triângulo | 0 | **0** |
| uma elipse | 16 | **0** |
| um quadrado com contornos degenerados | 0 | **0** |
| gravata-borboleta even-odd | 0 | **0** |

O limite é 0 onde toda aresta é reta, porque aí não há ponto interior e as duas
polilinhas são os mesmos pontos. Na elipse ele **não** é 0 por construção: os
dois achatadores concordam sobre o *número* de segmentos e colocam os pontos
interiores de propósito de formas diferentes — diferenças progressivas em
float64 contra avaliação direta de `B(j/n)` em float32 —, então um cruzamento
pode cair do outro lado de uma subamostra, que custa `255/16 = 16` níveis. O
que se mediu foi 0; o limite fica onde está porque é uma propriedade da
aritmética e não desta execução.

**O contorno degenerado é uma cena aqui, e não uma nota de rodapé**: é onde as
duas metades discordavam por construção. Para o mesmo caminho o sink dá 6
segmentos ao desenho e o codificador de curvas dá 7, e o desvio é 0 — que é
exatamente a afirmação do §1 verificada em pixels em vez de no papel.

As seis cenas da forma **semeada** continuam byte a byte contra a rota provada:
nada do que entrou mexeu nelas. Determinismo idem, nas duas formas: a mesma cena
duas vezes dá o mesmo buffer, e uma cena pequena depois de uma grande não deixa
tinta para trás.

### A sabotagem, porque um teste que só roda não prova nada

A falha que este relatório nomeou não lança. Então as duas foram encenadas de
propósito, e o teste falha se elas *não* forem visíveis:

| sabotagem | pixels movidos | pior desvio |
|---|---:|---:|
| numeração cruzada: segmentos do plano, tabela do flatten | 141 | **255** de 255 |
| regra de fechamento removida: sem a aresta de fechamento | 329 | **255** de 255 |

Duas armadilhas apareceram ao montá-las, e as duas dizem algo sobre a forma da
falha. Com **um** desenho só, a numeração cruzada corre para fora do array de
segmentos do plano, e um root descriptor além do seu buffer lê zeros —
`float4(0,0,0,0)` é uma aresta horizontal, e aresta horizontal não cruza nada.
E com um **retângulo** como segundo desenho, toda aresta emprestada é ou
horizontal ou metade de um par que se cancela. Foi preciso um segundo desenho
com arestas inclinadas para que a numeração cruzada pegasse geometria de
verdade. Pela mesma razão a sabotagem da aresta de fechamento não usa o
triângulo das cenas de paridade: a aresta que o fecha é horizontal, e apagá-la
não muda nada.

### Custo, com a ressalva de sempre

A ressalva desta seção é a mesma que o §"tabela de custo" faz, e ela vale ainda
mais aqui: **as duas colunas de GPU leem de volta um `uint` por pixel por
desenho** — 64 MiB na maior linha — e isso domina tudo o mais em ambas. As duas
são uma submissão de quatro estágios pelo mesmo driver, então **nada aqui é
atribuível a encadeamento**. O que difere é o lado CPU: a coluna semeada precisa
de um `ComputeTilePlan`, que é `ComputeTileScene.build` fazendo o achatamento, as
caixas, a deduplicação e a codificação; a coluna ligada não precisa de nada
disso e paga um kernel a mais.

Mediana de cinco execuções, três execuções do arquivo, Intel UHD, feature level
12_1:

| cena | plano (CPU) | semeada | plano + semeada | ligada |
|---|---:|---:|---:|---:|
| 4 desenhos, 128x128 | 0,8 – 1,4 ms | 2,7 – 7,7 ms | 3,5 – 9,2 ms | 2,4 – 5,1 ms |
| 16 desenhos, 256x256 | 2,2 – 2,4 ms | 7,6 – 8,9 ms | 9,9 – 11,4 ms | 7,0 – 9,3 ms |
| 64 desenhos, 512x512 | 5,3 – 36,7 ms | 57 – 98 ms | 62 – 105 ms | 62 – 101 ms |

**A faixa é o resultado**, e não um intervalo de confiança: a mesma medida
variou por mais de dois para um entre execuções deste mesmo arquivo, com a
leitura de volta dominando. O que se pode dizer honestamente é que a coluna
ligada fica **no mesmo lugar ou um pouco abaixo** da semeada apesar de despachar
um kernel a mais, e que ela não paga a coluna do plano. O que **não** se pode
dizer é qualquer razão entre elas.

## Artefatos

- `poc/poc_23_gpu_2d_strategies/bin/main.dart`: probe e benchmark executável.
- `poc/poc_23_gpu_2d_strategies/README.md`: comandos e definição de cada medida.
- `tool/gl_vector_routes_smoke.dart`: a prova em **janela real** — `HWND`,
  contexto WGL, `RenderingPolicy.gpuOnly`, `onError` instalado e os contadores
  por estratégia impressos ao final. `--baseline`, `--no-b` e `--no-c` cobrem
  as quatro combinações.
- `test/rendering/gpu/gl_route_availability_test.dart`: os mesmos fatos em
  alvo offscreen, incluindo o limite de desvio da borda do cover pass.
- `test/rendering/gpu/compute/d3d12_compute_flatten_junction_test.dart`: a
  junção flatten→segmentos comparada por pixel contra a rota provada, com as
  duas sabotagens e a tabela de custo desta seção.

O código continua executável em Linux para conferir portabilidade, mas este
relatório e seus números de decisão referem-se ao Windows nativo, conforme o
foco definido para esta medição.
