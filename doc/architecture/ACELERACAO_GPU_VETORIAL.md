# Aceleração vetorial previsível: direção Vello + Impeller

**Estado em 22 de agosto de 2026:** formato sparse-strip, executor OpenGL
instanciado opt-in ligado ao device real, tessellator com curvas/cache da
abordagem B, plano stencil-then-cover da abordagem C, seletor A–D e contrato
GPU de gradientes implementados e testados. O renderer padrão ainda usa o
atlas denso enquanto os novos caminhos acumulam paridade e benchmarks.

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

Os próximos componentes são propagar clip/layer/material do replay até essa
entrada explícita, comparar pixels em framebuffer real e portar o layout para
HLSL, MSL, SPIR-V e WGSL. O shader GL experimental já consome a mesma
`GpuGradientBinding`/`GpuGradientShaderParameters` do contrato comum: linear,
radial/focal e pad/repeat/reflect amostram a LUT straight-alpha, premultiplicam
e só então aplicam a cobertura sparse. Binding e parâmetros de gradientes
diferentes, texture name zero e scalars que deixam de ser finitos ao estreitar
de `double` para float32 são recusados antes do pass. Isso impede que valores
finitos em Dart virem `Inf` silenciosamente no shader.

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
ao replay continua pendente.

### 5. Tile/compute

Flatten, binning, prefix sums e rasterização em compute, semelhante ao Vello
clássico. Só é escolhido quando compute, storage buffers e sincronização são
confiáveis. WebGL2, drivers limitados e o fallback WSL continuam no modo 2.

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

## Critérios para promover sparse strips a produção

- paridade CPU/GPU em solid, gradiente, imagem, clips e layers;
- nenhum shader compilado no frame;
- arenas estabilizadas sem alocação por draw em steady state;
- medição separada de geração CPU, upload, GPU e apresentação;
- recuperação de device loss e invalidação por geração;
- ganho comprovado sobre máscara densa em cenas reais;
- ausência de regressão no Linux sem WSL e em GPUs sem compute.

`GpuPathStrategySelector` já materializa essa política e produz uma razão
diagnosticável para cada decisão. `GpuPathWorkloadBuilder` agora obtém do
`Path`, do transform, do clip, da inspeção de tesselação e das métricas sparse
um workload coerente para esse seletor. `GpuPathPlanningTelemetry` já observa
o replay real, inclusive o hit efetivo do atlas, e registra o candidato
A/sparse/B/C/D; por contrato, `executedStrategy` continua sendo o atlas denso.
Falhas do planejamento são contidas e nunca quebram o frame. Até dispatch,
paridade em framebuffer e benchmarks passarem os critérios, os novos caminhos
permanecem experimentais e a máscara densa continua o fallback correto.
