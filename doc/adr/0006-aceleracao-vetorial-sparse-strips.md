# ADR 0006 — Sparse strips como próximo caminho vetorial GPU

**Status:** plano de submissão aceito; shaders ainda não são o renderer padrão

**Data:** 22 de agosto de 2026

## Contexto

O atlas alpha8 atual é correto e cacheável, mas seu custo inicial cresce com a
área do bounding box. Um renderer compute-first reduziria trabalho de CPU em
GPUs modernas, porém excluiria WebGL2 e criaria mais uma variável enquanto os
backends ainda precisam de paridade uniforme.

As referências locais mostram dois requisitos compatíveis: Impeller prioriza
pipelines previsíveis e recursos explícitos; Vello Hybrid mostra um formato
esparso que usa somente vertex/fragment shader e mantém uma etapa CPU.

## Decisão

O primeiro caminho vetorial novo será **híbrido por sparse strips**:

- `ScanlineFiller` continua produzindo a cobertura de referência;
- cobertura parcial é armazenada em strips de quatro scanlines;
- interior 255 vira fill sólido sem texel;
- o formato fica acima dos backends gráficos;
- cada backend implementará apenas upload, shader e draw;
- a máscara densa permanece fallback e cache para casos em que vence;
- compute/tile e tesselação são modos posteriores sob o mesmo contrato.

O protótipo não porta código Rust. Ele reimplementa o conceito usando os tipos,
fill rules, transformações e regras de cobertura do próprio `dart_ui`.

Sparse não substitui globalmente as abordagens A–D. O
`GpuPathStrategySelector` decide por draw entre primitiva/atlas analítico,
sparse, malha tessellated, stencil-then-cover e compute/tile. A decisão usa
capacidade, estabilidade, complexidade, auto-interseção, cache e custos medidos
de upload/instâncias/páginas/draws.

## Consequências

Positivas:

- piso de hardware baixo, incluindo APIs sem compute;
- custo intermediário próximo do perímetro para formas típicas;
- reconstrução CPU exata torna o formato verificável antes do shader;
- uma implementação comum pode alimentar GL, D3D, Metal, Vulkan e WebGPU.

Negativas:

- a geração inicial ainda usa CPU e não explora paralelismo de compute;
- há mais quads que numa máscara densa de um único bounding box;
- clips, layers, imagens e gradientes exigem novos buffers/shaders;
- a melhor rota depende da cena, então será necessário um modelo de custo.

## Evidência atual

Os testes em `test/rendering/gpu/vector` provam:

- reconstrução byte a byte contra o rasterizador analítico para retângulo,
  elipse, triângulo transformado e even-odd;
- nenhum trabalho para paths vazios/recortados;
- arena reutilizada entre fills;
- um retângulo 256 x 256 representado em menos de 1 KiB, contra 64 KiB densos.
- paginação alpha8, split de strips, ordem de composição, page runs e reuso de
  arenas no plano backend-neutral.

Isso prova o formato, não performance GPU. A promoção depende dos critérios em
`doc/architecture/ACELERACAO_GPU_VETORIAL.md`.
