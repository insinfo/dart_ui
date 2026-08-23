# Aceleração vetorial previsível: direção Vello + Impeller

**Sparse strips foi PROMOVIDA a produção.** É escolhida pelo seletor sem flag,
por uma regra de custo medida (`cruzamentos de tile < k · área`), com o atlas
denso intacto como fallback e uma flag apenas para desligar.

A história, em três passos: a primeira avaliação **reprovou**, porque a densa
vencia de 256² a 2048². A causa era estrutural — as strips re-codificavam a
saída do `ScanlineFiller` em vez de rasterizar — e foi corrigida com
`NativeStripRasterizer`, o que fez a vantagem assintótica aparecer. Restava o
seletor decidir pela variável errada (bytes de upload); agora ele decide por
cruzamentos de tile contra área, que é o que a medição sustenta.

Ver *As strips como rasterizador*, *A regra de custo*, *A guarda de
cacheabilidade* e *Critérios para promover*.

**Estado em 23 de agosto de 2026:** formato sparse-strip, executores OpenGL
opt-in de sparse, B e C, primeiro plano D por tiles, seletor A–D e contrato GPU
de gradientes implementados e testados. **Attachments e sample count agora
fazem parte do descriptor do render pass**, e com isso a seleção entre A, sparse,
B e C passou a ser automática no replay OpenGL: o seletor lê o que o
framebuffer daquele pass realmente carrega, em vez de uma hipótese global. O
renderer padrão continua no atlas denso e qualquer recusa volta a ele antes de
produzir pixels.

## Objetivo

O `dart_ui` já possui uma pilha GPU comum (`GpuRasterSink`, batches, atlas de
máscaras/glifos e layers) sobre OpenGL, D3D11, D3D12, Metal, Vulkan, WebGL e
WebGPU em diferentes níveis de maturidade. O próximo salto não é criar outro
backend por API: é reduzir o custo de transformar geometria vetorial em pixels
de maneira previsível e compartilhada por todos eles.

Duas referências locais orientam a direção, sem serem copiadas:

- `referencias/engine-main/impeller`: shaders conhecidos antes do frame,
  recursos explícitos, instrumentação e separação entre renderer e backend;
- `referencias/vello-main/sparse_strips`: cobertura esparsa proporcional à
  borda da forma e consumível por vertex/fragment shaders, sem exigir compute.

O resultado pretendido é híbrido: o Dart prepara comandos e cobertura
compacta; a GPU compõe cor, gradientes, imagens, clips e layers. A mesma cena e
os mesmos bytes intermediários precisam poder ser executados por CPU para
paridade e diagnóstico.

## O problema do atlas denso

O caminho atual de paths rasteriza todo o bounding box para uma máscara
alpha8. Para um cartão de 300 x 300 são 90.000 bytes, embora quase toda a área
seja 0 ou 255. Isso é excelente como fallback e cache de formas estáticas, mas
gera custo por **área** em upload, atlas e banda.

`SparseStripGenerator` muda somente a representação da cobertura:

```text
Path + clip + transform
        |
        v
ScanlineFiller (verdade analítica compartilhada)
        |
        v
faixas de 4 linhas
   |                 |
   v                 v
alpha parcial      interior 255
(texels alpha8)    (quad sólido)
```

Cada strip parcial guarda `x, y, largura, alphaOffset`; cada fill guarda
`x, y, largura`. As quatro linhas de cobertura parcial ficam contíguas. Um
consumidor simples emite um quad instanciado por registro: fill não amostra
textura; strip amostra alpha8. A suíte reconstrói a máscara densa e exige
igualdade byte a byte com `ScanlineFiller`, inclusive curvas, transformação e
fill even-odd.

Um retângulo sólido 256 x 256 ocupa 64 registros de fill, menos de 1 KiB de
dados significativos, contra 64 KiB da máscara densa. Esse é um teste de
estrutura, não um benchmark de GPU.

## O que foi adotado de cada referência

| Princípio | Aplicação no `dart_ui` |
|---|---|
| Performance previsível (Impeller) | sem compilação de shader ou reflexão no frame; pipelines e layouts devem ser criados no device |
| Renderer/backend separados (Impeller) | sparse strips e paint encoding ficam em `rendering/gpu/vector`; GL/D3D/Metal/Vulkan apenas enviam os mesmos dados |
| Recursos explícitos (Impeller) | arenas tipadas, contadores de bytes/quads, limites e gerações visíveis |
| Trabalho por perímetro (Vello) | alpha apenas nas bordas; interior vira fill sólido |
| Vertex/fragment como piso (Vello Hybrid) | primeira implementação não depende de compute, storage buffers ou subgroup |
| CPU como referência (Vello CPU) | cobertura analítica existente permanece a verdade de paridade |

Não foi adotada a arquitetura compute-first do Vello clássico nesta fase. Ela
é um modo futuro para GPUs fortes, não o contrato mínimo.

## Abordagens de renderização 2D coexistentes

As quatro abordagens não são backends mutuamente exclusivos. A seleção ocorre
por draw: a mesma janela pode usar retângulo analítico, ícone cacheado,
tesselação retida e compute para um SVG deformável no mesmo frame.

| Abordagem | Implementação e uso preferido | Limitação principal |
|---|---|---|
| A. Atlas + shader analítico | primitivas fechadas no fragment shader; paths pelo `GpuMaskAtlas`; glifos em atlas. É o padrão de UI e o fallback de paridade | paths deformados exigem nova rasterização/upload |
| B. Tesselação CPU | curvas viram malhas retidas; vence em geometria estável, simples e sem auto-interseção | AA de borda e regras complexas elevam custo/risco |
| C. Stencil-then-cover | winding no stencil e cover posterior; indicado para path dinâmico arbitrário | múltiplos passes e banda de stencil/fill-rate |
| D. Compute/tile | flatten, binning e cobertura na GPU; indicado para vetores dinâmicos complexos | requer API moderna e tem custo fixo maior |

O sparse-strip híbrido é uma ponte adicional dentro de A: conserva a mesma
cobertura analítica da CPU, mas envia somente bordas alpha8 e interiores como
quads sólidos. Ele requer apenas vertex/fragment e por isso cobre hardware onde
D não está disponível.

### 1. Máscara densa (existente, fallback)

`ScanlineFiller -> GpuMaskAtlas -> quad`. Favorece formas estáticas já em
cache, é simples e está provado por paridade. Continua obrigatório.

### 2. Sparse strips híbrido (executor OpenGL experimental)

CPU/Dart faz flatten e cobertura; GPU faz fine raster/composição. Favorece UI,
paths grandes e dispositivos sem compute. O formato intermediário já existe.

Componentes concluídos:

1. atlas alpha8 paginado, uploads por shelf row e split de strips largos;
2. instâncias compactas solid/alpha, batches ordenados e arenas reutilizáveis;
3. métricas de upload, instâncias, páginas, draws e capacidade retida;
4. seletor determinístico por capacidade/custo entre A, sparse, B, C e D;
5. LUT RGBA8 de gradiente compartilhável pela CPU e pelos shaders.
6. `GpuPathWorkloadBuilder`, que deriva dimensões, geometria, elegibilidade e
   custos medidos de objetos reais em vez de aceitar estimativas incompatíveis.

O primeiro consumidor real está em `gl_sparse_executor.dart`. Ele mantém VBO
instanciado de seis floats, programa GLSL 3.30/ES 3.00, páginas alpha8, uploads
parciais e comandos ordenados por batch/material/page-run. O
`GlApiSparseDriver` traduz esse contrato para chamadas reais de `GlApi`; o
`GlRenderDevice` compila, desenha, descarta nomes perdidos e os recria após
reset. Tudo continua explicitamente opt-in por
`enableExperimentalSparseStrips`: os símbolos de instancing não alteram o
probe nem o caminho denso padrão.

Clip, layer e material **já** chegam do replay real: o recorder move transform
e clip para o espaço do target subtraindo a origem do layer e cortando pelo
viewport do pass, de modo que a cobertura sparse nasce já clipada e uma forma
dentro de `saveLayer` é encodada nas coordenadas do alvo do layer. A paridade
por pixels contra a CPU foi medida em framebuffer real (desvio 0 em sólido,
desvio 1 em gradiente; ver a tabela mais adiante). Material de gradiente também
já chega do replay — ver a seção sobre gradientes. O que falta é portar o layout
para MSL. O shader GL experimental já consome a mesma
`GpuGradientBinding`/`GpuGradientShaderParameters` do contrato comum: linear,
radial/focal e pad/repeat/reflect amostram a LUT straight-alpha, premultiplicam
e só então aplicam a cobertura sparse. Binding e parâmetros de gradientes
diferentes, texture name zero e scalars que deixam de ser finitos ao estreitar
de `double` para float32 são recusados antes do pass. Isso impede que valores
finitos em Dart virem `Inf` silenciosamente no shader.

#### Sparse strips no navegador: WebGL2 e WebGPU

O desenho do Vello não exige compute nem storage buffer — os dados viajam como
textura inteira e quads instanciados — e é isso que torna a mesma abordagem
executável nos dois backends web. Ambos são opt-in por
`enableExperimentalSparseStrips` na adoção do contexto/device e só são
alcançados por um seam explícito (`submitSparseStrips`); o replay padrão
continua no atlas denso.

**WebGL2** não ganhou shader novo: WebGL2 *é* GLES 3.0, portanto
`webgl_sparse_driver.dart` compila o dialeto ES que `gl_sparse_strips.dart` já
emite e implementa a mesma interface `SparseGlDriver`, com `SparseGlExecutor`
dirigindo-o sem alteração (`vertexAttribDivisor` + `drawArraysInstanced` +
página R8). O mesmo argumento que faz `webgl_backend.dart` importar
`gl_shaders.dart` em vez de copiá-lo vale aqui, e vale mais: a cobertura do
strip *é* o antialiasing, e uma cópia que divergisse desenharia bordas
diferentes a partir do mesmo plano.

**WebGPU** ganhou `wgsl_sparse_shaders.dart` (tradução do GLSL, um vertex e
quatro fragment entry points — um por par cobertura×paint, porque o blend já
assa no pipeline), `webgpu_sparse_executor.dart` (executor + driver fakeável em
inteiros, testável na VM) e `webgpu_sparse_driver.dart` (o único arquivo com
`dart:js_interop`). O layout de instância é *o mesmo* `SparseGlSubmission`: a
ordem batch/material/page-run é a propriedade correta a preservar e ter dois
codificadores seria ter dois lugares onde ela pode estar certa. `firstInstance`
substitui o rebase de ponteiro que o GL 3.3 precisa. Uniformes vão em um slice
de 112 bytes por material, a 256 de distância, ligado por offset dinâmico.

