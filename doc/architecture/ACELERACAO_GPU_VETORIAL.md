# Aceleração vetorial previsível: direção Vello + Impeller

**Estado em 22 de agosto de 2026:** formato sparse-strip, executor OpenGL
instanciado opt-in, tessellator inicial da abordagem B, seletor A–D e contrato
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

O primeiro consumidor real está em `gl_sparse_executor.dart`. Ele mantém VBO
instanciado de seis floats, programa GLSL 3.30/ES 3.00, páginas alpha8, uploads
parciais e comandos ordenados por batch/material/page-run. Os símbolos de
instancing são opcionais e não alteram o probe do renderer denso. A ativação
automática permanece bloqueada até integrar lifecycle ao `GlRenderDevice`,
clips/layers e benchmarks comparativos.

Próximos componentes são o shader strip/fill em GLSL, suas variantes HLSL,
MSL, SPIR-V e WGSL, e a integração do plano com `GpuRasterSink`.

### 3. Tesselação/AA geométrico

CPU tessela paths e envia triângulos; MSAA ou AA analítico resolve bordas.
Favorece geometria pequena/reutilizada e APIs como Metal/Vulkan/D3D12. Deve
usar o mesmo paint/layer contract, não um segundo renderer.

`CpuPathTessellator` implementa o primeiro subconjunto: um contorno simples,
fechado e formado por linhas, convexo ou côncavo, triangulado por ear clipping.
A malha fica em coordenadas locais (`Float32List` XY + `Uint32List`), portanto
uma transformação por frame não invalida o VBO. Curvas não achatadas, holes,
múltiplos contornos, abertura, auto-interseção e degeneração são recusados por
um motivo tipado. O seletor só escolhe B após elegibilidade explícita.

### 4. Tile/compute

Flatten, binning, prefix sums e rasterização em compute, semelhante ao Vello
clássico. Só é escolhido quando compute, storage buffers e sincronização são
confiáveis. WebGL2, drivers limitados e o fallback WSL continuam no modo 2.

### 5. Primitivas analíticas

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
diagnosticável para cada decisão. Até os shaders e benchmarks passarem os
critérios, sparse strips permanece experimental e a máscara densa continua o
fallback correto.
