# ADR 0001 — macOS: processo worker com IOSurface, não embedder no processo

**Status:** aceito
**Data:** 8 de agosto de 2026
**Contexto medido:** [`logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md`](../logs/DECISAO_EMBEDDER_VS_WORKER_2026-08-08.md)

## Contexto

O AppKit exige a primeira thread do processo e a VM do Dart não a entrega. Dos
três backends macOS validados, o `appkitNativeHost` — um `main()` em
Objective-C que possui a thread 0 por construção — é o recomendado por
robustez. Restava decidir como o Dart se relaciona com esse host:

1. **embedder no mesmo processo:** o host liga a VM do Dart e cria o isolate;
2. **Dart como processo worker:** o host fala com um processo Dart separado.

O roteiro deixava a escolha para "um spike separado". Este ADR registra o
resultado desse spike.

## Decisão

**Dart roda como processo worker.** O host nativo possui a janela e a thread 0;
os frames atravessam a fronteira por `IOSurface`; o pipe carrega apenas
controle e input.

## Justificativa

### O embedder não está disponível com SDK de release

O SDK distribui `include/dart_api.h` mas **nenhum `libdart` linkável**. Os
295–298 símbolos `Dart_*` existem dentro de `bin/dart` e `bin/dartaotruntime`.
Um `main()` nativo que referencia `Dart_Initialize` não linka:

```text
Undefined symbols for architecture arm64:
  "_Dart_Initialize", referenced from: _main
```

Aqueles cabeçalhos servem ao caminho inverso — código nativo carregado *dentro*
do processo Dart. Hospedar a VM exige compilar o SDK do código-fonte, o que é
uma dependência de toolchain com versionamento próprio por plataforma alvo.

Isso, sozinho, já decidiria. Mas o custo que a opção evitaria também foi medido,
porque uma decisão tomada só por indisponibilidade envelhece mal.

### O que a fronteira de processo custa

Mínimos medidos, `macos-14` arm64:

| tamanho | `pipe` | `shm` | `iosurface` |
|---|---|---|---|
| 480×320 | 975 µs | 831 µs | **66 µs** |
| 1920×1080 | 14 361 µs | 10 363 µs | **107 µs** |
| 3840×2160 | 56 092 µs | 45 202 µs | **130 µs** |

Uma ida e volta sem pixel nenhum custa 22–59 µs, ou ~0,2% de um frame a 60 Hz —
esse é o total que um embedder recuperaria na saída. Na entrada, input ponta a
ponta mede 824 µs de mediana, dos quais 95 µs (11,5%) são a fronteira; o resto
é entrega do WindowServer até a fila do AppKit, que nenhuma das arquiteturas
muda.

### Por que IOSurface e não memória compartilhada

`shm` fica apenas 1,2–1,4× à frente do pipe **em todos os tamanhos**. Se a
cópia fosse o custo dominante, essa razão cresceria com o frame. Ela não cresce,
o que prova que o gargalo é o `CGImage` reconstruído por frame mais o upload do
CoreAnimation — ambos por pixel, e ambos intocados pelo `shm`. O `IOSurface`
elimina os dois: a superfície é entregue ao layer uma vez e cada frame seguinte
apenas marca que o conteúdo mudou.

## Consequências

**Positivas.** Um erro no código de UI em Dart não derruba a janela. O host
fica pequeno o bastante para ser auditado linha a linha. O custo por frame é
praticamente independente da resolução.

**Negativas.** Existe um protocolo para manter e um lifecycle de dois
processos. Detecção de crash do host e restart passam a ser requisitos, não
detalhes — e foram medidos na run
[`31272239992`](https://github.com/insinfo/dart_ui/actions/runs/31272239992):

| verificação | resultado |
|---|---|
| Dart percebe o `SIGKILL` | 29 ms, status `-9` |
| A superfície sobrevive ao host | escrita posterior funciona |
| Host novo reanexa a **mesma** superfície | `SURFACE_OK 7` + `PRESENT_OK` |

O terceiro item é o que torna a recuperação barata: a janela é nova, o
framebuffer não. A superfície pertence ao Dart — o host é consumidor de pixels,
não dono deles — e o `SIGKILL` é deliberado, porque um teardown educado do
AppKit nunca foi o caso em dúvida.

**Dívida conhecida — resolvida em 8 de agosto de 2026.** A passagem usava
`IOSurfaceLookup`, deprecado. O substituto suportado passa um mach port, que um
pipe não carrega; o mecanismo de rendezvous resolve isso — o host faz
`bootstrap_check_in` com um nome derivado do próprio pid, o **nome** viaja pelo
pipe, e o pai manda o port. Sem API deprecada e sem restrição de ordem.
Medições e o mecanismo descartado em
[`logs/MACH_PORT_HANDOFF_2026-08-08.md`](../logs/MACH_PORT_HANDOFF_2026-08-08.md).

## Quando reabrir

- Alvo passar a 120 Hz **e** o orçamento por frame ficar apertado por outros
  motivos — aí 24 µs deixam de ser ruído.
- O projeto já precisar compilar o SDK do Dart por outra razão: o custo
  incremental do embedder cai muito.
- Input precisar de latência abaixo de ~100 µs ponta a ponta, o que exigiria
  atacar o trecho WindowServer→AppKit, não a fronteira.