Duas divergências de linguagem estão comentadas no WGSL porque produziriam
imagem plausível e errada: `mod(x, 2)` do GLSL é escrito como
`x - 2*floor(x/2)` (o `%` do WGSL trunca em direção a zero e espelharia a rampa
`reflect` pelo lado errado), e `all(equal(a,b))` vira `all(a == b)`.

Uma armadilha real encontrada e corrigida no WebGL2: um comando *solid* não
amostra textura alguma, então o executor não liga nada — e o que sobra ligado
na unidade 0 é frequentemente a textura de cor do próprio FBO alvo. Isso é
feedback loop e o WebGL2 recusa o `drawArraysInstanced` inteiro com
`INVALID_OPERATION`. O driver web passa a ligar stand-ins de um texel nas
unidades 0 e 1 no início do pass, exatamente como o backend WebGPU liga um
dummy para o grupo que o pipeline layout exige.

### 3. Tesselação/AA geométrico

CPU tessela paths e envia triângulos; MSAA ou AA analítico resolve bordas.
Favorece geometria pequena/reutilizada e APIs como Metal/Vulkan/D3D12. Deve
usar o mesmo paint/layer contract, não um segundo renderer.

`CpuPathTessellator` implementa um contorno simples fechado, convexo ou
côncavo, triangulado por ear clipping. Quadráticas e cúbicas são achatadas com
tolerância explícita e limite de 65.536 segmentos; exceder o orçamento recusa
o draw sem aceitar silenciosamente o clamp do flattener geral. A malha fica em
coordenadas locais (`Float32List` XY + `Uint32List`) e
`CpuTessellatedPathCache` a retém por conteúdo/fill rule/tolerância, portanto
uma transformação por frame não invalida o VBO. Holes, múltiplos contornos,
abertura, auto-interseção e degeneração ainda são recusados por motivo tipado.
Como a tolerância é local, o chamador deve derivá-la da escala máxima prevista
quando o erro exigido for expresso em pixels de device.

O consumidor OpenGL agora mantém VBO/IBO por `TessellatedPathCacheKey` e o
replay o promove de fato. A restrição a `antiAlias=false` deixou de ser uma
regra global e virou uma leitura do pass: B é elegível para paint aliased em
qualquer alvo e para paint antialiased **apenas em pass multiamostrado**,
porque o shader B ainda não tem fringe analítico. Com gradiente, topologia
recusada ou falha de preparação, o comando não é inserido e o mesmo draw segue
pelo atlas A. Um teste no driver Intel valida por pixels a ordem
`dense -> B -> dense` e outro parte de uma `DisplayList` real.

### 4. Stencil-then-cover

`StencilCoverDrawPlan` materializa a abordagem C sem depender da API: arenas
tipadas de triângulos-fan assinados, bounds de cover e três comandos ordenados
por draw (clear, accumulate e cover). Non-zero usa increment/decrement wrap por
face; even-odd inverte o bit zero; o cover testa e zera stencil. Capacidade de
stencil, MSAA, clear limitado e operações obrigatórias são validadas antes da
emissão. Coordenadas não finitas e o limite de triângulos geram recusas
tipadas e transacionais.

`StencilCoverGlExecutor` e `GlApiStencilCoverDriver` executam esse contrato em
GL 3.3/ES 3.0. Os bindings opcionais não entram no probe denso; a ativação
exige `enableExperimentalStencilCover`. Lifecycle e device loss estão ligados
ao `GlRenderDevice`, e cada submissão consulta novamente os attachments do FBO
selecionado. Em perfil core o tamanho do stencil é obtido por
`glGetFramebufferAttachmentParameteriv`, não pelo `GL_STENCIL_BITS` legado.
Consultas preservam o draw-FBO anterior, rejeitam IDs negativos e verificam
`glCheckFramebufferStatus` antes de interpretar stencil/MSAA; um FBO
incompleto nunca produz capacidades residuais.
O pool GL agora possui uma variante explícita por descriptor: tamanho,
stencil e amostras fazem parte da chave e do orçamento; stencil8 single-sample
foi validado em driver real. MSAA possui renderbuffers e resolve explícito,
mas não é entregue silenciosamente ao `GpuLayerStack`, pois o composite
precisa ordenar o resolve antes de amostrar a textura. Integrar essa sequência
ao replay continua pendente, e é o último item entre este backend e C
automático — ver a seção sobre attachments abaixo, e em particular a medição de
144 níveis que proíbe o atalho de uma amostra só.

### 5. Tile/compute

Flatten, binning, prefix sums e rasterização em compute, semelhante ao Vello
clássico. Só é escolhido quando compute, storage buffers e sincronização são
confiáveis. WebGL2, drivers limitados e o fallback WSL continuam no modo 2.

`ComputePathEncoding`, `ComputeTileScene` e `ComputeTilePlan` já materializam
a fase neutra de API: segmentos float32 deduplicados, draws, bounds, bins CSR,
referências em ordem e comandos por tile ocupado. `ComputeTileCpuReference`
valida non-zero/even-odd e cobertura determinística.

O **Direct3D 12 já executa esse encoding de verdade, e já compõe o resultado no
render target** — ver a seção Direct3D 12 no fim deste documento. O encoding
ganhou depois disso, de forma aditiva, **bins de segmento por tile com backdrop
por tile** (`referenceSegments`, `tileSegments`, `referenceBackdrops`) e
**arredondamento de clip para pixel inteiro**, que é a semântica que
`ScanlineFiller` já tinha; ambos são neutros de API e servem a qualquer backend.
`VectorPlanCache` retém encodings por conteúdo para as duas rotas
experimentais.

Continuam faltando, em todos os backends: binning **na GPU** (hoje é CPU),
scan/prefix, materiais de gradiente nestas rotas, retenção dos buffers de GPU
entre frames, e os bindings de compute para Vulkan, Metal e WebGPU.
`RendererCapabilities.supportsCompute` só é verdadeiro no device Direct3D 12
aberto com a flag experimental.

### 6. Primitivas analíticas

Retângulos, rounded rects, círculos e linhas simples podem ser avaliados no
fragment shader sem máscara. É o caminho mais barato e deve vencer antes de
qualquer general path pipeline.

## Gradientes

`Gradient`, `LinearGradient`, `RadialGradient` e `GradientStop` são valores
imutáveis. O display list interna o gradiente e guarda kind/id nos bits livres
do paint. `GradientLut` produz RGBA8 sRGB straight-alpha com interpolação e
rounding determinísticos; a premultiplicação ocorre na composição final. O
replay CPU usa a inversa local↔device e respeita clip e `saveLayer`.

`GpuGradientCache` já deduplica e envia essa LUT como textura 1×N straight
RGBA, recriando-a após device loss. `GpuGradientShaderParameters` fornece
matrizes local↔target, origem de layer, geometria linear/radial/focal e layout
lógico comum às APIs. Sinks nativos/GPU ainda não integrados recusam
gradientes explicitamente; nunca os tratam silenciosamente como cor sólida.

## Seleção por custo, não por plataforma

A escolha pertence ao renderer e usa fatos da cena/device:

- primitiva analítica quando suportada;
- máscara em cache quando o hit evita nova rasterização/upload;
- sparse strips quando upload alpha + instâncias são materialmente menores que
  a máscara e o número de páginas/draws permanece limitado;
- tesselação quando uma malha reutilizável vence os texels;
- compute quando o device e a carga justificam o pipeline.

Assim Linux normal, WSL, Windows e macOS executam o mesmo Dart. WSLg sem DRI3
ou com uma rota de apresentação quebrada pode mudar o **presenter**, mas não a
representação da cena ou a correção do renderer.

## As strips como rasterizador

A primeira versão de sparse construía strips rodando o `ScanlineFiller` e
re-codificando os spans dele. Isso deixava o **trabalho** exatamente onde
estava e só barateava o transporte — e por isso perdia para a densa em toda a
faixa medida. `NativeStripRasterizer` fecha essa lacuna: calcula cobertura a
partir da geometria, por tile 4×4, sem passe de scanline nenhum.

O pipeline, portado de `vello_common` (`tile.rs`, `strip.rs`, Apache-2.0/MIT):

1. **flatten** para segmentos;
2. **tiling** — cada segmento nos tiles 4×4 que atravessa, guardando **um bit**
   por cruzamento: a linha corta a borda *superior* daquele tile? Esse bit é
   toda a contribuição de winding grosso;
3. **ordenação** por (y, x, linha) com radix sort estável de duas passadas;
4. **render** — área trapezoidal exata por pixel, `acc` propagando para a
   direita, e uma strip por corrida de tiles adjacentes, com os vãos totalmente
   cobertos virando fills sólidos.

Três armadilhas que custaram convergência e que ficam registradas:

- **Aresta horizontal não pode ser descartada no tiler.** Ela não contribui
  winding nem área — o render a pula — mas é o que *marca* quais locations
  precisam de alpha. Sem ela, um retângulo de topo fracionário perde todas as
  colunas depois do primeiro tile, porque a strip termina na aresta esquerda e
  o winding por scanline não tem onde ser escrito.
- **Geometria fora do clip não pode ser só "grampeada no tile 0".** A cobertura
  dentro do clip depende de arestas fora dele. O Vello culla a geometria e
  guarda winding por linha à parte; aqui a aresta é **partida** e a parte de
  fora vira vertical na borda do clip — que é exatamente o que o
  `ScanlineFiller` já documenta fazer, então as duas rotas concordam por
  construção.
- **Linha vertical exatamente na borda de um pixel** dá `y_slope = ±inf` e
  `0 * inf = NaN`. A convenção é que a linha pertence ao pixel de cuja borda
  *esquerda* ela está. O Rust obtém isso da semântica de `max` do x86; em Dart
  toda comparação com NaN é falsa, então é um teste explícito.

**Paridade:** 18 cenas adversariais contra o rasterizador atual (retângulo
fracionário, diagonal, curva, furo com winding oposto, even-odd, contornos
sobrepostos, forma maior que a tela, forma à esquerda do clip, vertical na
borda de pixel e de tile, degenerada, transform, clip fracionário, 24 formas
pequenas, estrela auto-intersectante). Desvio ≤ 1 nível em todas, 0 nas de
borda inteira. Mais 4 cenas de benchmark verificadas por igualdade.

O primeiro rascunho falhou em 9 das 18 — o teste foi o que convergiu.

## A regra de custo

Este é o resultado da etapa, e **não é um vencedor único**. Medido nesta
máquina (Intel UHD), CPU isolada, mediana de 51, 256×256, microssegundos:

| Cena | cruzamentos de tile | densa | re-codificada | **nativa** |
|---|---|---|---|---|
| painel (8 arestas, muita área) | 288 | 260 | 384 | **137–149** |
| ícones (64 formas pequenas) | 1 740 | 278 | 364 | 307–347 |
| espirógrafo (721 arestas finas) | 4 152 | 328 | 437 | 528–792 |
| estrela (62 arestas longas) | 4 646 | 540 | 673 | 954–988 |

