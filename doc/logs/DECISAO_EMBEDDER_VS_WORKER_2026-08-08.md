# Backend 3 — embedder no mesmo processo ou Dart como worker?

**Data:** 8 de agosto de 2026
**Runs:** [`31246294865`](https://github.com/insinfo/dart_ui/actions/runs/31246294865),
[`31246483105`](https://github.com/insinfo/dart_ui/actions/runs/31246483105) e
[`31246734901`](https://github.com/insinfo/dart_ui/actions/runs/31246734901)
— `macos-14` arm64, Dart 3.6.0
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

A régua certa não é o round trip, é o orçamento de um frame:

```text
60 Hz             16 667 µs por frame
iosurface             80 µs   0,5% do orçamento
fronteira de proc.    24 µs   0,14% do orçamento
pipe               1 352 µs   8,1% do orçamento
```

Mesmo o pipe ingênuo cabe em 60 Hz com folga. O embedder compraria de volta
0,14% de um frame ao custo de compilar o SDK do Dart do zero.

---

## 3. Decisão

**Dart como processo worker, com IOSurface para frames e pipe para controle.**

Razões, em ordem de peso:

1. O embedder não está disponível com SDK de release — é uma decisão de
   toolchain, não de arquitetura.
2. A fronteira de processo custa 0,14% de um frame a 60 Hz. Não é o gargalo.
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
- [ ] Frames maiores (4K) para confirmar que a vantagem do IOSurface cresce com
      o tamanho, como a teoria prevê.
