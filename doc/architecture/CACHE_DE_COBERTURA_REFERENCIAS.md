# Cache de cobertura nas referências (Impeller, Flutter/flow, Vello, Skia)

> **Escopo.** Pesquisa factual sobre *se e como* os renderizadores de referência cacheiam
> cobertura (máscara de alfa por forma), motivada pela pergunta: por que as referências não
> fazem o que o `GpuMaskAtlas` do dart_ui faz (rasterizar a cobertura de um path uma vez na CPU
> e reusar a textura enquanto forma e transform não mudam)? A hipótese em avaliação era
> "pressão de memória em alvos mobile".
>
> **Método.** Leitura direta do código-fonte e da documentação nas cópias locais em
> `referencias/`. **Nada aqui vem de memória.** Todos os caminhos são relativos a
> `c:\MyDartProjects\dart_ui\`. Cada afirmação factual traz `caminho:linha`.
> Onde não achei evidência, está escrito "**não encontrei evidência**".
> Inferências minhas estão isoladas na seção 8 e marcadas como tal ao longo do texto.

Fontes lidas:

| Fonte | Caminho local |
|---|---|
| Impeller (renderizador atual do Flutter) | `referencias/engine-main/impeller/` |
| Flutter engine fora do Impeller (`flow/`, `display_list/`, `shell/`, `docs/`) | `referencias/engine-main/` |
| Vello (+ `sparse_strips`, `glifo`, `vello_encoding`) | `referencias/vello-main/` |
| Skia (Ganesh) — consultado para a pergunta 6 e como precedente direto | `referencias/skia/` |
| Framework Flutter (Dart) — apenas para docs de `RepaintBoundary`/`CustomPaint` | `referencias/flutter-master/` |

---

## 1. O Impeller cacheia cobertura de path em algum lugar?

**Resposta curta: não. A cobertura no Impeller é estritamente transitória — vive no
stencil/depth attachment dentro do render pass e é descartada explicitamente no fim dele.**

### 1.1 A cobertura é stencil dentro do frame

O Impeller usa *stencil-then-cover* para paths não convexos. O algoritmo está inline em
`DrawGeometry`:

- `referencias/engine-main/impeller/entity/contents/color_source_contents.h:142-148` — decide
  `is_stencil_then_cover` a partir do `GeometryResult::Mode` (`kNonZero` / `kEvenOdd`).
- `:150-193` — **"Stencil preparation draw"**: emite um draw com
  `options.blend_mode = BlendMode::kDestination` (não escreve cor) e
  `StencilMode::kStencilNonZeroFill` / `kStencilEvenOddFill`, usando o *clip pipeline*.
- `:195-205` — **"Cover draw"**: troca para `StencilMode::kCoverCompare` e desenha um
  `RectGeometry` sobre a área de cobertura.
- `:246-249` — comentário explícito: *"for sufficiently complex paths we may opt to use
  stencil-then-cover to avoid tessellation."*

A origem da técnica é creditada à Skia em `referencias/engine-main/impeller/docs/faq.md:234`
(*"Ideas such as stencil-then-cover that Impeller now uses originated from Skia"*).

### 1.2 O buffer de cobertura é explicitamente descartável

`referencias/engine-main/impeller/renderer/render_target.h:68-72`:

```cpp
static constexpr AttachmentConfig kDefaultStencilAttachmentConfig = {
    .storage_mode = StorageMode::kDeviceTransient,
    .load_action  = LoadAction::kClear,
    .store_action = StoreAction::kDontCare,
    ...
```

`StoreAction::kDontCare` = o conteúdo do stencil **não é preservado** ao fim do pass. E
`StorageMode::kDeviceTransient` é documentado em
`referencias/engine-main/impeller/core/formats.h:46-57`:

> *"Used by the device for temporary render targets. These allocations cannot be transferred
> from and to other allocations… These allocations reside in tile memory which has higher
> bandwidth, lower latency and lower power consumption. The total device memory usage is also
> lower as a separate allocation does not need to be created in device memory. Prefer using
> these allocations for intermediates like depth and stencil buffers."*

Ou seja: a cobertura do Impeller nem sequer chega à memória de dispositivo — por design ela
mora em *tile memory*. Não há textura de cobertura para cachear.

### 1.3 O Impeller não tem sequer como chavear um cache por path

- `referencias/engine-main/impeller/geometry/path.h` — **não encontrei** `unique_id`,
  `GetHash` ou qualquer identidade estável de conteúdo para `Path` (grep por
  `unique_id|GetHash|hash` retorna vazio neste arquivo).
- `referencias/engine-main/impeller/entity/` — os únicos mapas associativos são
  `content_context.h:776` (`RuntimeEffectPipelineKey` → pipeline) e os `backdrop_data_` de
  `display_list/canvas.h:267`. **Não encontrei evidência** de nenhum mapa `forma → textura`.

### 1.4 A geometria tesselada também **não** é cacheada entre frames

`referencias/engine-main/impeller/entity/geometry/fill_path_geometry.cc:46-49` chama
`Tessellator::TessellateConvex(...)` **dentro de `GetPositionBuffer`**, ou seja, a cada draw,
escrevendo num `HostBuffer` transitório (`:25`). O único "cache" do tesselador é uma tabela de
valores trigonométricos para círculos/elipses:
`referencias/engine-main/impeller/tessellator/tessellator.h:36-40` e `:318-321`
(*"Data for various Circle/EllipseGenerator classes, cached per…"*).

### 1.5 O que o Impeller **de fato** cacheia

| Item | Onde | Escopo/vida |
|---|---|---|
| Pipeline State Objects (variantes de shader) | `impeller/entity/contents/content_context.h:265-274` (*"used as a key for the per-pipeline variant cache"*), `impeller/renderer/backend/vulkan/pipeline_cache_vk.h`, `pipeline_cache_data_vk.h` | processo / disco |
| Atlas de glifos | `impeller/typographer/glyph_atlas.h:65-70`, `impeller/typographer/lazy_glyph_atlas.h:15-47` | entre frames, com reuso incremental |
| Reuso incremental do atlas de glifos | `impeller/typographer/backends/skia/typographer_context_skia.cc:494-558` (steps 1–4a: reusa `last_atlas`, faz append dos glifos novos, só recria se não couber) | entre frames |
| Render targets (texturas offscreen) | `impeller/entity/render_target_cache.h:13-20` — *"An implementation of the RenderTargetAllocator that **caches all allocated texture data for one frame**. Any textures unused after a frame are immediately discarded."* (`keep_alive_frame_count = 4` em `:19-20`) | pool de alocação, **não** de conteúdo |
| Samplers | `impeller/renderer/sampler_library.h:24` | processo |
| FBOs (GLES) | `impeller/renderer/backend/gles/texture_gles.h:141` | processo |
| Conversão YUV (VK) | `impeller/renderer/backend/vulkan/yuv_conversion_library_vk.h:43` | processo |
| Textura de backdrop, **dentro** do frame | `impeller/display_list/canvas.cc:1049`, `:1080`, `:1614` | um frame |

E a filosofia declarada no README: *"All shader compilation and reflection is performed offline
at build time. All pipeline state objects are built upfront. **Caching is explicit and under the
control of the engine.**"* — `referencias/engine-main/impeller/README.md:18-20`.

**Blurs**: `impeller/entity/contents/filters/gaussian_blur_filter_contents.cc` produz um
`Snapshot` (`impeller/renderer/snapshot.h:23-27`: *"Represents a texture and its intended draw
transform/sampler configuration"*) — é uma textura de frame, alocada pelo `RenderTargetCache`
de um frame. **Não encontrei evidência** de cache de blur chaveado por conteúdo entre frames no
Impeller.

---

## 2. O Flutter, fora do Impeller, cacheia? O `RasterCache`

**Sim — mas cacheia RGBA colorido de camadas/DisplayLists, não máscaras de cobertura. E, o
achado mais importante: o `RasterCache` está DESLIGADO quando o Impeller é o renderizador.**

### 2.1 Desligado sob Impeller (fato central)

`referencias/engine-main/shell/common/rasterizer.cc:765-772`:

```cpp
bool ignore_raster_cache = true;
if (surface_->EnableRasterCache()) {
  ignore_raster_cache = false;
}
```

E as três superfícies Impeller retornam `false`:

- `referencias/engine-main/shell/gpu/gpu_surface_gl_impeller.cc:170-172` → `return false;`
- `referencias/engine-main/shell/gpu/gpu_surface_vulkan_impeller.cc:299-301` → `return false;`
- `referencias/engine-main/shell/gpu/gpu_surface_metal_impeller.mm:354-356` → `return false;`
- Contraste: o default é `true` em `referencias/engine-main/flow/surface.cc:25-27`.

Mais: em builds "slimpeller" o `RasterCache` é removido do binário —
`referencias/engine-main/flow/compositor_context.h:198` (`NOT_SLIMPELLER(RasterCache raster_cache_)`),
macro em `referencias/engine-main/common/macros.h:8-18`, flag em
`referencias/engine-main/common/config.gni:35-37`. Todo o `flow/raster_cache.h` está dentro de
`#if !SLIMPELLER` (`referencias/engine-main/flow/raster_cache.h:8` e `:279-283`).

### 2.2 O que ele guarda

Camadas (`kLayer`, `kLayerChildren`) **e** DisplayLists/pictures (`kDisplayList`) —
`referencias/engine-main/flow/raster_cache_key.h:24`. O produto é um `DlImage` RGBA:
`referencias/engine-main/flow/raster_cache.cc:89-96` cria a superfície com
`SkImageInfo::MakeN32Premul(...)` e `skgpu::Budgeted::kYes`. Não é máscara A8.

### 2.3 Heurísticas de decisão (limiares reais)

**Para DisplayLists** (`referencias/engine-main/flow/layers/display_list_raster_cache_item.cc`):

- `:24-50` `IsDisplayListWorthRasterizing`:
  - `will_change == true` → **não cacheia** (*"If the display list is going to change in the
    future, there is no point in doing to extra work to rasterize."*, `:29-33`);
  - bounds vazios ou não-finitos → não cacheia (`:35-40`, via
    `RasterCacheUtil::CanRasterizeRect`, `flow/raster_cache_util.h:39-52`);
  - `is_complex == true` → cacheia sempre (`:42-46`);
  - senão: `complexity_calculator->ShouldBeCached(Compute(display_list))` (`:48-49`).
- Limiares de complexidade:
  - GL: `complexity_score > 200000u`, comentado *"Set cache threshold at 1ms"* —
    `referencias/engine-main/display_list/benchmarking/dl_complexity_gl.h:23-26`
  - Metal: idem, `200000u` — `.../dl_complexity_metal.h:23-26`
  - Naive (fallback): `complexity_score > 5u` — `.../dl_complexity.h:45-47`
- `:103-125` `PrerollFinalize`: só cacheia se **visível** e
  `accesses_since_visible > raster_cache->access_threshold()`.

**Contagem de frames estáveis**: `access_threshold` default = **3** —
`referencias/engine-main/flow/raster_cache.h:139-142`. Contador incrementado em
`MarkSeen` (`flow/raster_cache.cc:144-155`), só enquanto visível.

**Para camadas** (`referencias/engine-main/flow/layers/layer_raster_cache_item.cc:44-78`):

- não cacheia se há platform view, texture layer, ou se está culled (`:52-55`);
- `num_cache_attempts_ >= layer_cached_threshold_` → `kCurrent`; senão tenta cachear os
  *filhos* (`kChildren`) (`:57-77`);
- default do limiar de camada = `kMinimumRendersBeforeCachingFilterLayer` = **3** —
  `referencias/engine-main/flow/layers/cacheable_layer.h:35-38` +
  `flow/raster_cache_util.h:23-37`. O comentário explica o trade-off entre cachear a camada
  filtrada vs. cachear os filhos: *"Caching the layer itself avoids all of that … but can be
  worse than caching the children if the filter itself is not stable from frame to frame."*
- `OpacityLayer` nunca se auto-cacheia: `layer_cached_threshold = numeric_limits<int>::max()`,
  com o comentário *"the opacity_layer couldn't cache itself, so the cache_threshold is the
  max_int"* — `referencias/engine-main/flow/layers/opacity_layer.cc:12-15`.

### 2.4 Orçamento / limite

- **Throttle por frame**: `kDefaultPictureAndDisplayListCacheLimitPerFrame = 3` —
  `referencias/engine-main/flow/raster_cache_util.h:17-21`, com o comentário
  *"Generating too many caches in one frame may cause jank on that frame. This limit allows us
  to throttle the cache and distribute the work across multiple frames."* Aplicado em
  `flow/raster_cache.h:218-222` (`GenerateNewCacheInThisFrame`) e checado em
  `flow/layers/display_list_raster_cache_item.cc:158-161`.
- **Não encontrei evidência de um orçamento em bytes que force despejo** no `RasterCache`. Há
  apenas *medição* (`EstimatePictureCacheByteSize`, `EstimateLayerCacheByteSize` —
  `flow/raster_cache.cc:282-302`; métricas em `flow/raster_cache.h:62-92`) e um endpoint de
  serviço para consultá-la (`referencias/engine-main/docs/Engine-specific-Service-Protocol-extensions.md:185-199`).
  O comentário em `flow/layers/display_list_raster_cache_item.cc:150-155` fala em
  *"we shouldn't cache the current node if the memory is more significant than the limit"*, mas
  o código imediatamente abaixo (`:158-161`) checa apenas `GenerateNewCacheInThisFrame()` —
  isto é, o limite de 3/frame, não bytes.
- O `RasterCache` é reconhecido como caro em memória:
  `referencias/engine-main/shell/common/rasterizer.h:538-540` — *"This cache does not describe
  the entirety of GPU resources that may be cached. **The `RasterCache` also holds very large
  GPU resources.**"*

### 2.5 O que invalida

- **Despejo agressivo, todo frame**: `EvictUnusedCacheEntries()` remove **toda** entrada não
  vista no frame corrente — `flow/raster_cache.cc:214-232`, chamada em
  `flow/layers/layer_tree.cc:137`. Não é LRU com folga; é "não apareceu neste frame → morre".
- **Mudança de transform** (ver seção 5): a chave inclui a CTM.
- `Clear()` em perda de contexto GPU — `flow/compositor_context.cc:226`, `:233`.

---

## 3. O Vello cacheia alguma coisa?

**O modelo do Vello é re-encodar a cena por frame.** Há caches, mas nenhum de *cobertura
rasterizada de path*.

### 3.1 O modelo é per-frame

- `referencias/vello-main/doc/ARCHITECTURE.md:71-78`: `Scene` → `Encoding` (buffers linearizados
  de comandos de path, draw, transforms) → `Recording` (comandos de GPU) → `WgpuEngine`.
- `referencias/vello-main/vello/src/scene.rs:40-43`: *"Rendering from a `Scene` will **not**
  clear it, which should be done in a separate step, by calling `Scene::reset`. If this is not
  done for a scene which is retained (to avoid allocations) between frames, this will likely
  quickly increase the complexity of the render result…"* — ou seja, o padrão esperado é
  `reset()` + re-encode a cada frame; o `Scene` retido serve só para reaproveitar alocações.
- `referencias/vello-main/vello/src/render.rs:148`: `resolver.resolve(encoding, &mut packed)` é
  executado em cada `render_encoding_coarse`.
- A tese do projeto é justamente **evitar** texturas intermediárias:
  `referencias/vello-main/README.md:55-57` — *"In traditional PostScript-style renderers, some
  steps of the render process like sorting and clipping either need to be handled in the CPU or
  done through the use of intermediary textures. Vello avoids this by using prefix-sum
  algorithms…"*

### 3.2 Caches que existem

| Cache | Onde | O que guarda |
|---|---|---|
| Glyph **encoding** cache (não raster) | `referencias/vello-main/vello_encoding/src/glyph_cache.rs:18-26` | `Arc<Encoding>` do *contorno* do glifo — dados de path, não pixels |
| Ramp/gradiente | `referencias/vello-main/vello_encoding/src/ramp_cache.rs:25,47` | LUTs de gradiente |
| Imagens | `referencias/vello-main/vello_encoding/src/image_cache.rs:37` | atlas de imagens |
| Hinting instances | `referencias/vello-main/vello_encoding/src/glyph_cache.rs:324` (`MAX_CACHED_HINT_INSTANCES: usize = 8`) | instâncias de hinting |
| Pipeline caches | `referencias/vello-main/CHANGELOG.md:136` — *"Breaking: Support for pipeline caches. (#524)"* | PSOs |
| Gradient ramp cache (hybrid) | `referencias/vello-main/sparse_strips/vello_hybrid/src/gradient_cache.rs:18-31` | rampas, LRU com contagem máxima |
| `ImageCache` / `MultiAtlasManager` | `referencias/vello-main/sparse_strips/vello_common/src/image_cache.rs:46` (adicionado em `sparse_strips/vello_common/CHANGELOG.md:116`) | atlas multi-página |
| **Glyph atlas raster (glifo)** | `referencias/vello-main/glifo/src/atlas/cache.rs` | **bitmaps de glifos rasterizados** — o único cache de cobertura rasterizada em todo o Vello |

Política de poda do glyph *encoding* cache —
`referencias/vello-main/vello_encoding/src/glyph_cache.rs:94-112`:
`MAX_ENTRY_AGE = 64` frames, `PRUNE_FREQUENCY = 64`, `CACHED_COUNT_THRESHOLD = 256`,
`MAX_FREE_LIST_SIZE = 32`.

### 3.3 Status: explicitamente experimental / pendente

- `referencias/vello-main/README.md:40-47` — bloco `[!WARNING]`: *"Vello can currently be
  considered in an alpha state. In particular, we're still working on the following: …
  **GPU memory allocation strategy** (#366), **Glyph caching** (#204)."* Ou seja, no Vello
  principal (compute) o cache de glifos **ainda não existe**.
- `referencias/vello-main/glifo/README.md:31-34` — *"Glifo is under rapid development.
  Consider it experimental for now. Its goals are to: … **Cache those glyphs so that repeated
  renders of a glyph are fast.**"*
- `referencias/vello-main/glifo/src/glyph.rs:303-307` e `:941-945` — *"**Note: Atlas caching is
  currently highly experimental and not recommended for external use.**"*
- `referencias/vello-main/sparse_strips/README.md:3-9` — a nova implementação visa
  *"Handle a wider range of memory conditions (e.g., when less memory is available)"* e é
  *"**not yet suitable for production use**"*.
- `referencias/vello-main/sparse_strips/vello_cpu/CHANGELOG.md:87` e
  `sparse_strips/vello_hybrid/CHANGELOG.md:109` documentam a migração para `glifo` com um
  objeto `Resources` de caches persistentes de imagem e glifo.

**Não encontrei evidência** de qualquer cache de cobertura de *path arbitrário* (não-glifo) em
nenhum crate do Vello.

---

## 4. Há declaração explícita sobre memória, largura de banda ou GPUs móveis?

**Sim — mas quase nenhuma delas é o argumento "não cacheamos máscara porque mobile tem pouca
memória". O que existe é mais específico e, em geral, aponta na direção oposta.**

### 4.1 O que está escrito, literalmente

| # | Citação | Onde | O que realmente diz |
|---|---|---|---|
| A | *"These allocations reside in **tile memory** which has **higher bandwidth**, lower latency and lower power consumption. The total device memory usage is also lower… Prefer using these allocations for intermediates like depth and stencil buffers."* | `referencias/engine-main/impeller/core/formats.h:51-55` | Justifica manter a **cobertura em tile memory**, não em textura. É a declaração mais próxima de "por que não materializar a máscara" — mas o argumento é banda/latência/energia, não "pouca RAM". |
| B | *"Built to perform the best when using a modern graphics API like Metal or Vulkan … and when running on **mobile tiler GPUs** like the ones found in smartphones and AppleSilicon/ARM desktops."* | `referencias/engine-main/impeller/toolkit/interop/README.md:19` | Confirma que o alvo de design do Impeller é a GPU tiler móvel. Não menciona cache de máscara. |
| C | *"Trimming the content coverage by the coverage limit can **reduce memory bandwith**. But in cases where there are **animated matrix filters, such as in the framework's zoom transition**, the changing scale values continually change the source_coverage_limit… This leads to **non-optimal allocation patterns as differently sized textures cannot be reused**."* | `referencias/engine-main/impeller/entity/save_layer_utils.cc:74-83` | **A citação mais relevante do Impeller para o nosso caso.** Fala de banda de memória *e* do problema de escala animada gerando alvos de tamanho diferente a cada frame. Heurística: `kDefaultSizeThreshold = 0.3` (`:16`), i.e. se a diferença de tamanho for < 30 %, usa a cobertura transformada em vez da interseção, para permitir reuso de textura. |
| D | *"This cache does not describe the entirety of GPU resources that may be cached. **The `RasterCache` also holds very large GPU resources.**"* | `referencias/engine-main/shell/common/rasterizer.h:538-540`, `:556-558` | Reconhece o custo de memória do raster cache do Flutter. Não é específico de mobile. |
| E | *"Generating too many caches in one frame may cause jank on that frame."* | `referencias/engine-main/flow/raster_cache_util.h:19-20` | Custo é **jank de CPU/GPU no frame**, não memória. |
| F | *"…resources backing the retained fragments can be efficiently cached GPU-side **without hogging relatively scarce GPU memory**."* | `referencias/vello-main/doc/vision.md:40` | Vello: memória de GPU escassa é citada como dificuldade de *fragmentos retidos*, não como razão para não cachear cobertura. |
| G | *"…it is **more efficient to cache the glyphs** rather than re-rendering them each frame. That will **especially help on very low-spec GPUs (especially mobile phone which have high display dpi relative to available computing resources)**, but should also help especially with power even on more powerful devices."* | `referencias/vello-main/doc/roadmap_2023.md:90` | **Argumento invertido**: no Vello, mobile é razão **a favor** de cachear raster, não contra. |
| H | *"That has nontrivial cost in memory allocation and **bandwidth for texture copying** … but the impact of copying on total rendering time is not expected to be that bad."* | `referencias/vello-main/doc/roadmap_2023.md:34` | Sobre atlas de imagens; custo de banda considerado aceitável. |
| I | *"Desktop GPUs may benefit from a larger minimum … On **mobile GPUs, experiments have shown that keeping intermediate textures smaller is more important for both memory usage and performance**, even if it requires more render passes."* (`min_texture_size` default 512×512) | `referencias/vello-main/sparse_strips/vello_hybrid/src/scene.rs:165-172`, default em `:184-189` | Evidência empírica citada de que texturas intermediárias grandes são ruins em mobile. É sobre *layers*, não sobre cache de máscara. |
| J | *"Handle a wider range of memory conditions (e.g., when less memory is available)."* | `referencias/vello-main/sparse_strips/README.md:7` | Objetivo declarado do sparse-strips. |
| K | *"…very large glyphs consume **disproportionate atlas space**."* (`max_cached_font_size: 128.0`) | `referencias/vello-main/glifo/src/atlas/cache.rs:58-61`, default em `:64-72` | Limite de *tamanho* para cachear raster — orçamento de atlas, não RAM do dispositivo. |
| L | *"If we have MSAA to fall back on, paths are already fast enough that we really only benefit from atlasing when they are **very small**."* | `referencias/skia/src/gpu/ganesh/ops/AtlasPathRenderer.cpp:125-127` | Skia: quando o caminho direto já é rápido, materializar máscara **não compensa**. |

### 4.2 Veredito sobre o "folclore"

**Não encontrei, em nenhuma das fontes, uma declaração do tipo "não cacheamos cobertura de path
porque isso consumiria memória demais em dispositivos móveis".** O que existe é:

1. Impeller: a cobertura fica em **tile memory** justamente porque isso é mais barato em banda,
   latência, energia **e** memória total (citação A). O motivo declarado do Impeller como um todo
   é **jank de compilação de shader**, não memória —
   `referencias/engine-main/impeller/docs/faq.md:123-131`, `:202-208`.
2. Vello: mobile é usado como argumento **pró-cache** de glifos (citação G).
3. As restrições reais que aparecem no código são de **espaço de atlas** (K), **tamanho máximo de
   textura** e **thrashing sob transform animada** (C, e seção 6), não de RAM de dispositivo.

---

## 5. Dependência de resolução: um raster cacheado só vale para uma transform

Todas as fontes que cacheiam raster tratam isso do mesmo jeito: **a transform entra na chave**,
e o cache é desabilitado quando a transform é "instável" ou não-alinhada.

### 5.1 Flutter `RasterCache` — a CTM é parte da chave

`referencias/engine-main/flow/raster_cache_key.h:87-91`:

```cpp
RasterCacheKey(RasterCacheKeyID id, const SkMatrix& ctm)
    : id_(std::move(id)), matrix_(ctm) {
  matrix_[SkMatrix::kMTransX] = 0;
  matrix_[SkMatrix::kMTransY] = 0;
}
```

A translação é zerada (só ela é tolerada); **escala, skew e rotação entram na chave por igualdade
exata** (`Equal` em `:112-117` compara `lhs.matrix_ == rhs.matrix_`).
Consequências no código:

- `RasterCache::Draw` faz lookup com `RasterCacheKey(id, canvas.GetTransform())` —
  `flow/raster_cache.cc:180`. Escala diferente ⇒ *miss*.
- Como `EvictUnusedCacheEntries` mata tudo que não foi visto no frame
  (`flow/raster_cache.cc:214-232`), uma escala que muda a cada frame gera **entrada nova + despejo
  da anterior todo frame**.
- Há alinhamento a pixel físico: `RasterCacheUtil::GetIntegralTransCTM` /
  `ComputeIntegralTransCTM` (`flow/raster_cache_util.h:68-84`, `:99-102`) — *"Snap the translation
  components of the matrix to integers… **Any layers that participate in raster caching must align
  themselves to physical pixels even when not cached to prevent a change in apparent location if
  caching is later applied.**"* Aplicado em `flow/raster_cache.cc:43-47` (`draw`) e `:85-87`
  (`Rasterize`), e nas camadas (`flow/layers/display_list_layer.cc:118-119`,
  `flow/layers/color_filter_layer.cc:73-74`, `flow/layers/opacity_layer.cc:29-31`).
- **Não encontrei evidência** de quantização de escala nem de tolerância de escala no
  `RasterCache` do Flutter. É igualdade exata de `SkMatrix`.

### 5.2 Skia — o tratamento mais explícito que encontrei

`referencias/skia/src/gpu/ganesh/ops/SoftwarePathRenderer.cpp` (a CPU rasteriza a máscara de
cobertura, sobe para textura e cacheia — o análogo mais direto do nosso `GpuMaskAtlas`):

- `:284-287` — *"**To prevent overloading the cache with entries during animations we limit the
  cache of masks to cases where the matrix preserves axis alignment.**"*
  (`args.fViewMatrix->preservesAxisAlignment()`)
- `:304-316` — *"**Use the cache only if >50% of the path is visible.**"*
  (`unclippedArea > 2 * clippedArea` ⇒ desliga o cache) + rejeição se exceder `maxTextureSize`.
- `:319-357` — a chave: `boundsForMask->width()/height()`, `sx, sy, kx, ky` do view matrix
  (*"**We require the upper left 2x2 of the matrix to match exactly for a cache hit.**"*, `:321`),
  translação fracionária quantizada em 8 bits por eixo (`fracX/fracY & 0x0000FF00`, `:341-343`),
  bits de estilo, e `shape.writeUnstyledKey()`.
- `:332-337` — no Android framework, `fracX = fracY = 0`: *"Fractional translate does not affect
  caching on Android. This is done for **better cache hit ratio and speed**, but it is matching
  HWUI behavior, which doesn't consider the matrix at all when caching paths."*

E a documentação da flag que liga isso —
`referencias/skia/include/gpu/ganesh/GrContextOptions.h:225-229`:

> *"If true this allows path mask textures to be cached. **This is only really useful if paths are
> commonly rendered at the same scale and fractional translation.**"* (`fAllowPathMaskCaching = true`)

O mesmo padrão se repete em `referencias/skia/src/gpu/ganesh/GrBlurUtils.cpp:1162-1229`
(máscaras de blur): mesma frase sobre animações (`:1163-1165`), mesma regra dos >50 % visíveis
(`:1178-1190`), mesma exigência de 2×2 exata (`:1198-1213`), mesma quantização de 8 bits da
translação (`:1205-1208`), guardado por `SK_DISABLE_MASKFILTERED_MASK_CACHING`.

`referencias/skia/src/gpu/ganesh/ops/AtlasPathRenderer.h` (máscara de cobertura em atlas na GPU):
chave = `fPathGenID` + `fAffineMatrix[6]` (afim completa) + `fFillRule` (`:117-128`); rejeita
perspectiva (`:59`); e o cache é *"the locations of cacheable path masks **in the most recent
atlas**"* (`:115-116`), resetado a cada flush
(`referencias/skia/src/gpu/ganesh/ops/AtlasPathRenderer.cpp:279`, `:469`).

Máscara de clip cacheada da Skia: chave = `genID` do clip + `drawBounds` em espaço de
dispositivo — `referencias/skia/src/gpu/ganesh/ClipStack.cpp:792-809`; reuso permitido quando a
máscara maior contém o draw menor (`:811-816`).

### 5.3 Vello / glifo — escala absorvida no tamanho da fonte, casada por bits exatos

- `referencias/vello-main/glifo/src/atlas/key.rs:56-58`: `size_bits: u32` —
  *"Font size as f32 bits (**exact match, no quantization**)."*
- `referencias/vello-main/glifo/src/glyph.rs:1475-1480`: *"we need to try to **absorb** the font
  size into the draw transform, such that we can just use the font size to uniquely identify a
  glyph cache hit (for example, **if we draw a glyph at font size 12 with scale 2, it's the same
  as drawing the glyph at font size 24**)."*
- `referencias/vello-main/glifo/src/glyph.rs:1565-1591`: a absorção só ocorre se
  `is_positive_uniform_scale_without_skew()` (ou `..._without_vertical_skew()` no caso hinted);
  caso contrário o modo é `Direct` (sem absorção). E `:1566-1569`: *"…**any skewing factor is
  currently rejected for caching**."*
- Posição subpixel horizontal quantizada em 4 baldes:
  `referencias/vello-main/glifo/src/atlas/key.rs:20-24` (`SUBPIXEL_BUCKETS: u8 = 4`,
  *"Higher values improve rendering quality at the cost of more atlas entries per glyph"*) e
  `:85-87`.
- Desabilita cache para outlines com stroke e para paints não-sólidos —
  `referencias/vello-main/glifo/src/glyph.rs:389-396`.

**Comparação Impeller (glifos):** `TextFrame::RoundScaledFontSize` arredonda a escala para
1/100 e satura em 48 — `referencias/engine-main/impeller/typographer/text_frame.cc:53-61`
(*"An arbitrarily chosen maximum text scale to ensure that regardless of the CTM, a glyph will
fit in the atlas. If we clamp significantly, this may reduce fidelity but is preferable to the
alternative of failing to render."*). A chave do atlas é `ScaledFont{font, scale}` —
`referencias/engine-main/impeller/typographer/font_glyph_pair.h:37-52`. Posição subpixel
quantizada em 4 níveis (0, 0.25, 0.5, 0.75) —
`referencias/engine-main/impeller/typographer/text_frame.cc:63-77`.
**Este é o único lugar do Impeller onde existe cache por escala quantizada.**

---

## 6. Bônus — quando cachear é ruim, segundo as fontes

Evidência direta, em ordem de força:

1. **Animação de transform enche o cache de lixo.**
   `referencias/skia/src/gpu/ganesh/ops/SoftwarePathRenderer.cpp:284-286` e
   `referencias/skia/src/gpu/ganesh/GrBlurUtils.cpp:1163-1165`:
   *"To prevent overloading the cache with entries during animations we limit the cache of masks
   to cases where the matrix preserves axis alignment."*

2. **Só compensa se a escala for estável.**
   `referencias/skia/include/gpu/ganesh/GrContextOptions.h:226-227`:
   *"This is only really useful if paths are commonly rendered at the same scale and fractional
   translation."*

3. **Zoom animado quebra o reuso de textura e ainda paga a alocação.**
   `referencias/engine-main/impeller/entity/save_layer_utils.cc:74-83`:
   *"…in cases where there are **animated matrix filters, such as in the framework's zoom
   transition**, the changing scale values continually change the source_coverage_limit…
   **This leads to non-optimal allocation patterns as differently sized textures cannot be
   reused.**"* — e a mitigação é uma tolerância de 30 % no tamanho (`:16`, `:87-90`), justamente
   para *não* reagir a cada micro-variação de escala.

4. **Se o caminho direto já é rápido, materializar máscara não compensa.**
   `referencias/skia/src/gpu/ganesh/ops/AtlasPathRenderer.cpp:125-127`:
   *"If we have MSAA to fall back on, paths are already fast enough that we really only benefit
   from atlasing when they are very small."* Daí os limites: 256² px totais, 128² com MSAA,
   largura ≤ 1024 (`:122-132`, `:177-191`) — e a documentação em `AtlasPathRenderer.h:54-59`,
   `:79-83`.

5. **Se boa parte da máscara está fora da tela, não compensa.**
   `SoftwarePathRenderer.cpp:304-316` e `GrBlurUtils.cpp:1178-1190`: cache só se >50 % visível.

6. **Cachear demais num frame causa jank naquele frame.**
   `referencias/engine-main/flow/raster_cache_util.h:19-21` — daí o teto de 3 novos caches
   por frame.

7. **Se o conteúdo vai mudar, não cacheie.**
   `referencias/engine-main/flow/layers/display_list_raster_cache_item.cc:29-33`
   (`will_change`). Exposto ao usuário no framework:
   `referencias/flutter-master/packages/flutter/lib/src/widgets/basic.dart:872-878` —
   *"Whether the raster cache should be told that this painting is likely to change in the next
   frame. This hint tells the compositor **not to cache** the layer containing this widget
   because the cache will not be used in the future."* (e `:860-866` para `isComplex`).

8. **Cachear o resultado filtrado pode ser pior que cachear os filhos, se o filtro não é estável.**
   `referencias/engine-main/flow/raster_cache_util.h:23-37`.

9. **Glifos muito grandes não valem o atlas.**
   `referencias/vello-main/glifo/src/atlas/cache.rs:58-61` (`max_cached_font_size = 128.0`).

10. **Alinhamento a pixel é obrigatório sob risco de "pulo" visual.**
    `referencias/engine-main/flow/raster_cache_util.h:73-77` — o objeto precisa se alinhar a
    pixels físicos **mesmo quando não cacheado**, senão sua posição aparente muda ao entrar no
    cache.

---

## 7. Seção extra — o precedente mais próximo do `GpuMaskAtlas` é a Skia, não o Impeller

Vale registrar porque muda o enquadramento da discussão: **a abordagem do dart_ui não é
inédita nem contrariada pelas referências — ela é essencialmente o
`skgpu::ganesh::SoftwarePathRenderer` da Skia**, que:

- rasteriza a cobertura do path na CPU (`GrSWMaskHelper`,
  `referencias/skia/src/gpu/ganesh/GrSWMaskHelper.h:32-45`);
- sobe o resultado como textura A8 e a registra no `GrResourceCache` com uma `UniqueKey`
  (`SoftwarePathRenderer.cpp:361`, `:419-421`);
- chaveia por conteúdo da forma + 2×2 da matriz + translação subpixel
  (`SoftwarePathRenderer.cpp:319-357`);
- é acionado como **último recurso** da cadeia de path renderers
  (`referencias/skia/src/gpu/ganesh/GrDrawingManager.cpp:1035-1041`: só se
  `fPathRendererChain->getPathRenderer(...)` falhar e `allowSW`).

E a Skia tem ainda uma segunda variante, na GPU: `AtlasPathRenderer` —
*"Draws paths by first rendering their **coverage mask** into an offscreen atlas"*
(`referencias/skia/src/gpu/ganesh/ops/AtlasPathRenderer.h:41-42`), com cache
`(pathGenID, afim, fillRule) → posição no atlas` (`:117-130`), porém com vida de **um flush**
(`AtlasPathRenderer.cpp:279`, `:469`).

Ou seja: **o Impeller não faz isso porque escolheu stencil-then-cover + tile memory, não porque
alguém tenha documentado que cache de máscara é ruim em mobile.** A Skia faz, com guardas
rigorosas de escala.

---

## 8. Fatos com citação vs. inferências minhas

### 8.1 Fatos (todos com `caminho:linha` acima)

1. Impeller resolve preenchimento de path não-convexo com stencil-then-cover; a cobertura é
   escrita no stencil attachment e descartada (`StoreAction::kDontCare`) no fim do pass, em
   memória `kDeviceTransient` (tile memory). — `color_source_contents.h:142-205`,
   `render_target.h:68-72`, `core/formats.h:46-57`.
2. Impeller não tem identidade de conteúdo para `Path` nem mapa forma→textura em `entity/`.
   — grep vazio em `geometry/path.h`; `entity/contents/content_context.h:776` é o único mapa.
3. Impeller tessela por draw, sem cache entre frames. — `fill_path_geometry.cc:46-49`.
4. Impeller cacheia: PSOs, atlas de glifos (com reuso incremental), render targets por frame
   (pool), samplers, FBOs GLES, conversões YUV, textura de backdrop dentro do frame.
   — tabela na seção 1.5.
5. O `RasterCache` do Flutter está **desativado** sob Impeller
   (`EnableRasterCache() → false` nas três superfícies Impeller) e removido em builds
   `slimpeller`.
6. O `RasterCache` guarda imagens RGBA (`MakeN32Premul`) de camadas e DisplayLists — não
   máscaras.
7. Limiares reais do `RasterCache`: `access_threshold = 3`; ≤ 3 novos caches de DisplayList por
   frame; complexidade > 200000 (GL/Metal, "1 ms") ou > 5 ops (naive); `will_change` desliga;
   camadas exigem 3 renders estáveis; `OpacityLayer` nunca se auto-cacheia.
8. O `RasterCache` **não** tem orçamento em bytes que force despejo — só métricas; o despejo é
   "não visto neste frame ⇒ removido".
9. A chave do `RasterCache` inclui a CTM com translação zerada; escala/skew por igualdade exata;
   sem quantização de escala.
10. Vello re-encoda a cena por frame (`Scene::reset` + `Resolver::resolve`); cacheia encodings de
    glifo, rampas, imagens, hinting e pipelines — **nenhum cache de cobertura de path**.
11. O cache de raster de glifo do Vello (`glifo`) é declarado *"highly experimental and not
    recommended for external use"*; no Vello principal, glyph caching ainda está listado como
    trabalho em aberto no README.
12. `glifo` absorve escala uniforme no `font_size` e casa o `size_bits` por **bits exatos**;
    rejeita skew para cache; quantiza a posição subpixel em 4 baldes; não cacheia acima de
    128 ppem.
13. Impeller quantiza a escala de texto em 1/100 (`RoundScaledFontSize`) e satura em 48 — único
    cache por escala quantizada do Impeller.
14. **Não existe**, em Impeller, flow, display_list, docs do engine ou Vello, uma declaração de
    que cache de máscara/textura foi rejeitado por pressão de memória em mobile.
15. Onde mobile aparece: (a) Impeller declara tile memory como *vantagem* de banda/energia;
    (b) Vello cita mobile como razão **a favor** de cachear glifos; (c) `vello_hybrid` cita
    experimentos mostrando que texturas intermediárias menores são melhores em mobile.
16. Skia **faz** cache de máscara de cobertura por conteúdo+transform em dois lugares
    (`SoftwarePathRenderer`, `AtlasPathRenderer`) e documenta que isso *"só é realmente útil se
    os paths forem comumente renderizados na mesma escala e translação fracionária"*.
17. Skia desliga o cache de máscara quando a matriz não preserva alinhamento de eixos, para não
    "sobrecarregar o cache com entradas durante animações"; e quando <50 % da máscara é visível.
18. Impeller documenta explicitamente que escala animada (transição de zoom do framework) gera
    texturas de tamanhos diferentes a cada frame e impede reuso, e adota tolerância de 30 %.

### 8.2 Inferências minhas (NÃO estão escritas nas fontes)

> Marcadas como inferência: são deduções a partir dos fatos acima, não citações.

- **(I1)** A razão pela qual o Impeller não cacheia cobertura parece ser **arquitetural, não de
  memória**: o pipeline foi desenhado para que a cobertura nunca exista fora do tile
  (`kDeviceTransient` + `kDontCare`). Materializar uma máscara exigiria uma textura em memória de
  dispositivo — exatamente o que o comentário de `formats.h:51-55` diz que se quer evitar por
  banda/latência/energia. Mas **as fontes não conectam explicitamente esses dois pontos**.
- **(I2)** O Impeller provavelmente também não cacheia porque **não tem a infraestrutura**:
  sem identidade estável de `Path` (fato 2), não há chave possível. Isso é consequência de o
  Impeller receber `DlPath` por frame via DisplayList, não uma consequência declarada.
- **(I3)** O Flutter desligar o `RasterCache` sob Impeller sugere que a equipe julgou o ganho do
  cache de camadas menor que seu custo quando o renderizador já é AOT e barato por draw. **Não
  encontrei nenhum documento explicando essa decisão** — só o `return false`.
- **(I4)** O padrão convergente entre Skia (2×2 exata + 8 bits de translação), Flutter
  (`SkMatrix` exata, translação zerada) e glifo (`size_bits` exatos) indica que **quantizar
  escala é considerado arriscado demais para fidelidade** — todos preferem *miss* + re-raster a
  reusar uma máscara de escala aproximada. É uma leitura de padrão, não uma citação.
- **(I5)** O `GpuMaskAtlas` do dart_ui ocupa, no espaço de design, a mesma posição do
  `SoftwarePathRenderer` da Skia. A diferença é que na Skia ele é *fallback de última instância*
  (fato: `GrDrawingManager.cpp:1035-1041`) enquanto no dart_ui é o caminho **padrão** — essa
  comparação de papel é minha.
- **(I6)** A ausência de qualquer menção a "memória mobile" como argumento anti-cache sugere que
  a hipótese levantada é **folclore**, ao menos no que se pode apurar nestas fontes. Não é prova
  de inexistência (pode estar em design docs internos, PRs ou vídeos fora deste repositório).

---

## 9. Implicações para dart_ui

Contexto do nosso caso: **desktop, escala majoritariamente fixa, UI estática**, com medição de
1 rasterização a cada 26 frames.

1. **O desenho não contraria as referências; ele escolhe o outro lado de um trade-off que a
   Skia documenta.** `GrContextOptions.h:226-227` diz que cache de máscara de path *"só é
   realmente útil se os paths forem comumente renderizados na mesma escala e translação
   fracionária"*. Isso descreve literalmente uma UI de desktop estática. O que a Skia trata como
   condição rara (e por isso o `SoftwarePathRenderer` é fallback), nós temos como caso comum.

2. **O Impeller não é contra-exemplo do cache; ele é um renderizador com premissas diferentes.**
   Ele mira GPU tiler móvel (`toolkit/interop/README.md:19`) e paga a cobertura em tile memory a
   cada frame porque lá isso é barato. Em desktop, com GPU imediata e sem tile memory, esse
   argumento perde força — mas **isso é inferência (I1)**, não algo escrito.

3. **O risco conhecido (escala animada / zoom) é exatamente o risco que as referências
   documentam**, e vale copiar as três guardas delas:
   - **Guarda de estabilidade de transform** — Skia desliga o cache quando a matriz não preserva
     alinhamento de eixos, *"para não sobrecarregar o cache com entradas durante animações"*
     (`SoftwarePathRenderer.cpp:284-286`). Equivalente para nós: detectar escala/rotação variando
     entre frames e cair para o caminho direto (stencil/cover ou raster imediato) em vez de
     escrever a máscara.
   - **Guarda de visibilidade** — cache só se >50 % da máscara é visível
     (`SoftwarePathRenderer.cpp:304-316`). Evita pagar a escrita de uma máscara majoritariamente
     clipada.
   - **Guarda de tamanho** — Skia limita a 256²/128² px e 1024 de largura
     (`AtlasPathRenderer.cpp:122-132`) e o `glifo` corta em 128 ppem
     (`glifo/src/atlas/cache.rs:58-61`): acima de certo tamanho, a escrita da máscara custa mais
     que redesenhar.

4. **Tolerância de escala: as referências dizem "não".** Nenhuma delas interpola ou reusa uma
   máscara de escala próxima — Flutter compara `SkMatrix` exata, Skia exige a 2×2 exata, `glifo`
   compara bits do `f32`. Se quisermos uma tolerância no `GpuMaskAtlas`, estaremos fazendo algo
   que **nenhuma referência faz** (inferência I4). Uma alternativa que *tem* precedente é
   quantizar só a **translação subpixel** (Skia: 8 bits/eixo; Impeller e glifo: 4 baldes), e
   **snapar translação a pixel inteiro** como o Flutter faz com `GetIntegralTransCTM`
   (`flow/raster_cache_util.h:68-84`) — com a ressalva importante daquele comentário: o objeto
   precisa se alinhar a pixel **mesmo quando não cacheado**, senão a posição aparente muda no
   momento em que o cache entra em ação.

5. **Orçamento e despejo: o Flutter é um mau modelo, o `glifo` é um bom.** O `RasterCache` não
   tem orçamento em bytes e despeja tudo que não apareceu no frame — política agressiva demais
   para um atlas de máscaras. O `glifo` usa LRU por idade com parâmetros explícitos
   (`max_entry_age = 64` frames, `eviction_frequency = 64`, `max_cached_font_size = 128`;
   `glifo/src/atlas/cache.rs:64-72`) e mantém `pending_clear_rects` para zerar regiões liberadas
   antes de reuso (`:92-112`) — um modelo mais adequado ao `GpuMaskAtlas`.

6. **Throttle por frame vale a pena.** O comentário de `flow/raster_cache_util.h:19-20`
   (*"Generating too many caches in one frame may cause jank on that frame"*) e o teto de 3
   sugerem que, ao entrar numa tela nova com muitas formas, distribuir a rasterização por vários
   frames evita um pico de latência.

7. **Fica sem evidência**: nada nas fontes lidas afirma que a nossa abordagem é errada, nem que
   memória em mobile foi a razão de ninguém a adotar como padrão. A justificativa que existe é
   sobre **estabilidade de escala** — e é uma justificativa que o nosso alvo (desktop, escala
   fixa) satisfaz.