A variável independente **não é a contagem de segmentos**: é o número de
**cruzamentos de tile**. A estrela tem 62 arestas e custa mais que o
espirógrafo de 721, porque cada aresta dela atravessa a superfície inteira.

E a curva vai no sentido **oposto** ao esperado:

> Strips ganham quando os cruzamentos de tile são **poucos em relação à área** —
> forma grande e simples. A densa ganha quando os cruzamentos são densos.

O mecanismo é direto quando se olha o que cada rota paga por unidade de
trabalho. A densa custa área, mas seu custo *por pixel* é um `fillRange` — na
velocidade de um memset. A strip custa ~240 operações escalares por cruzamento
de tile (16 pixels de matemática de área analítica, sem SIMD). Trocar escritas
baratíssimas por pixel por matemática cara por cruzamento só compensa quando há
muito interior para pular — e interior é justamente o que vira fill sólido de
graça.

No Vello essa conta é outra porque o laço de 4 pixels é uma instrução SIMD. Em
Dart não é, e essa é a diferença que a porta não consegue apagar.

### O mesmo, com a GPU no meio

Deformando (nenhum cache ajuda), varredura por área, três execuções:

| Superfície | sparse | densa | |
|---|---|---|---|
| 256² | 1,58 / 1,72 / 2,18 ms | 1,34 / 1,79 / 1,62 ms | empate dentro do ruído |
| 512² | **1,79 / 2,05 / 2,56** | 3,10 / 3,16 / 3,19 | **sparse ~1,5×** |
| 1024² | **5,42 / 5,84 / 6,34** | 9,07 / 9,83 / 8,97 | **sparse ~1,7×** |
| 2048² | **18,98 / 19,56 / 17,27** | 33,62 / 31,63 / 38,34 | **sparse ~1,8×** |

Comparar com a tabela anterior (re-codificada) é o ponto: lá a densa vencia em
toda a faixa e **a distância não fechava com a área**. Aqui ela inverte a
partir de 512² e a vantagem *cresce*. A hipótese arquitetural era essa, e ela
só aparece quando as strips deixam de pagar a rasterização da densa.

## A guarda de cacheabilidade: o que adotei das referências

O levantamento em `CACHE_DE_COBERTURA_REFERENCIAS.md` mostrou que o precedente
do nosso `GpuMaskAtlas` é a **Skia**, não o Impeller, e que a Skia protege esse
cache com guardas que nós não tínhamos. Vale separar duas perguntas que estavam
misturadas:

- **"esta forma volta?"** — responde o modelo de repetição;
- **"esta forma é cacheável?"** — respondem as guardas da Skia.

### Adotada: alinhar a chave de repetição à chave do atlas

A chave de repetição usava o `Transform2D` inteiro, incluindo a translação
absoluta. O `GpuMaskAtlas` **não** faz isso: ele chaveia pelo deslocamento
**sub-pixel** em relação à origem inteira da máscara, mais o tamanho
(`gpu_mask_atlas.dart`, `dx = transform.tx - left`). Consequência real: uma
lista rolando de pixel em pixel **acerta** o cache do atlas, e a chave antiga
declarava cada frame um draw novo — perdendo exatamente os acertos que o atlas
existe para capturar.

Prever "o atlas teria isso em cache" com uma chave mais grossa ou mais fina que
a do próprio atlas é prever a coisa errada. Corrigido: a chave agora decompõe em
2×2 exata + translação sub-pixel + tamanho + fill rule, espelhando o atlas.

A Skia vai um passo além e quantiza a translação fracionária em 8 bits por eixo
(`SoftwarePathRenderer.cpp:341-343`); o nosso atlas compara exato, então a chave
de repetição também compara exato. **Subir isso é mudar a política de fidelidade
do atlas**, não da guarda, e fica registrado como proposta abaixo.

A 2×2 é comparada exatamente, como em toda referência: Skia exige a 2×2 exata
(`:321`), o cache de glifo do Vello compara bits de f32, o Flutter compara a
`SkMatrix` inteira. Ninguém tolera escala aproximada, porque máscara reamostrada
em outra escala é máscara mais borrada, não mais barata.

### Não adotada no seletor: desligar por não-preservar alinhamento de eixos

A Skia desliga o cache quando a matriz não preserva alinhamento de eixos, *"to
prevent overloading the cache with entries during animations"*
(`SoftwarePathRenderer.cpp:284`). É uma guarda excelente — e no **seletor** ela
seria uma regressão aqui, porque nós temos informação melhor.

A guarda da Skia é um **proxy** para "isto está animando", já que a Skia não
guarda histórico. Nós guardamos. Uma forma sob rotação *animada* já não repete
(a 2×2 muda todo frame), então o modelo de repetição a marca não-cacheável
sozinho. Mas uma forma sob rotação **constante** — girada uma vez e parada — é
perfeitamente cacheável, e a guarda da Skia a mandaria para outra rota sem
motivo. Histórico de repetição subsume o proxy e é estritamente mais preciso.

**Onde ela ainda vale é dentro do atlas**, que não tem acesso ao histórico e
hoje enche de entradas durante um pinch-zoom que nunca serão reusadas.
Registrado como próximo passo, com o número que o justificaria ainda por medir.

### Não adotadas: >50% visível, e limites de tamanho

- **>50% visível** (`SoftwarePathRenderer.cpp:304-316`): plausível, mas eu não
  tenho medição que a sustente aqui e o custo que ela evita — entradas de atlas
  desperdiçadas — é o mesmo que a guarda anterior ataca melhor. Não adotar sem
  medir é a regra que este documento vem seguindo.
- **Limites de tamanho** (Skia: 256², 128² — `AtlasPathRenderer.cpp:122-132`):
  **redundante com a regra de custo**, e foi verificado em vez de assumido. A
  regra `cruzamentos < k · área` já manda forma grande para sparse: no painel de
  256² são 0,0044 cruzamentos/pixel e a 1024² são 0,0011, cada vez mais dentro
  do limiar. Somar um teto de tamanho seria um segundo critério dizendo a mesma
  coisa com outro número para desafinar.

### Proposta para a camada de widgets

O sinal que falta ao seletor e que só a árvore conhece é **"esta subárvore está
animando"**. Hoje ele é inferido do histórico, o que custa um frame de atraso e
não distingue "parou" de "vai voltar a andar". Uma dica vinda do widget
(`AnimatedBuilder`, uma transição em curso, um gesto de pinch ativo) responderia
antes do primeiro frame e cobriria o caso que o histórico erra: o começo de uma
animação. **Não implementado aqui** — API de widgets é território de outro
agente — e registrado como proposta.

Isso também é o que o contexto de produto pede: chrome estático e canvas animado
convivem no mesmo frame, e a resposta certa não é um modo global.

## Critérios para promover sparse strips a produção

**Veredito: PROMOVIDA.** Sparse strips passou a ser escolhida pelo seletor sem
flag experimental, com o atlas denso intacto como fallback e uma flag apenas
para **desligar**.

| Critério | Veredito | Evidência |
|---|---|---|
| paridade solid, clips, layers | atende | desvio 0 |
| paridade gradiente | atende | 1, e 2 no radial focal (atribuído) |
| paridade imagem e glifo | reescrito | recusa nomeada |
| nenhum shader compilado no frame | atende | inicialização na abertura do device |
| arenas sem alocação por draw | atende | `bufferGrowths` estabiliza |
| medição separada CPU/upload/GPU | atende | CPU isolada por rota; bytes dos dois lados |
| device loss e invalidação | atende | teste em driver real |
| **ganho sobre a máscara densa** | **atende** | seletor escolhe sparse só onde ganha — tabela abaixo |
| sem regressão em GPU sem instancing | **atende por construção** | política `auto`: driver sem instanced arrays fica no atlas denso, o backend **não** é recusado |
| sem regressão em Linux sem WSL | **não afirmável** | só há esta máquina |

### O que "promovida" significa em código

`GlSparseStripsPolicy` com três estados, porque um booleano não conseguia
distinguir dois casos que precisam de respostas opostas quando o driver não tem
instanced arrays:

| Política | Sem instancing | Para quê |
|---|---|---|
| `auto` (padrão) | segue sem sparse, backend íntegro | produção |
| `disabled` | idem | **kill switch** |
| `required` | recusa o backend | testes e medições da rota |

Antes da promoção o flag significava `required`, então ligá-lo por padrão teria
feito um símbolo ausente derrubar o backend GL inteiro. A degradação vale também
para a **recuperação de device loss**: se a rota opcional não puder ser
reconstruída, ela é descartada em vez de o device ser marcado perdido — senão
"este driver não reconstrói uma otimização" viraria "este renderer não desenha".

### A decisão, por cena

Medido nesta máquina, 256×256 (`strip_rasterizer_cost_test.dart`):

| Cena | cruzamentos/pixel | rota escolhida | medição |
|---|---|---|---|
| painel | 0,0044 | **sparse** | 2,5× mais rápida |
| ícones | 0,0266 | atlas denso | empate, dentro do ruído |
| espirógrafo | 0,0634 | atlas denso | ~1,4× mais lenta |
| estrela | 0,0709 | atlas denso | ~1,7× mais lenta |

E com a GPU no meio, deformando (nenhum cache ajuda):

| Superfície | sparse | densa |
|---|---|---|
| 256² | **0,96–1,06 ms** | 1,21–1,33 |
| 512² | **1,75–1,89** | 2,92–2,99 |
| 1024² | **4,89–4,93** | 9,28–9,56 |
| 2048² | **16,1–16,8** | 33,4–35,3 |

O seletor escolhe sparse em todas essas — e recusa nas três cenas densas em
arestas onde ela perde. É essa correspondência, e não o número isolado, que
autoriza a promoção.

## Attachments e sample count no descriptor do pass

`GpuRenderPass` passou a carregar `GpuPassAttachments` — bits de depth, bits de
stencil e contagem de amostras. O valor não vem do device: vem do alvo que
aquele pass vai realmente ligar.

| Pass | Origem do valor |
|---|---|
| superfície | `GpuLayerStack.beginFrame(surfaceAttachments:)`, declarado pelo target |
| layer | o alvo devolvido pelo alocador, via `GpuAttachmentAwareTarget` |

A mudança é **aditiva**: `GpuLayerTarget` não ganhou membro obrigatório. Um
alvo que sabe mais implementa também `GpuAttachmentAwareTarget`; qualquer outro
— e são cinco backends mais os fakes de teste — continua lido como
`GpuPassAttachments.colorOnly`, que é exatamente o que ele é. Nenhum backend
fora de OpenGL precisou mudar.

Por que isso importa: o mesmo contexto GL tem um framebuffer default sem
stencil (medido assim na Intel UHD), um FBO offscreen que este backend cria e
portanto pode criar com stencil8, e alvos de layer do pool que são só cor.
Perguntar ao *device* "tem stencil?" dá uma resposta e está errada para dois
dos três. Um comando de stencil-then-cover emitido contra um framebuffer sem
stencil não falha: desenha o quad de cover sem máscara, ou seja, a bounding box
no lugar da forma.

