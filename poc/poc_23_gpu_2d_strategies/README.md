# POC-23 — Intel UHD e estratégias 2D A/B/C/D

Esta POC responde duas perguntas separadas:

1. quais APIs o runtime desta máquina realmente expõe;
2. quanto custa o trabalho já implementado no `dart_ui` para as abordagens
   A, B e C, além de um microkernel que confirma a execução compute de D.

Ela não apresenta o microkernel D como um rasterizador Vello. O binning de
tiles, a cobertura de curvas e a composição compute ainda precisam ser
implementados. Da mesma forma, B mede a tesselação e o cache na CPU porque o
executor GL de malha indexada ainda não existe.

## Executar

```powershell
dart run poc/poc_23_gpu_2d_strategies/bin/main.dart
```

Execução curta para desenvolvimento:

```powershell
dart run poc/poc_23_gpu_2d_strategies/bin/main.dart --quick
```

No WSL, o mesmo binário torna visível a diferença entre o fallback CPU e o
driver D3D12 do Mesa:

```bash
# caminho selecionado pelo ambiente
dart run poc/poc_23_gpu_2d_strategies/bin/main.dart --quick

# tentativa explícita do Mesa/D3D12 no WSLg
GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=Intel \
  dart run poc/poc_23_gpu_2d_strategies/bin/main.dart --quick
```

No ambiente observado, o Windows entrega OpenGL 4.6 e Vulkan 1.4 na Intel,
enquanto o Mesa/D3D12 do WSLg entrega OpenGL 4.1. Consequentemente, A/B/C
continuam possíveis nesse GL do WSL, mas D via OpenGL compute é recusado de
forma correta porque compute só entrou no core no OpenGL 4.3. Vulkan no WSL
também deve ser considerado acelerado apenas se `vulkaninfo` apontar a Intel
como `INTEGRATED_GPU`; `llvmpipe` é CPU.

Parâmetros:

- `--samples=N`: amostras usadas para obter a mediana;
- `--gpu-frames=N`: quadros sincronizados de cada carga GPU.

## O que cada linha mede

| Linha | Escopo real |
|---|---|
| A atlas cold | scanline CPU e escrita R8 para paths ainda não cacheados |
| A atlas warm | lookup retido do atlas, sem nova rasterização |
| B tessellation cold | flatten de curvas e ear clipping na CPU |
| B tessellation warm | lookup da malha indexada retida |
| C stencil plan | flatten e criação de clear/accumulate/cover |
| A GL | upload de 1.024 quads, um draw e `glFinish` |
| B GL | draw de uma malha indexada retida; executor local da POC |
| C GL | upload e três passes por path, seguido de `glFinish` |
| D GL compute | preenchimento RGBA8 por tiles 16×16 e `glFinish`; não é path raster |

Os números CPU e GPU não devem ser misturados num único ranking. Mesmo na
seção GPU, D é um limite inferior de compute, B e C resolvem 128 paths,
enquanto A resolve 1.024 retângulos analíticos. A POC torna a comparação
reproduzível sem esconder essas diferenças de trabalho.

O resultado completo coletado na Intel UHD desta máquina e as recomendações
de arquitetura estão em
[`doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md`](../../doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md).
