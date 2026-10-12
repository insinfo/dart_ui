# Metal no macOS 27 — vazamentos por falta de autorelease pool

Data: 2026-10-12
Máquina: Mac mini, Apple M4, macOS 27.2 (26B5101f)
Dart: 3.6.2
Commits: `2f49a66` (pools na abertura e nas liberações) e `2ebcae8` (buffers
do passe soltos no passe seguinte, e a asserção no workflow)

O job macOS do `framework.yml` roda os testes com
`OBJC_DEBUG_MISSING_POOLS=YES` desde que o caminho Metal existe, e o
`metal_present_probe.yml` roda as duas sondas de apresentação com a mesma
variável. Nenhum dos dois lia o que ela imprimia. Este documento registra o
que ela dizia, de onde vinha cada linha e o que foi corrigido.

## 1. O que a variável imprimia

Contagem de linhas `MISSING POOLS` por arquivo de teste, rodando um arquivo
por vez (`dart test <arquivo> -j 1`):

| Arquivo | Antes | Classes Metal mais frequentes |
|---|---|---|
| `metal_backend_test.dart` | 51 | 21 `AGXG16GDevice`, 7 `MTLCommandQueueDescriptorInternal` |
| `metal_cpu_parity_test.dart` | 62 | 30 `AGXG16GDevice` |
| `metal_offscreen_test.dart` | 54 | 22 `AGXG16GDevice` |
| `metal_device_test.dart` | 32 | (só descritores e `NSUserDefaults` da abertura) |
| `metal_window_target_test.dart` | 33 | idem |
| os outros três | 13 | nenhuma |

**Treze é a linha de base do processo**, e não é nossa: um teste sem uma
única chamada Objective-C (`test/foundation/diagnostics_test.dart`) imprime as
mesmas 13 linhas (`OS_os_log`, `_NSSwiftProcessInfo`,
`_NSSwiftCharacterSet`, `__NSCFString`). No runner do CI a linha de base tem
outra cara (`__NSCFString` e `__NSCFCharacterSet` na partida da VM), mas a
mesma natureza. A run `38220456481` tinha, além dela, 22 `AppleParavirtDevice`
e 12 `MTLCommandQueueDescriptorInternal`, que são os mesmos dois vazamentos
abaixo no device paravirtualizado.

Cada `AGXG16GDevice` vazado é uma referência ao `MTLDevice` que nunca é
devolvida. O device é único por processo, então a memória não cresce, mas o
device nunca chega a ser liberado e a contagem cresce a cada quadro.

## 2. Três causas

Encontradas com uma sonda passo a passo (abrir, compilar pipelines, criar alvo,
limpar, ler, liberar) e um breakpoint em `objc_autoreleaseNoPool` no lldb.

**2.1 `MetalGpu.open` sem pool.** `MTLCreateSystemDefaultDevice` e
`newCommandQueue` devolvem +1, e o código guardava exatamente isso, mas a regra
de nomes diz o que o *chamador* recebe, não o que o chamado autolibera no
caminho. O driver AGX autolibera o próprio device dentro da criação, e
`newCommandQueue` autolibera um `MTLCommandQueueDescriptor`.

**2.2 Nenhum `dispose` tinha pool.** O lldb mostrou o caminho:

```
objc_autoreleaseNoPool
AutoreleasePoolPage::autoreleaseNoPage
objc_autorelease
-[IOGPUMetalResource dealloc]
-[IOGPUMetalTexture dealloc]
-[AGXTexture dealloc]
-[AGXG16GFamilyTexture dealloc]
<Dart>
```

A última liberação de qualquer recurso Metal autolibera o device. Alvo
offscreen, cache de pipelines, renderer de malha, slots da janela e a própria
`MetalGpu` liberavam fora de pool.

Um detalhe que confunde a leitura: o segundo aviso da sonda aparecia em
`gpu.dispose()` **depois** da correção, com `objc_autoreleasePoolPush` no topo
da pilha. Não é um vazamento do push. É o valor de retorno autoliberado pela
otimização de TLS (`objc_autoreleaseReturnValue`) de uma chamada anterior feita
fora de pool, que só vira um autorelease de verdade quando o próximo pool é
empurrado. O culpado era o `pipelines.dispose()` logo antes.

**2.3 Os buffers do passe morriam na thread do Metal.** Depois de 2.1 e 2.2,
sete dos oito arquivos voltaram a 13. O de paridade ainda tinha 7, e a janela
real (`tool/metal_window_present_probe.dart`) tinha 16 em 8 quadros, **dois
por quadro**. Com `pthread_self` impresso ao lado de cada passo:

```
[0x16bfbf000] STEP render 0
objc[43899]: MISSING POOLS: (0x16c04b000) ... AGXG16GDevice ...
[0x16bfbf000] STEP read 0
```

A thread que vaza não é a do isolate, e o momento varia entre execuções:
às vezes durante `readPixels`, às vezes no `dispose`, às vezes no passe
seguinte. Dois por quadro são os dois `MTLBuffer` do passe (vértices e
índices). Eles eram soltos logo depois do encode, então a última referência
ficava com o command buffer, que a solta na thread de conclusão do Metal, e lá
não há pool.

A hipótese foi testada por experimento, não por pilha: o lldb deixou de
conseguir continuar este binário AOT depois do primeiro uso (o processo fica
parado em `continue`). Com os buffers guardados pelo alvo e soltos no início
do passe seguinte, dentro do pool dele, os 16 viraram 0.

## 3. Depois

| Medição | Antes | Depois |
|---|---|---|
| Linhas acima da base de 13, somadas nos 8 arquivos de `test/rendering/gpu/metal/` | 167 | **0** |
| Linhas de classe Metal (`AGX`, `MTL`, `IOGPU`) nesses 8 arquivos | ≥ 80 | **0** |
| `tool/metal_window_present_probe.dart`, 8 quadros | 16 | **0** |
| `tool/metal_present_probe.dart` | 2 | **0** (eram texturas da própria sonda) |

`METAL_WINDOW_PRESENT=PASS`, `METAL_PRESENT_PROBE=DONE ok=16 fail=0` e
`MACOS_POPUP=PASS` nesta máquina, na mesma sessão.

O que continua aparecendo e não é nosso: `CAMetalLayer`, `NSUserDefaults`,
`NSBundle` e `FPMTLMetricsMetricsBundleInternal` em threads do sistema durante
a sonda de `CAMetalLayer` sem janela.

## 4. A trava

`metal_present_probe.yml` ganhou o passo *Assert no Metal object leaks through
a missing pool*. Ele falha em qualquer linha `MISSING POOLS` cuja classe comece
com `AGX`, `MTL`, `IOGPU` ou `AppleParavirt`. Os prefixos são de propósito: a
linha de base da VM muda de cara entre versões do macOS, e uma lista de exceções
dela quebraria a cada atualização do runner. A lista das classes do driver, ao
contrário, só cresce quando alguém vaza um recurso.

O `framework.yml` não ganhou a mesma trava. Lá os testes rodam em paralelo e a
saída de stderr de um processo de teste não diz qual teste a produziu, então
uma falha apontaria para o job inteiro. A sonda roda um caminho só e diz
exatamente qual.