`GlWindowTarget` consulta o framebuffer 0 uma vez por contexto.
`GlOffscreenTarget` cria o que precisa: quando o executor C está ligado, um
**framebuffer multiamostrado** (cor RGBA8 + stencil8) passa a ser o alvo de
desenho, e o FBO de sempre — com a textura single-sample — vira o alvo de
**resolve**. Um `glBlitFramebuffer` no fim do `present`, depois de todos os
passes e antes do readback, move os pixels: `glReadPixels` não lê renderbuffer
multiamostrado, e o composite de um layer amostra uma textura, que um
renderbuffer também não é.

A contagem de amostras é a que o driver oferecer, até um teto de 16 — é o único
controle que um cover pass tem sobre a qualidade da borda, e o teto é memória,
não qualidade (ver a tabela de desvio adiante).

Cada passo é verificado e **toda falha recua** em vez de levantar: driver sem
`GL_MAX_SAMPLES` de 4, framebuffer incompleto ou erro de GL deixam o alvo em
stencil8 de uma amostra — ou só cor, se nem isso. O target declara o que
realmente tem e o seletor acredita. Nada aqui pode impedir um frame de
renderizar.

Um teste no driver real confirma pelos dois lados: o que o target declara e o
que `glGetFramebufferAttachmentParameteriv` responde.

### A armadilha que custou a primeira tentativa

A primeira tentativa de MSAA foi revertida por `GL_INVALID_OPERATION` em
cascata. A causa não era o MSAA: era `_attachmentStencilBits` pedindo
`GL_FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE` de um attachment `GL_NONE`. A
especificação diz que isso gera erro, e **erro de GL é sticky** — o próximo
`checkError` de um teste sem relação nenhuma o recolhia e marcava o device como
perdido, o que se lia como um driver que parou de desenhar. Hoje o tipo do
objeto é consultado primeiro e um framebuffer só de cor responde 0 sem erro
algum, que é a resposta ordinária de todo alvo de layer.

## O que virou automático no replay OpenGL

`GlVectorReplay` é a fiação única dos dois targets GL — offscreen e janela —
justamente para que um golden test e a tela sigam o mesmo caminho. Ela responde
capacidades **por draw**, cruzando os attachments do pass com o `antiAlias` do
paint:

| Rota | Exige |
|---|---|
| sparse strips | executor ligado **e** (`antiAlias` **ou** gradiente) |
| tesselação (B) | executor ligado **e** (aliased **ou** pass multiamostrado) |
| stencil-then-cover (C) | executor ligado **e** stencil no pass **e** ≥ 4 amostras |

A terceira linha é uma medição, não cautela. Um path preenchido neste renderer
é **sempre** antialiased analiticamente: CPU, atlas denso e encoder sparse
tiram os bytes do mesmo `ScanlineFiller`, e nenhum deles consulta o flag
`antiAlias` do paint para um path. Um cover pass de uma amostra produz borda
binária: a mesma cena mediu **144 níveis de diferença em 572 pixels de borda**
contra a CPU. Promover para isso seria trocar a imagem por velocidade, que é a
única coisa que um seletor não pode fazer. Com o sample count no descriptor, o
seletor recusa sozinho abaixo de 4 amostras — e agora que o alvo multiamostrado
existe, ele liga C sozinho.

**Gradiente inverte a regra.** Para todo outro draw o atlas denso é o fallback
garantido, e por isso toda recusa acima é uma decisão de custo. Um gradiente não
tem esse fallback: o atlas guarda um alpha por texel e o modula por uma cor só,
então mandar um gradiente para lá pintaria um preenchimento chapado. B e C têm o
mesmo problema — ambos entregam ao rasterizador geometria e um material sólido.
Então para um draw com gradiente as capacidades reportam **sparse ou nada**, e
"nada" faz o seletor levantar, a telemetria conter, e o `GpuRasterSink` recusar
nomeando o backend. Um gradiente é desenhado como gradiente ou recusado em voz
alta; nunca é achatado em silêncio para a cor de fallback do paint.

O seletor também ganhou `stencilMinimumDenseMaskBytes` (16 KiB por padrão):
acima disso, uma máscara densa **não cacheada** custa uma rasterização de CPU e
um upload proporcionais à **área**, que C substitui por geometria proporcional
ao **perímetro**. Uma máscara já residente continua vencendo, porque não custa
nada.

Resultado medido no driver Intel UHD desta máquina, tudo partindo de uma
`DisplayList` real, sem nenhuma chamada explícita a executor:

| Cena | Rota escolhida | Desvio contra a CPU |
|---|---|---|
| path com furo, antialiased, 143×143 | **sparse strips** | 0 |
| mesmo path aliased, pass stencil8 + 16 amostras | **stencil-then-cover** | 0 |
| mesmo path com bordas fora da grade | **stencil-then-cover** | **18** em 636 pixels |
| mesmo path antialiased pequeno (18×18) | atlas denso | 0 |
| mesmo path dentro de `saveLayer` grande (152×152) | **stencil-then-cover** | 0 |
| mesmo path dentro de `saveLayer` pequeno (80×80) | atlas denso | 0 |
| gradiente linear repeat, path | **sparse strips** | 1 |
| gradiente radial focal reflect | **sparse strips** | 1 |
| retângulo com gradiente | **sparse strips** | 1 |
| gradiente dentro de `saveLayer` | **sparse strips** | 1 |

Três números e três significados diferentes, que é a razão de estarem separados:

- **0** é exatidão de verdade. Sparse transporta os mesmos bytes de cobertura
  que a CPU calcula; não há aritmética sobrando para arredondar diferente.
- **1** é arredondamento. Os dois lados leem a mesma LUT de 256 entradas e
  interpolam entre vizinhos — `GradientLut.sampleArgb` existe para espelhar uma
  textura com filtro linear — mas a GPU faz essa interpolação com os pesos
  sub-texel em ponto fixo do próprio sampler. É a mesma tolerância que a
  comparação sparse de gradiente no Direct3D 12 declara.
- **18** não é arredondamento: é **quantização**. N amostras expressam N+1
  valores de cobertura; cobertura analítica é contínua. Nas cenas cujas bordas
  caem exatamente sobre um desses valores — meio pixel eixo-alinhado, 45° pela
  grade — os dois coincidem e o desvio é 0, o que é sorte da geometria e não
  uma propriedade da rota. Numa borda fora da grade o desvio medido é 18 níveis
  em 636 pixels de um total de 25.600; o interior é exato e só a franja difere.

O número encolhe com 1/N e foi medido nos dois pontos:

| Amostras | Desvio na borda fora da grade |
|---|---|
| 4 | 42 |
| 16 | 18 |

O alvo offscreen pega **16** porque o driver oferece (`GL_MAX_SAMPLES = 16` na
Intel UHD desta máquina) — o teto é memória, não qualidade. É esse o custo
declarado da abordagem C.

### Por que não há franja analítica (ainda), e o que ela custaria

Investiguei o Impeller para portar a técnica, e o achado foi o contrário do
esperado: **o Impeller não faz AA analítico de borda para fills**. Não há uma
única ocorrência de `fwidth`/`dFdx`/`dFdy` na árvore do Impeller, não há fringe
nem atributo de distância por vértice, o `solid_fill.frag` é literalmente
`frag_color = color`, o `clip.frag` do prepass de stencil é `void main() {}`, e
o `dl_dispatcher.cc` documenta `setAntiAlias` como no-op porque "AA is
implicit". O AA de geometria do Impeller **é 4× MSAA com o attachment de stencil
também multiamostrado** — exatamente o pipeline que este backend agora tem, com
4× em vez dos 16× daqui.

A razão de fundo é estrutural, não de esforço: **o cover pass não tem como
calcular cobertura analítica**. Ele é mascarado por um teste de stencil, que é
binário, e não se tira derivada de um teste de stencil. AA analítico só sai de
graça no fragment shader quando a forma tem SDF fechada — é o que o
`rrect_blur.frag` do Impeller faz para retângulo arredondado, e não generaliza
para path arbitrário.

Fazer de verdade custa **geometria, não shader**: tesselar um anel de ~1px ao
redor do contorno com um atributo por vértice de distância, e o fragment fazer
`alpha *= clamp(d / fwidth(d), 0, 1)`. Isso arrasta offsetting de contorno,
joins e caps, e é **incompatível com o cover-quad sobre a bounding box** — a
franja substitui o cover na borda, então o cover teria de ser a forma inset de
meio pixel. É um subsistema do tamanho de um stroker, não um ajuste de shader,
e está registrado como tal abaixo.

Enquanto isso, C só é escolhido para forma grande, não cacheada e recusada pelo
tesselador — o caso em que a alternativa é rasterizar e subir ~20 KB de máscara
por frame.

## Attachments em alvos de layer

Um alvo de layer é adquirido quando o layer **abre**, antes de qualquer conteúdo
ser gravado nele. Então o que ele carrega não pode ser deduzido do conteúdo:
seria preciso varrer a display list adiante — passando por layers aninhados e
por clips que talvez descartem tudo — e essa varredura custa mais do que a
memória que economizaria, além de ter de concordar exatamente com a decisão que
o seletor tomaria depois.

Por isso é **política**, expressa sobre o único fato disponível no push (o
tamanho) mais o que o backend sabe de si:

| Condição | Attachments |
|---|---|
| executor C desligado | só cor |
| qualquer eixo < 128 px | só cor |
| resto | stencil8 + 4 amostras |

O limiar de 128 px não é gosto: `stencilMinimumDenseMaskBytes` são 16 KiB, que
uma forma precisa ter uns 128×128 para alcançar, e **uma forma não pode ser
maior que o layer que a corta**. Abaixo disso os attachments comprariam uma
capacidade que nada lá dentro conseguiria usar, e uma interface abre muito mais
badges e chips do que painéis inteiros.

As 4 amostras (contra 16 da superfície) também são custo: um frame tem uma
superfície e pode ter muitos layers, todos residentes até o fim do frame, então
o custo de um layer multiplica pela contagem. A `samples * 5` bytes por pixel,
16× em oito layers de 512×512 são 168 MiB contra o orçamento de 256 MiB do pool;
4× são 42 MiB. E 4 é o mínimo que C exige para ser selecionado, ou seja, a
alocação mais barata que destrava alguma coisa.

Errar a política **nunca é imagem errada, só custo errado**: layer que ganhou
attachments e não precisou desperdiçou memória; layer que precisou e não ganhou
tem seu conteúdo desenhado pelo atlas denso, que é a rota de paridade.

Duas peças fecham isso:

- `GpuAttachmentAwareAllocator`, interface **adicional** (pelo mesmo motivo de
  `GpuAttachmentAwareTarget`): os quatro backends que implementam só
  `GpuLayerTargetAllocator` continuam compilando e recebendo o método simples.
  Se o alocador não souber responder, a stack cai para só-cor em vez de fingir.
