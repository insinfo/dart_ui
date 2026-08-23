# Relatório POC-23 — Intel UHD e estratégias 2D A/B/C/D

Data da medição: 22 de agosto de 2026.

## Resposta curta

A GPU desta máquina suporta as quatro abordagens propostas.

- **A — atlas analítico:** é a melhor base para UI comum e já é o caminho de
  produção mais completo do `dart_ui`.
- **B — tesselação na CPU:** é especialmente boa para paths estáticos que
  podem permanecer em VBO/IBO. A POC confirmou o draw retido, mas a integração
  desse executor ao replay de produção ainda não foi feita.
- **C — stencil-then-cover:** funciona no hardware e o executor OpenGL real foi
  medido. Deve ser uma rota especializada para fills/clips arbitrários, não a
  rota padrão de toda primitiva.
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
2. **B como fast path retido:** usar para SVGs/ícones estáticos e paths convexos
   ou simples; cache por conteúdo, tolerância e fill rule.
3. **C como fallback especializado:** fills arbitrários, winding/even-odd e
   clips para os quais A/B não sejam adequados; agrupar clears e covers é a
   próxima otimização relevante.
4. **D como trilha moderna:** começar no Vulkan ou D3D12, com buffers de cena,
   flatten/binning/fine raster e composição em tiles. OpenGL compute serve à
   POC, mas Vulkan/D3D12 oferecem melhor modelo explícito de sincronização e
   recursos para o backend definitivo.

O seletor deve escolher por workload, não apenas por API disponível: frequência
de deformação, complexidade, sobreposição, estabilidade do cache, fill rule e
custo de upload determinam a abordagem vencedora.

## Artefatos

- `poc/poc_23_gpu_2d_strategies/bin/main.dart`: probe e benchmark executável.
- `poc/poc_23_gpu_2d_strategies/README.md`: comandos e definição de cada medida.

O código continua executável em Linux para conferir portabilidade, mas este
relatório e seus números de decisão referem-se ao Windows nativo, conforme o
foco definido para esta medição.
