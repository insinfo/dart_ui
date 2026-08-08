# Backend 3 — embedder no mesmo processo ou Dart como worker?

**Data:** 8 de agosto de 2026
**Runs:** [`31246294865`](https://github.com/insinfo/dart_ui/actions/runs/31246294865),
[`31246483105`](https://github.com/insinfo/dart_ui/actions/runs/31246483105),
[`31246734901`](https://github.com/insinfo/dart_ui/actions/runs/31246734901) e
[`31247641461`](https://github.com/insinfo/dart_ui/actions/runs/31247641461)
(varredura 480×320 / 1080p / 4K) — `macos-14` arm64, Dart 3.6.0
**Código:** [`transport_benchmark.dart`](../../poc/poc_20_macos_three_backends/bin/transport_benchmark.dart),
[`embedder_feasibility.c`](../../poc/poc_20_macos_three_backends/native/embedder_feasibility.c)

O documento de arquitetura dizia que a escolha entre as duas evoluções do
backend 3 sairia de "um spike separado". Este é o spike, e ele responde as duas
perguntas de formas diferentes porque elas são perguntas diferentes: a do
embedder tem resposta sim/não, a do worker tem resposta em microssegundos.

---

## 1. Embedder no mesmo processo: **indisponível com SDK de release**

A pergunta é se um `main()` nativo consegue hospedar a VM do Dart. Quem
responde é o linker, não a documentação.

O que o SDK distribui:

```text
include/  dart_api.h  dart_api_dl.c  dart_api_dl.h
          dart_native_api.h  dart_tools_api.h  dart_version.h  internal/
libdart*, *.a, *.dylib  →  nenhum
```

Os símbolos existem, mas dentro dos executáveis:

| binário | símbolos `_Dart_` exportados |
|---|---|
| `bin/dart` | 295 |
| `bin/dartaotruntime` | 298 |

E a tentativa de link:

```text
$ clang -I"$SDK/include" embedder_feasibility.c -o embedder_feasibility
Undefined symbols for architecture arm64:
  "_Dart_Initialize", referenced from:
      _main in embedder_feasibility-3c6711.o
ld: symbol(s) not found for architecture arm64
EMBEDDER_FEASIBLE=0
```

**Conclusão.** Os cabeçalhos servem para o caminho inverso — código nativo
carregado *dentro* do processo Dart, que resolve `Dart_*` do executável
hospedeiro. Hospedar a VM em um `main()` próprio exige `libdart` linkável, que
só sai de um build do SDK a partir do código-fonte. Isso não é "mais difícil":
é uma dependência de toolchain diferente, com versionamento próprio, para cada
plataforma alvo.

Vale registrar o que *não* foi testado: um SDK compilado do zero provavelmente
funciona — o Flutter faz exatamente isso. A afirmação aqui é estritamente sobre
o SDK de release.

---

## 2. Worker com transporte melhor: **medido**

Três transportes, o mesmo host, a mesma janela, o mesmo frame 480×320 BGRA
(614 400 bytes), 120 frames cada. O tempo é ida e volta completa: o Dart
escreve o frame, o host confirma que apresentou.

| transporte | mín (µs) | mediana (µs) | p95 (µs) | bytes pelo pipe |
|---|---|---|---|---|
| `ipc-baseline` (PING/PONG, sem pixels) | **24** | 77 | 356 | 5 |
| `pipe` (`FRAME` + octetos) | **1 352** | 2 698 | 4 989 | 614 400 |
| `shm` (mapeamento POSIX) | **987** | 1 679 | 3 872 | 20 |
| `iosurface` | **80** | 125 | 522 | 12 |

Medianas nas três runs, na mesma ordem de transporte:

| run | pipe | shm | iosurface |
|---|---|---|---|
| `31246294865` | 1 269 | 904 | 108 |
| `31246483105` | 2 671 | 1 554 | 245 |
| `31246734901` | 2 698 | 1 679 | 125 |

**As medianas variam por 2× entre runs — é hardware compartilhado — mas a ordem
e as proporções nunca mudaram.** O mínimo é a medida mais estável: é o custo
quando a máquina não está ocupada. Pelo mínimo, `iosurface` é 16,9× mais rápido
que o pipe.

### O que os números dizem

**`shm` melhora pouco (1,7×) e isso é a informação mais útil da tabela.** Se a
cópia fosse o gargalo, eliminar as duas cópias de 614 KB teria resolvido. Não
resolveu, porque o custo dominante não era copiar: era o host reconstruir um
`CGImage` por frame e o CoreAnimation subir os pixels para a GPU a cada
apresentação. `shm` remove a cópia e mantém as duas outras.

**`iosurface` ganha 10,9× sobre o pipe** porque ataca justamente isso: a
superfície é entregue ao layer **uma vez**, e cada frame seguinte só marca que
o conteúdo mudou. O compositor já está lendo aquelas páginas.

Ou seja, a intuição comum — "shm é o recurso clássico de performance" — está
certa sobre IPC genérico e incompleta sobre frames de display. Um `IOSurface`
**é** memória compartilhada; a diferença é que ela vem com formato de pixel,
lock e visibilidade para GPU e WindowServer.

### Quanto o embedder economizaria

O `ipc-baseline` é uma ida e volta que não carrega pixel nenhum: 24 µs no
mínimo, 77 µs na mediana. Esse é o piso que todo transporte paga e é **a única
parte que um embedder eliminaria**. Dos 80 µs do IOSurface, 24 são fronteira e
56 são o trabalho de apresentar, que o embedder também teria que fazer.

A régua certa não é o round trip, é o orçamento de um frame — e a resposta
depende do tamanho do frame, o que a primeira medição em 480×320 escondia.

```text
60 Hz             16 667 µs por frame

480x320    iosurface     66 µs   0,4%      pipe     975 µs    5,8%
1920x1080  iosurface    107 µs   0,6%      pipe  14 361 µs   86,2%
3840x2160  iosurface    130 µs   0,8%      pipe  56 092 µs  336,5%

fronteira de processo   22-59 µs  ≈0,2% em qualquer tamanho
```

**Correção de uma afirmação anterior:** eu havia escrito que "até o pipe cabe em
60 Hz com folga". Isso valia só em 480×320. Em 1080p o pipe consome 86% do
orçamento e em 4K ele estoura por 3,4×. A frase certa é: em 480×320 qualquer
transporte serve, e é exatamente por isso que medir só nesse tamanho não
decidiria nada.

O embedder, em qualquer tamanho, compraria de volta ~0,2% de um frame ao custo
de compilar o SDK do Dart do zero.

### Escala com o tamanho do frame

Mínimos, run [`31247641461`](https://github.com/insinfo/dart_ui/actions/runs/31247641461):

| tamanho | bytes/frame | `pipe` (µs) | `shm` (µs) | `iosurface` (µs) | ganho |
|---|---|---|---|---|---|
| 480×320 | 614 KB | 975 | 831 | **66** | 14,8× |
| 1920×1080 | 8,3 MB | 14 361 | 10 363 | **107** | 134× |
| 3840×2160 | 33 MB | 56 092 | 45 202 | **130** | 431× |

Esta é a tabela que decide, e ela diz três coisas:

1. **`iosurface` é praticamente plano.** O frame cresce 54× e o custo sobe 2×.
   Nada no caminho de apresentação é por pixel — a superfície já está no layer,
   e cada frame só avisa que o conteúdo mudou.
2. **`pipe` e `shm` escalam linearmente com os bytes** e ambos estouram o
   orçamento de 60 Hz já em 1080p (86% e 62%). Em 4K os dois entregam ~16 fps.
3. **A vantagem do `shm` sobre o `pipe` fica em 1,2–1,4× em todos os tamanhos.**
   Se a cópia fosse o custo dominante, essa razão cresceria com o tamanho. Ela
   não cresce — confirmando que o gargalo é o `CGImage` por frame mais o upload
   do CoreAnimation, ambos por pixel, que `shm` não toca.

---

## 3. Decisão

**Dart como processo worker, com IOSurface para frames e pipe para controle.**

Razões, em ordem de peso:

1. O embedder não está disponível com SDK de release — é uma decisão de
   toolchain, não de arquitetura.
2. A fronteira de processo custa ~0,2% de um frame a 60 Hz, em qualquer
   resolução. Não é o gargalo — o caminho por pixel é, e é ele que o
   `IOSurface` elimina.
3. O isolamento de crash é uma vantagem real: um erro no código de UI em Dart
   não derruba a janela, e o host é pequeno o bastante para ser auditado.

O que muda no código: `FRAME` continua existindo para comparação e para o caso
degradado, mas o caminho recomendado passa a ser `SURFACE` + `PRESENT`.

### Quando reabrir a decisão

- Se o alvo passar a ser 120 Hz **e** o orçamento por frame ficar apertado por
  outros motivos — aí 24 µs deixam de ser ruído.
- Se o projeto já precisar compilar o SDK do Dart por outra razão, o custo
  incremental do embedder cai muito.
- Se o input precisar de latência abaixo de ~1 ms de ponta a ponta; isso ainda
  não foi medido separadamente do frame.

---

## 4. Trabalho restante deste eixo

- [ ] Medir latência de **input** (host → Dart) isoladamente, do mesmo jeito.
- [ ] Múltiplos buffers (double/triple) e sincronismo com o refresh.
- [ ] Detecção de crash do host e restart, com a superfície sobrevivendo.
- [ ] Substituir `IOSurfaceLookup` (deprecado) por passagem de mach port via
      XPC — hoje o pipe não carrega um port right.
- [x] Frames maiores: confirmado. A vantagem vai de 14,8× em 480×320 para 431×
      em 4K, e o custo do `IOSurface` é praticamente plano.
- [ ] Medir com o display real a 60 Hz em vez de um loop livre: hoje o
      benchmark mede quanto custa apresentar, não se o compositor acompanha.