- O **resolve ordenado**. `GlRenderDevice` resolve um alvo de layer
  multiamostrado no fim de *cada* pass que escreveu nele — não no fim do layer,
  porque os batches de um layer não são um bloco contíguo (um layer aninhado os
  parte, e um flush de atlas os parte de novo). Resolver duas vezes é inofensivo;
  o que importa é a ordem, e ela é garantida: o quad de composite pertence ao
  pass do **pai**, que é acrescentado depois. Um teste conta os resolves, porque
  um resolve faltando é invisível na asserção de estratégia e muito visível nos
  pixels.

A stack lê os attachments **do alvo que recebeu**, não do que pediu — um pool
que rebaixe o pedido produz um descriptor verdadeiro e uma promoção recusada, em
vez de um comando de stencil contra um framebuffer sem stencil.

O custo de CPU da seleção sparse é pago uma vez. O seletor só prefere sparse
depois de **medir** o encoding, e medir significa rasterizar; então o
`GlVectorPathRecorder` guarda o plano que mediu e o reusa quando o commit
chega, em vez de rasterizar o mesmo path duas vezes. O probe sparse só roda
quando o pass pode executá-lo.

## Gradientes no replay, de ponta a ponta

Fechado. O caminho completo, sem nenhuma API explícita: `DisplayList` com paint
de gradiente → player → `GpuRasterSink` → seletor → `GlVectorPathRecorder`, que
resolve a rampa por `GpuGradientCache` e monta
`GpuGradientBinding`/`GpuGradientShaderParameters` → shader sparse amostrando a
LUT. Linear, radial focal, `pad`/`repeat`/`reflect`.

Quatro decisões que valem registro:

1. **A rampa é resolvida no momento de gravar, não no de submeter.** Se o
   upload falhar ou o shader transform for singular, o draw precisa ser recusado
   *antes* de um comando entrar no stream ordenado — um submitter que
   descobrisse isso na hora do draw já teria emitido todo o resto do frame e não
   teria para onde recuar.
2. **A rampa é endereçada em espaço de target.** A origem do layer entra nas
   duas matrizes; sem isso um gradiente dentro de `saveLayer` seria avaliado em
   coordenadas de device enquanto seus pixels são escritos em coordenadas locais
   do layer, e a rampa deslizaria junto com a posição do layer. Uma cena de
   paridade cobre exatamente isso.
3. **Retângulo com gradiente vai pela rota de path.** O pipeline sólido modula
   uma cor de vértice e não tem onde pôr uma rampa; `GpuRasterSink` manda o
   retângulo pelo caminho de máscara, que é o que tem material de gradiente. A
   cobertura é a mesma dos dois jeitos — a área analítica do filler para um
   retângulo eixo-alinhado é a mesma quantidade que o `boxCoverage` calcula.
4. **O alpha do paint é ignorado, dos dois lados.** A rampa carrega o próprio
   alpha e o replay de CPU lê a rampa também; modular aqui escureceria duas
   vezes.

`GradientRasterSink` deixou de ser o portão do player para os sinks de GPU e
passou a ser declarado pelo `GpuRasterSink`, com a recusa movida para dentro.
Isso era necessário porque a resposta deixou de ser uma propriedade da classe:
um contexto OpenGL com o executor sparse desenha um gradiente e a mesma classe
sem ele não desenha. Imagens, glyph runs e composites de `saveLayer` recusam
nomeando a primitiva — os mesmos três que o renderer de CPU recusa.

## Cache de plano vetorial no caminho GL

`VectorPlanCache` — a LRU genérica que o agente do Direct3D 12 escreveu — foi
adotada pelo `GlVectorPathRecorder` sem nenhuma mudança na classe, como ele
previu. O que ela retém aqui é o `SparseStripDrawPlan`.

**Duas economias, e a segunda é a maior.** A óbvia é entre frames: um path
estático re-rasterizava a cobertura analítica inteira todo frame, que é
exatamente o custo que sparse existe para reduzir, pago repetidamente. A
específica deste recorder é *dentro* do frame: o seletor não prefere sparse
antes de ver quanto o encoding custa, e descobrir isso significa rodar o
encoder — então `probeSparseMetrics` rasteriza **todo** path candidato,
inclusive os que o seletor depois manda para o atlas denso ou para B. Com o
cache, o draw promovido não encoda duas vezes, e os *recusados* pagam a medição
uma vez por frame em vez de uma vez por consulta.

Isso substituiu um memo de entrada única que só cobria o par probe/commit — ele
não sobrevivia a um segundo path medido no meio, nem a uma fronteira de frame.

A chave guarda a transform e o clip em **espaço de target**, não os de device
que a request carrega: é o espaço em que o encoding é realmente construído,
então dois draws da mesma forma na mesma posição de device dentro de layers
posicionados diferente ficam em entradas distintas, como devem. `variant` fica
zero — a única outra entrada do encoding é o tamanho de página do atlas, que é
fixo pela vida do recorder e portanto não pode diferir entre duas entradas do
próprio cache dele.

Medido nesta máquina (Intel UHD, painel 256×256 com furo, mediana de 21 frames,
quatro execuções):

| Cena | Antes (cache limpo por frame) | Depois |
|---|---|---|
| estática | 1,66–1,92 ms | **0,95–1,18 ms** |
| deformando (offset sub-pixel por frame) | — | 1,25–1,66 ms |

Cerca de **40–45% do frame** numa cena estática. A linha deformando é honesta e
não melhora muito: por construção ela erra a chave todo frame, e o que sobra é
o ganho de o commit reusar o encoding do probe — que o memo antigo já dava. É o
mesmo formato do resultado do D3D12, onde estático caiu bem mais que deformando.

Os números ficam em `test/rendering/gpu/gl_vector_cost_test.dart`, atrás de
`DART_UI_GPU_BENCHMARK=1`, porque duração numa máquina compartilhada vira teste
instável ou sem sentido. O que é asserção roda sempre: `gl_device_test.dart`
conta hits e misses — cena estática encoda uma vez e acerta depois, cena
animada erra sempre mas **não cresce** (a LRU evicta, que é o motivo de ela ser
limitada), e dois layers de origens diferentes não compartilham entrada.

**Aproveitamento em B:** nenhum, de propósito. `CpuTessellatedPathCache` já
retém a malha por conteúdo, fill rule e tolerância — e a malha fica em
coordenadas *locais*, então ela sobrevive a uma transform animada, coisa que
uma chave com transform de device não faz. Trocar seria regressão.

## Semântica de clip: conferida, sem divergência

O agente do D3D12 achou uma divergência real no caminho compute: ele aplicava o
retângulo de clip **exato**, enquanto `ScanlineFiller` — e portanto o renderer
de CPU, o atlas denso e o encoder sparse — expande o clip para pixels inteiros
com `floor`/`ceil`. O corte exato é a resposta mais bonita e é a errada, porque
faz uma rota discordar de todas as outras.

O sparse do GL **não tem como divergir**: `SparseStripGenerator` *é* o
`ScanlineFiller` com outro sink, então herda o arredondamento em vez de
reimplementá-lo. E nada a jusante reaplica o clip — o executor sparse não seta
scissor, porque a cobertura que ele desenha já é zero fora do retângulo
expandido.

Isso é uma afirmação sobre o código; a medição que a sustenta são duas cenas de
paridade com **todas as bordas de clip fracionárias**, comparadas nos 25.600
pixels contra o renderer de CPU: **desvio 0**, incluindo o caso degenerado em
que o clip remove a forma inteira.

## Backdrop por tile: análogo já existente

O truque que o D3D12 adotou no compute — segmento à direita do tile que cobre a
altura inteira vira winding constante, e só span parcial é binnado e avaliado
exatamente — **já tem análogo no sparse, implementado desde o começo**: a
classificação por coluna do `SparseStripGenerator` transforma o interior em
registros de *fill* sem nenhum texel alpha, e só a borda vira strip. É o mesmo
princípio (não gastar dados no que é constante), expresso por coluna em vez de
por tile.

A outra metade do truque deles — evitar o *binning* dos segmentos — não tem
contrapartida porque sparse não tem etapa de binning: a lista de arestas ativas
do filler já só toca as arestas que cruzam a scanline atual. Registrado aqui
para não ser reinvestigado.

## O que continua seam explícito

- **O seletor decidir sparse por cruzamentos de tile**, não por bytes de
  upload — ver *A regra de custo*. É o que bloqueia a promoção hoje.
- **SIMD para o laço de área**, que é a diferença que a porta não apaga: em
  Rust os 4 pixels de um tile são uma instrução. Se Dart ganhar acesso a SIMD,
  a curva inteira se move.
- **Culling de geometria fora da tela** (`CulledWindings`, captive rows), que a
  porta omitiu de propósito: hoje o clip inteiro é passado como bbox, o que
  custa só para paths muito maiores que a superfície.
- **Franja analítica no cover de C.** Fecharia os 18 níveis restantes, e é um
  subsistema de geometria (offsetting de contorno, joins, caps, cover inset),
  não um ajuste de shader — ver a seção acima e a evidência de que o Impeller
  também não a tem. Mais amostras só encolhem o número por 1/N.
- **Gradiente em glifos e imagens.** Recusado por nome. Para imagem a display
  list não codifica a regra de combinação entre os pixels da imagem e a rampa;
  para glifo seria um segundo shader sobre o atlas de cobertura. Avaliado e não
  feito: o caso de uso real (texto com gradiente) é raro o bastante para não
  pagar um shader novo antes de haver quem peça, e a recusa nomeada já impede o
  desenho errado. O renderer de CPU recusa os mesmos dois.
- **Portar o layout sparse** para MSL. HLSL (Direct3D 12), WGSL/WebGL2 e
  SPIR-V (Vulkan) já foram feitos, com paridade medida em cada um; ver a seção
  do Vulkan mais adiante para como o SPIR-V é produzido sem `glslangValidator`.
- **D (compute) no OpenGL.** Continua plano e referência de CPU, sem executor
  nativo neste backend. O primeiro executor real de D é o de Direct3D 12,
  descrito abaixo.

## Vulkan: sparse strips em SPIR-V emitido em Dart

Estado em 23 de agosto de 2026. Opt-in por flag na abertura do device
(`enableExperimentalSparseStrips`); um device aberto sem ela não constrói
pipeline nenhum a mais, não expõe recorder nem telemetria, e o caminho denso de
produção continua sendo exatamente o que já existia — um frame sem draw
promovido grava **um** render pass, como sempre gravou.

### Como o SPIR-V é produzido, e por quê

Esta foi a decisão de projeto real do port, e ela **já tinha sido tomada** para
o renderer denso: `vulkan_spirv.dart` é um montador de SPIR-V escrito em Dart.
O port sparse segue esse caminho em vez de reabri-lo.

O argumento, resumido: `vkCreateShaderModule` aceita palavras SPIR-V e nada
mais. Transformar GLSL em SPIR-V exige `glslang` ou `shaderc` — biblioteca
nativa que este repositório não distribui, não consegue construir a partir do
Dart, e teria de encontrar na máquina de cada desenvolvedor e na CI. Sobram
duas opções honestas:

1. **Blob pré-compilado versionado.** É o que a maioria dos bindings faz, e é
   dívida pior que ausência: as palavras são ilegíveis, o GLSL que as produziu
   sai da árvore ou fica desatualizado, regenerar exige uma ferramenta que
   ninguém tem instalada, e nem um revisor nem um teste distingue um blob certo
   de um errado.
2. **Emitir o SPIR-V em Dart.** SPIR-V não é um alvo de compilador no sentido
   difícil — é um formato binário plano, regular e totalmente especificado, e
   estes shaders são aritmética em linha reta. O shader vira *Dart legível*,
   é regenerado a cada execução (nunca fica velho), não precisa de ferramenta
   nenhuma (Linux, macOS e Windows produzem as mesmas palavras) e é
   verificável sem GPU.

A escolha é a 2, e a verificação é em três camadas independentes: estrutural
sem GPU (magic, versão, id bound, contagem de palavras por instrução, ordem das
seções, decorações de descriptor set e offsets do bloco de push constant); o
próprio driver, que aceita ou recusa o módulo em `vkCreateGraphicsPipelines`; e
os pixels, contra o renderer de CPU.

**O que o port sparse acrescentou a essa decisão** é o único ponto em que ela
ficou sob pressão: o GLSL de referência tem `if`, e `SpirvBuilder` emite um
único bloco em linha reta, sem `OpSelectionMerge` e sem `OpPhi`. Três saídas,
e as duas adotadas foram adotadas por motivos diferentes:

1. **Modo de cobertura e modo de paint viram módulos separados** — quatro
   fragment modules (sólido/alpha × sólido/gradiente), exatamente como
   `vulkan_shaders.dart` já separa os três `GpuPipelineKind` e como o WGSL usa
   quatro entry points. O Vulkan assa o blend no pipeline de qualquer forma, e
   colocar o modo no mesmo objeto custa zero.
2. **Tipo e spread de gradiente viram `OpSelect`**, não módulos. São estado de
   material, não de batch; torná-los estado de pipeline transformaria quatro
   módulos em catorze e doze pipelines em quarenta e dois, todos construídos
   antecipadamente, para evitar um select aritmético num shader já dominado por
   dois fetches de textura.
3. Ensinar controle de fluxo ao `SpirvBuilder`. **Não feito**, e não por
   aversão: `OpSelect` é *suficiente* aqui porque nenhum desses desvios guarda
   efeito colateral ou laço — todos escolhem entre dois valores. No dia em que
   um shader precisar de laço, a resposta continua sendo um `OpLoopMerge` no
   montador e não uma dependência de `shaderc`.

A consequência a ter em mente ao ler o fragment shader: **os dois parâmetros,
linear e radial, são calculados para todo fragmento**, e o não escolhido
realmente divide por zero quando lê a geometria do outro tipo. Isso é seguro —
`OpSelect` não propaga nada do operando que descarta — e está anotado em cada
sítio em vez de ficar para ser redescoberto. O `sqrt` do discriminante recebe
`max(disc, 0)` pelo mesmo motivo: um NaN que só depois é descartado obriga o
leitor a provar que foi.

Divergências de linguagem tratadas explicitamente, iguais em espírito às do
WGSL: `mod(x, 2)` do GLSL é escrito como `x - 2*floor(x/2)` (um resto que
trunca em direção a zero espelharia a rampa `reflect` pelo lado errado), e o
`texelFetch` da página alpha é `OpImageFetch` sobre `OpImage` — sem sampler,
sem normalização, sem filtro entre a coordenada e o texel.

### O que muda em relação ao GL, e são quatro fatos do Vulkan

1. **Não existe `uYFlip` nem flip nenhum.** O NDC do Vulkan aponta y para
   **baixo** e a origem do framebuffer é o canto superior esquerdo, que já é a
   convenção da display list. Clip y é `y / height * 2 - 1`, a *mesma*
   expressão de x. Copiar a projeção do GL desenharia a cena correta de cabeça
   para baixo — que lê como bug de cena e não de backend.
2. **Não existe rebase de atributo.** `vkCmdDraw` tem `firstInstance`; cada
   comando é um draw só.
3. **Não existe uniform buffer.** Todo escalar é push constant: 112 bytes,
   contra os 128 que o Vulkan garante, escritos direto no command buffer, sem
   descriptor, sem alocação e sem sincronizar com o valor do frame anterior.
   Dois ranges disjuntos e em estágios diferentes — viewport no vertex, empurrado
   uma vez por pass; material no fragment, uma vez por comando.
4. **Dois descriptor sets, não dois bindings.** Página alpha e rampa de
   gradiente são ambos `COMBINED_IMAGE_SAMPLER` no binding 0 do seu próprio set.
   Não é estilo: `VulkanRenderDevice.createTexture` já aloca a cada textura um
   descriptor set de um binding, então um layout de dois sets de um binding
   permite ligar página e rampa **como elas já estão**, sem segundo pool, sem
   segundo layout e sem cópia de descriptor.

### Uploads, render passes e a ordem

Um `vkCmdCopyBufferToImage` **não pode** ser gravado dentro de um render pass.
O renderer denso monta todos os uploads do frame em um buffer e os grava numa
passada única antes do `vkCmdBeginRenderPass`; quando uma submissão sparse
roda, esse momento já passou. Reusar o staging denso significaria escrever por
cima de bytes cuja cópia foi gravada e ainda não executou. Então o driver
sparse tem staging próprio, grava as próprias cópias e barreiras quando o pass
abre, e só então abre um render pass **seu** — com o `loadRenderPass` que o
`VulkanPipelines` já constrói, compatível com o pass denso porque a
compatibilidade olha só formato e sample count do attachment.

Isso torna cada fronteira dense/vector um render pass a mais, e é o preço
honesto do interleave nesta API. Só quem pediu a rota experimental paga.

**Dois bugs reais foram encontrados por essa via, e os dois só aparecem com
dois draws promovidos no mesmo frame** — o que é exatamente o motivo de as
cenas de ordenação existirem:

- o cursor de staging voltava a zero no segundo pass, escrevendo por cima dos
  bytes de cobertura do primeiro antes de a cópia dele executar;
- o buffer de instâncias fazia o mesmo, com o segundo pass sobrescrevendo os
  quads do primeiro.

Ambos agora são arenas monotônicas por frame: o buffer que o frame supera é
aposentado (não liberado — cópias já gravadas o nomeiam por handle) e devolvido
no início do frame seguinte, depois do `waitIdle` do alvo. E a barreira antes
de uma cópia numa página já lida por um pass anterior deixou de ser
`TOP_OF_PIPE` — que não espera nada — para nomear o `FRAGMENT_SHADER`/
`SHADER_READ` que de fato precisa terminar antes (write-after-read).

### Paridade medida

Intel(R) UHD Graphics, Vulkan 1.4.323, driver 0x195bb0, offscreen com readback.

| Cena | Desvio |
|---|---|
| retângulo alinhado a pixel (só instâncias sólidas) | 0 |
| retângulo com bordas fracionárias (sólidas + página alpha) | 0 |
| quadrilátero diagonal (quase só strips de borda) | 0 |
| path auto-sobreposto, even-odd | 0 |
| paint translúcido, source-over | 0 |
| path com clip fracionário | 0 |
| gradiente linear pela LUT compartilhada | 1 nível em 106 de 1024 pixels |
| gradiente radial com foco, spread reflect | 1 nível em 15 de 1024 pixels |
| replay ordenado: path promovido sob/sobre batch denso | 0 |
| replay ordenado: dois paths promovidos | 0 |

O desvio de gradiente tem a mesma causa declarada no port do Direct3D 12 — a
CPU indexa a `GradientLut` e o shader **amostra** a mesma rampa com filtro
linear — e o número linear é o **mesmo 106** que o Direct3D 12 mediu na mesma
cena. Dois shaders escritos independentemente caindo nos mesmos 106 pixels é a
interpolação da rampa, não a aritmética de um backend.

Vale registrar um resultado que não era esperado: o retângulo de bordas
fracionárias tem desvio **0** aqui, enquanto a comparação *densa* do mesmo
backend (`vulkan_cpu_parity_test.dart`) precisa tolerar um nível nele. Não é
sorte. A rota densa avalia `boxCoverage` no fragment shader e pode desempatar
uma cobertura de exatamente 0,5 para o lado oposto ao da CPU; aqui o byte de
cobertura que o shader lê **é** o byte que o `ScanlineFiller` calculou. A
representação sparse remove a divergência em vez de tolerá-la.

### Validation layer: o que foi e o que não foi provado

Os testes abrem a sessão pedindo `VK_LAYER_KHRONOS_validation` e o último caso
de cada arquivo exige que ela não tenha reclamado. **Na máquina em que estes
números foram medidos a layer não está instalada** — há apenas o ICD da Intel,
sem SDK do LunarG. Então o que aquele teste provou aqui foi que pipelines, os
dois descriptor sets, os dois ranges de push constant e as barreiras de
cobertura desenham os pixels certos, e **não** que um validador os inspecionou.
Numa máquina com o SDK o mesmo teste verifica de fato e falha alto. A distinção
é impressa em vez de escondida, porque "validação passou" e "validação estava
ausente" não são a mesma afirmação. Esta é a lacuna a fechar quando houver uma
máquina com o SDK.

### Seletor, recorder e o que ainda é recusado

`vulkan_vector_path_recorder.dart` é o `d3d12_vector_path_recorder.dart` com uma
estratégia em vez de duas — este backend não constrói pipeline de compute, então
D não tem rota aqui e é recusado por nome em vez de oferecido e depois
descartado. Preparação de CPU apenas: um draw aceito é retido como comando
ordenado e executado depois, na ordem exata que a display list tinha, e uma
recusa não custa nada — o sink continua pelo atlas denso como se o recorder não
tivesse sido consultado.

Recusados por nome, hoje: **fill aliased** (cobertura sparse *é* antialiasing
analítico; usá-la para `antiAlias: false` suavizaria uma borda que a display
list pediu dura), **comando fora de ordem de batch**, **encoding vazio**, e
**gradiente**. Este último merece precisão: o shader SPIR-V desenha gradiente e
a tabela acima mede dois. O que falta não é o shader — é o seam, comum a todos
os backends, que resolve o gradiente de um `ReplayPaint` para uma LUT residente
durante o replay. Recusar no recorder mantém a recusa honesta em vez de adiar a
falha para a submissão, depois que trabalho denso já desenhou.

### Arquivos

`lib/src/rendering/gpu/vulkan/`: `vulkan_sparse_strips.dart` (SPIR-V dos cinco
módulos, layout de push constant, arenas de submissão), `vulkan_sparse_-`
`executor.dart` (política, sem API), `vulkan_sparse_driver.dart` (pipelines,
descriptor sets, staging, barreiras, render pass), `vulkan_vector_path_-`
`recorder.dart` (ponte do seletor), mais as adições em `vulkan_spirv.dart`
(`OpSelect`, comparações, `OpImageFetch`, `OpDot`, `OpTypeBool`),
`vulkan_bindings.dart` (`vkCmdDraw`) e `vulkan_backend.dart` (flag, caminhada
ordenada, seam explícito).

## Direct3D 12: sparse strips e o primeiro executor de D

Estado em 23 de agosto de 2026. Tudo opt-in por flag na abertura do device
(`enableExperimentalSparseStrips`, `enableExperimentalComputeTiles`); um device
aberto sem elas não compila shader nenhum a mais, não constrói PSO nenhum a
mais e não expõe recorder nem telemetria — o caminho denso de produção é
byte a byte o que já existia.

### Sparse strips (HLSL, vertex instanciado + pixel)

`d3d12_sparse_strips.dart` é `gl_sparse_strips.dart` transposto linha a linha,
porque é isso que torna a comparação entre os dois significativa. Mesma
instância de seis floats, mesmo quad de quatro vértices derivado do índice do
vértice, mesma leitura inteira da página alpha8 (`Load`, o equivalente de
`texelFetch`), mesma ordem premultiplicar-depois-cobrir para gradientes, mesma
LUT compartilhada.

Três coisas mudam, e as três são fatos da API:

1. **Não existe `uYFlip`.** O Direct3D escreve a linha 0 do render target no
   topo, então o único flip aritmético do vertex stage é a conversão inteira.
2. **Não existe rebase de atributo.** `DrawInstanced` tem
   `StartInstanceLocation`, que desloca o fetch por instância; cada comando é
   um único draw, sem re-apontar ponteiro de atributo como o GL 3.3 exige.
3. **Não existem uniforms.** Todo escalar é root constant (28 dwords em um
   `cbuffer b0`), e há duas descriptor tables de um descriptor cada — página
   alpha e LUT de gradiente não são adjacentes no heap do device.

O `D3d12SparseDriver` grava na mesma command list do frame e usa a mesma arena
de upload do frame ring: a geometria de instância é lida uma vez, e o tempo de
vida dela já é o da fence que libera o allocator. Recuperação de device loss
segue o padrão do `d3d12_device`: `markLost` faz o executor **esquecer** root
signature, PSOs e páginas em vez de liberá-las através de um device removido.

Paridade medida contra o renderer de CPU, offscreen com readback, Intel UHD
Graphics, feature level 12_1:

| Cena | Desvio |
|---|---|
| retângulo alinhado a pixel (só instâncias sólidas) | 0 |
| retângulo com bordas fracionárias (sólidas + página alpha) | 0 |
| quadrilátero diagonal (quase só strips de borda) | 0 |
| path auto-sobreposto, even-odd | 0 |
| paint translúcido, source-over | 0 |
| path com clip fracionário | 0 |
| gradiente linear pela LUT compartilhada | 1 nível em 106 de 1024 pixels |

O único desvio é o gradiente, e a razão está declarada no teste: a CPU indexa
a `GradientLut` e o shader **amostra** a mesma rampa com filtro linear, então
um pixel cujo parâmetro cai a meio texel de uma parada pode pegar a entrada
vizinha. Um passo de rampa é um nível nesta cena, e o canal alpha é exato em
todos os pixels.

### D (compute tile): o encoding não precisou mudar

Este é o primeiro executor nativo de D nesta arquitetura, e o resultado mais
útil é negativo: **o encoding de `ComputeTilePlan` não precisou de nenhuma
mudança para ser executável**. `segments`, `draws`, `bounds`, `bins`,
`references` e `commands` sobem para a GPU como os bytes que já são — cada um
já é exato, já é float32 ou uint32, já tem um stride que um `StructuredBuffer`
declara, e os bins CSR já carregam exatamente o que um dispatch precisa: um
comando por tile ocupado, em ordem, nomeando um intervalo contíguo de
referências. As únicas adições ficaram do lado do backend: o teto de tamanho
de tile que um thread group impõe e o layout do buffer de cobertura.

O shader (`cs_5_0`, `[numthreads(16,16,1)]`) é uma transcrição de
`ComputeTileCpuReference`: mesma rejeição de bounds semiaberta, mesma
classificação de aresta, mesmo `crossingX <= x`, mesma quantização inteira
`(covered * 255 + samples / 2) / samples`. Um grupo por comando, isto é, por
tile ocupado; `Dispatch(commandCount, 1, 1)` já pula todo tile vazio sem
argument buffer indireto — indireto só passa a ser a ferramenta certa quando o
binning também for para a GPU.

Root signature sem descriptor heap: seis SRVs e um UAV como **root
descriptors**, endereço direto, mais 8 root constants. O buffer de cobertura é
zerado por cópia de memória de upload antes do dispatch, porque o conteúdo
inicial de um recurso de default heap é indefinido e o shader só escreve os
pixels de tiles ocupados.

Paridade contra a referência de CPU, mesmo adaptador:

| Cena | Desvio |
|---|---|
| retângulo alinhado ao eixo | 0 |
| retângulo com bordas fracionárias | 0 |
| dois draws sobrepostos, compartilhando tiles | 0 |
| mesmo encoding com non-zero e even-odd | 0 |
| grade de tiles não quadrada com tile parcial | 0 |
| tile de 8 pixels, abaixo do thread group | 0 |
| quadrilátero inclinado | 16 níveis em 8 de 4096 elementos |
| curva achatada (centenas de segmentos) | 0 |

A tolerância declarada para geometria inclinada é **uma subamostra** — 16
níveis em uma grade 4×4 — e a razão é a única coisa que não dá para
transcrever: o Dart avalia `x0 + (y-y0)*(x1-x0)/(y1-y0)` em float64 sobre
entradas float32 e o shader avalia em float32. Para aresta alinhada ao eixo a
expressão colapsa em `x0` e as duas são exatas, que é por que as cenas
retangulares comparam em 0.

### D compõe de verdade: o pass de composição

O buffer por draw acima continua existindo — é o oráculo — mas não é o que
desenha. Existe um **segundo entry point** no mesmo HLSL, compilado como uma
unidade separada porque os dois declaram `u0` e um único source com dois
recursos no mesmo registrador é conflito que o compilador recusa:

| Entry point | Saída | Uso |
|---|---|---|
| `csTileCoverage` | `RWStructuredBuffer<uint>`, um uint por pixel **por draw** | diagnóstico; lido de volta na CPU e comparado com o oráculo |
| `csTileCoverageTexture` | `RWTexture2D<float>` do tamanho do alvo, um draw por dispatch | composição; nunca sai da GPU |

O laço de cobertura é escrito **uma vez** e compartilhado pelos dois, então a
paridade medida contra o oráculo vale para os dois.

Por draw composto:

1. a textura de cobertura vai para `UNORDERED_ACCESS`;
2. um dispatch escreve a cobertura **daquele** draw (root constant
   `uSelectedDraw`), o que é o que impede dois paths promovidos sobrepostos de
   lerem a cobertura um do outro;
3. ela vai para `PIXEL_SHADER_RESOURCE` — e essa transição **é** a
   sincronização de que a leitura precisa: sair de `UNORDERED_ACCESS` é
   ordenado depois de toda escrita do dispatch, então não há barreira UAV
   separada;
4. um único quad sobre os pixels do bounds do draw compõe, com o material e o
   blend daquele draw.

**A textura nunca é limpa entre draws**, e isso é seguro em vez de sorte: o
passo 4 desenha exatamente o retângulo que o passo 2 garante ter escrito
inteiro. O binning garante a primeira metade (um tile que intersecta o bounds
referencia o draw, e o dispatch escreve todo pixel de todo tile que referencia),
e `dispatchDrawCoverage` devolve esse retângulo justamente para que o chamador
honre a segunda.

**O quad de composição é um draw do pipeline sparse, não um shader novo.** Uma
instância alpha do sparse já é "amostre uma textura de um canal num pixel de
device e module um material por ela"; basta pôr `atlasOrigin` na origem do quad
para que a coordenada interpolada coincida com a coordenada de device. Por isso
`enableExperimentalComputeTiles` também constrói o pipeline sparse, e por isso
não existe uma segunda cópia da aritmética de premultiplicação/blend que os
testes de paridade prendem em zero.

Formato: `R32_FLOAT`, guardando `alpha / 255`. Quatro bytes onde um bastaria, e
a razão é garantia e não preferência — `R32_FLOAT/UINT/SINT` são os três
formatos que todo device Direct3D 12 precisa suportar para *typed UAV store*;
se `R8_UNORM` serve é uma capability que este backend não consulta. O valor
normalizado é o que um `R8_UNORM` daria, para que a composição de D e a de
sparse façam a mesma conta.

Paridade da composição, `DisplayList` real, 64×64, contra **duas** referências
— o oráculo de CPU composto com a mesma aritmética, e o rasterizador analítico:

| Cena | vs oráculo | vs CPU analítica |
|---|---|---|
| retângulo alinhado a pixel | 0 | 0 |
| retângulo com bordas em 1/4 e 1/2 pixel | 0 | 0 |
| path auto-sobreposto, non-zero | 0 | 0 |
| paint translúcido source-over | 0 | 0 |
| clip em pixel inteiro | 0 | 0 |
| clip com borda fracionária | 0 | **0** (era 153; ver abaixo) |
| curva achatada | 0 | **21** |
| dois draws promovidos, em ordem | 0 | 0 |
| draw promovido sob retângulo denso posterior | — | 0 |

**Zero contra o oráculo em todas.** Isso é o que prova o transporte: um quad na
origem errada, um texel lido errado, um UAV lido antes do dispatch terminar, uma
cobertura velha vazando, um material ou blend trocado — nada disso pode estar
"quase certo".

As duas colunas diferentes são reais e nomeadas:

- **21 níveis na curva**: D antialiasa por **supersampling** (grade 4×4) e o
  atlas denso e o sparse usam área exata do `ScanlineFiller`. Promover um draw
  para D muda seus pixels de borda em pouco mais de uma subamostra. É
  propriedade do algoritmo, não deste port.
- **O clip fracionário: fechado, e a causa não era antialiasing.** Media 153
  níveis. A hipótese era "falta antialiasar a borda do clip"; a medição disse
  outra coisa. `ScanlineFiller` — e portanto a CPU, o atlas denso e o encoder
  sparse — **expande o clip para pixels inteiros** antes de preencher. D estava
  aplicando o retângulo exato. Antialiasar a borda teria feito D discordar de
  *todas* as outras rotas, que é uma imagem pior e não melhor.
  `ComputeTileClipRounding.outwardWholePixel` (o padrão) adota a semântica do
  framework, e o desvio caiu para **0**. `ComputeTileClipRounding.exact`
  continua disponível para quem não está comparando com essas rotas.

### Ligação ao seletor, transacional

`D3d12VectorPathRecorder` implementa `GpuPathCommandRecorder`, faz só trabalho
de CPU e mantém sua própria lista ordenada de comandos — o
`GpuVectorCommandStream` ordena por render pass, e este device não tem pass
nenhum além da superfície (ele recusa `saveLayer` que precise de offscreen por
nome). No dia em que houver pool de layers, a lista vira o stream.

O `D3d12OffscreenTarget` intercala: para cada comando vetorial, emite o
intervalo denso que o precede, depois o comando, depois o resto. O clear e o
bind do render target acontecem na primeira emissão, antes do primeiro comando
vetorial. Recusa volta ao atlas denso sem alterar ordem, e
`RendererCapabilities.supportsCompute` passou a seguir a flag do device em vez
de ser constante — um seletor não pode escolher D num device que não tem o que
executá-la.

Medido por pixels contra a CPU, a partir de uma `DisplayList` real: path
antialiased grande promovido a sparse (0), path promovido coberto por um
retângulo denso desenhado depois (0), dois paths promovidos em ordem (0),
preenchimento aliased nunca promovido (0). O debug layer do Direct3D 12 não
reporta nenhuma mensagem de severidade ERROR ou CORRUPTION em nenhum dos três
passes — sparse, dispatch de compute com readback, e composição de compute com
as duas transições por draw.

Tanto sparse quanto D são oferecidos **por draw** e sob as mesmas duas
condições: `antiAlias` (as duas rotas produzem cobertura antialiasada, e usar
qualquer uma para um preenchimento aliased amaciaria uma borda que o display
list pediu dura) e ausência de gradiente (nenhuma das duas tem material de
gradiente resolvido neste caminho; o recorder não pode construir um binding sem
tocar o device). O que sobra vai para o atlas denso, sem alterar ordem.

### Custo medido neste hardware

O seletor decide por custo, então os números são medidos e não estimados.
Intel UHD Graphics, feature level 12_1, superfície 256×256, um painel
arredondado antialiased (232×216 de bounds, 32 segmentos depois do flatten),
mediana de 21 frames. `d3d12_vector_cost_test.dart` imprime esta tabela.

**Representação — o que cada rota entrega à GPU:**

| | bytes | observação |
|---|---|---|
| máscara densa | 50 112 | área do bounding box, um byte por pixel |
| sparse strips | **2 164** | 496 de alpha + 1 668 de instâncias; 2 draws, 1 página |
| compute tiles | 11 144 | segmentos, draws, bounds, bins CSR, referências, comandos, **listas de segmento por tile e backdrops** |

Sparse é **23×** menor que a máscara densa. O encoding de D cresceu de 6 176
para 11 144 bytes com o binning — é o preço explícito da otimização abaixo, e
continua **4,5×** menor que a máscara densa.

**O que o binning mudou, medido:**

| | antes | depois |
|---|---|---|
| segmentos percorridos por amostra | 32 (todos os do draw) | **1,54 em média** |
| entradas totais de segmento por tile | — | 346 em 224 referências |

Uma redução de **~21×** nos testes de aresta.

**Encode de CPU por frame:**

| | µs |
|---|---|
| sparse (`ScanlineFiller` + strips + plano) | ~980–1 050 |
| compute (flatten + binning de tiles e segmentos) | **~580–640** |

D continua custando **~1,6× menos CPU** que sparse mesmo depois de passar a
binnar segmentos (antes eram ~370–490 µs sem binning).

**Frame completo, acima de uma baseline que só limpa e faz readback**, mediana
de 21 frames com 5 de aquecimento descartados:

| Rota | estático — antes | estático — agora | deformando — antes | deformando — agora |
|---|---|---|---|---|
| atlas denso | 1,08–1,37 | 0,74–0,90 | 1,20–1,57 | 0,99–1,09 |
| sparse strips | 0,94–1,16 | **0,25–0,46** | 0,96–1,14 | **0,58–0,89** |
| compute tiles | 1,79–2,11 | **0,51–0,62** | 2,26–2,56 | **1,65–1,69** |

"antes" é a medição anterior ao binning e ao cache; "agora" inclui os dois. O
teste imprime também os acertos do cache em cada medição — 25 acertos e 1 erro
na cena estática, 0 e 26 na deformando — para que uma melhora seja atribuível ao
cache em vez de ao clima.

### Binning de segmentos por tile

A medição acima dizia que D era a rota mais cara apesar de gastar menos CPU, e
nomeava a causa: `containsPoint` percorria **todos** os segmentos do draw para
**cada subamostra** — 224 tiles × 256 threads × 16 amostras × 32 segmentos ≈ 29
milhões de testes de aresta para um painel. Não havia culling por tile.

O `ComputeTilePlan` agora carrega, por referência (tile, draw), uma lista CSR de
segmentos e um **backdrop**. O laço do shader lê só a lista.

O backdrop é a parte que é fácil errar, e é o motivo do aviso do Vello. Com raio
para +x, fixe um tile `T = [x0,x1) × [y0,y1)` e parta os segmentos pela extensão
em x:

| grupo | condição | contribuição |
|---|---|---|
| esquerda | `sxMax <= x0` | `crossingX <= x0 <= x`, nunca cruza — **descartar** |
| direita | `sxMin >= x1` | `crossingX >= x1 > x`, **sempre** cruza — depende só de y |
| meio | resto | avaliar por amostra — **binnar** |

Descartar o grupo da direita é o erro clássico: perde-se o winding e a forma sai
oca. O Vello resolve com backdrop acumulado por linha de tiles; aqui há um
refinamento que torna a decomposição **exata** em vez de aproximada: um segmento
à direita só vira backdrop constante quando **cobre a altura inteira do tile**
(`syMin <= rowTop && syMax >= rowBottom`). Um que cobre só parte dela faria o
backdrop depender de y, então é binnado no tile e avaliado exatamente. Os três
casos são mutuamente exclusivos e exaustivos, então a soma é o mesmo número do
laço bruto.

O backdrop guarda **dois** números: non-zero precisa do winding com sinal,
even-odd precisa da paridade da *contagem*, e uma soma com sinal igual a zero
esconde tanto uma contagem par quanto uma ímpar.

Isso é verificado **antes de qualquer GPU**:
`ComputeTileCpuReference.rasterizeDrawUsingSegmentBins` roda a versão binnada do
oráculo e `compute_tile_segment_bins_test.dart` exige igualdade byte a byte com
a versão bruta em oito cenas — retângulo mais largo que um tile, retângulo com
furo, even-odd, escada com arestas terminando dentro da linha de tiles, curva
achatada com transformação, forma cortada cujos segmentos passam de toda a
grade, três draws compartilhando tiles, e grade não divisível. É o tipo de erro
que produz uma imagem plausível, então ele é medido e não inspecionado.

Acumulação por difference array + prefix sum por linha de tiles, o que mantém o
custo proporcional aos tiles que cada segmento toca e não a todos os tiles do
draw.

### Cache de encoding retido

O atlas denso guarda a máscara por conteúdo; nenhuma das duas rotas
experimentais guardava nada, e por isso cena estática e cena deformando custavam
quase o mesmo para elas.

`vector_plan_cache.dart` é o análogo de `CpuTessellatedPathCache` generalizado
sobre o *valor* retido — `SparseStripDrawPlan` para uma rota, `ComputeTilePlan`
para a outra — porque as duas chaveiam nos mesmos fatos: path **por conteúdo**
(`Path` é imutável e tem hash pré-computado, então um path reconstruído idêntico
acerta), transform de device, clip, fill rule, tolerância, mais um `variant` que
o consumidor define — D põe ali o tamanho da superfície e do tile, porque um
plano binnado numa grade não pode ser usado em outra; sparse põe zero.

LRU com capacidade, não mapa ilimitado: a chave contém a transform de device,
então uma forma animada gera chave nova todo frame e um mapa sem limite cresceria
sem parar justamente na carga que o cache deveria ajudar. Limitado, essa carga
simplesmente erra — que é o custo de hoje — e a cena estática acerta.

O cache **não** retém recursos de GPU: um plano sparse em cache ainda sobe suas
páginas alpha e um plano de compute ainda sobe seus buffers. O que é economizado
é o encode de CPU.

A rota GL não foi tocada (território de outro agente). `VectorPlanCache` está em
`rendering/gpu/vector/` e é deliberadamente genérica sobre o valor: o
`GlVectorPathRecorder` pode adotá-la sem que nada mude aqui.

**Conclusão, e ela é legítima: neste hardware e nesta cena, sparse continua
ganhando de D.** Compute caiu de 3,5× para 1,3× o custo de sparse na cena
estática e de 2,4× para 2,2× na deformando — grande melhora, mas o pódio não
mudou. E o seletor por custo já faz a coisa certa: com `computeSegmentThreshold`
em 512, um painel de 32 segmentos nem chega a D.

Isso é uma cena de UI típica numa GPU integrada, que é o caso em que sparse é
imbatível: a cobertura analítica da CPU é barata quando o path é pequeno, e o
upload de 2 KB não pesa. O valor de D aparece em outra classe de cena, e vale
dizer qual:

- **muitos segmentos por pixel coberto** — SVG complexo, mapa, texto vetorizado
  em corpo grande — onde o `ScanlineFiller` da CPU cresce com o número de
  arestas e o binning faz D crescer só com as arestas *daquele tile*;
- **geometria deformando todo frame**, onde nenhum cache ajuda e o encode de
  D é ~1,6× mais barato que o de sparse;
- **CPU saturada**, onde mover trabalho para a GPU vale mesmo custando mais
  tempo de GPU;
- **paths muito grandes em área**, onde a máscara densa cresce com a área e o
  backdrop faz o interior de D custar zero segmento por amostra.

O que ainda falta em D, agora que o binning existe: binning na GPU (hoje é CPU),
scan/prefix, materiais de gradiente nesta rota, e um cache que retenha também os
buffers na GPU em vez de só o encoding.

**Aviso de medição:** o alvo offscreen lê os pixels de volta, então todo frame
termina em espera de fence e cópia da superfície inteira. Esse custo é igual
para as três rotas e por isso a tabela é relativa a uma baseline; o que sobra é
um **limite superior** honesto do custo da rota, não um timer de GPU. Um
`ID3D12QueryHeap` com timestamps é a medição a acrescentar quando estes números
começarem a decidir alguma coisa. Os testes de tempo ficam atrás de
`DART_UI_GPU_BENCHMARK=1` porque, rodando em paralelo com as outras suítes
Direct3D 12, eles levavam o adaptador integrado a resetar por timeout.
