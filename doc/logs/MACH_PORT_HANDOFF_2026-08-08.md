# Passagem de IOSurface por mach port — qual mecanismo ainda funciona

**Run:** [`31249520943`](https://github.com/insinfo/dart_ui/actions/runs/31249520943)
— `macos-14` arm64, Dart 3.6.0
**Código:** [`surface_port_probe.dart`](../../poc/poc_20_macos_three_backends/tool/surface_port_probe.dart),
[`mach_port_transfer.dart`](../../poc/poc_20_macos_three_backends/lib/src/mach_port_transfer.dart)

## O problema

`IOSurfaceLookup` é deprecado. O substituto suportado é
`IOSurfaceCreateMachPort` no produtor e `IOSurfaceLookupFromMachPort` no
consumidor — e essas duas funções não são a dificuldade. A dificuldade é que
**um mach port right não passa por um pipe**. Mover o right entre um processo
Dart e o host que ele criou é o problema inteiro.

A superfície do teste é criada **sem** `kIOSurfaceIsGlobal`
(`PROBE_SURFACE_GLOBAL=0`), então um sucesso não pode ser o caminho deprecado
disfarçado.

## Resultado

| mecanismo | veredito | evidência |
|---|---|---|
| `mach_ports_register` herdado pelo fork | **falha** | `SURFACE_PORT_SLOTS=3:1` — o slot sumiu |
| `bootstrap_register` | **funciona** | `SURFACE_PORT_OK bootstrap 480x320` |
| rendezvous via `bootstrap_check_in` | **funciona** | `SURFACE_PORT_OK rendezvous 480x320` |

`PRESENT_OK 1 surface-port` — apresentar pelo port funciona. E
`PRESENT_OK 2 surface` na mesma run: o caminho deprecado continua intacto.

## O achado: libxpc ainda limpa os registered ports, 12 anos depois

O caso `mach_ports_register` falhou exatamente como
[Sesek (2014)](https://robert.sesek.com/2014/1/changes_to_xnu_mach_ipc.html) e
[rdar://15417334](https://www.openradar.appspot.com/15417334) descreveram, e o
probe mediu isso diretamente:

```text
PROBE_REGISTERED_SLOT=2
PROBE_REGISTERED_STATUS=0          registro aceito pelo kernel
PROBE_REGISTERED_MASK_BEFORE=1     slot 0 ocupado
PROBE_REGISTERED_MASK_AFTER=5      slots 0 e 2   (1 | 4)
PROBE_REGISTERED_MASK_POSTSPAWN=1  slot 2 SUMIU
```

O bit desapareceu **no processo pai**, entre o registro e o `Process.start`.
Ou seja: o `atfork` handler do libxpc sobrescreve o array inteiro com seu
próprio bootstrap port, e o `Process.start` do Dart usa `fork()` — não
`posix_spawn`, que não roda atfork handlers.

O lado do kernel continua vivo e sem restrição no XNU atual: `ipc_task_init`
copia o array do pai para todo filho, `ipc_task_reset` não limpa, e o trap não
tem verificação de entitlement — o `KERN_SUCCESS` acima prova. **O mecanismo
morre inteiramente em espaço de usuário.**

O relatório original tinha 12 anos e nunca fora verificado em 14/15. Agora
está: continua valendo em macOS 14, arm64, em 2026.

## Recomendação: rendezvous

Ambos os que funcionam servem, mas o rendezvous é o que se escolhe:

- **`bootstrap_register` é deprecado desde 10.5.** Funcionar hoje não é
  argumento para construir em cima — é exatamente a dívida que este spike veio
  pagar. Fica registrado como funcionando, não como escolha.
- **O rendezvous não usa nada deprecado.** O host faz `bootstrap_check_in` com
  um nome derivado do próprio pid, imprime esse nome, e o pai faz `look_up` e
  manda uma mensagem. Um **nome** atravessa um pipe perfeitamente; só o filho
  precisa criar um receive right.
- **É o único sem restrição de ordem.** O canal sobrevive à superfície, então
  um resize é outra mensagem — não outro processo. Os outros dois exigem que o
  port exista antes do spawn.
- É a forma que o Chromium usa (`MachPortRendezvousServer`), com os papéis
  invertidos.

O `bootstrap_check_in` aceitou um nome que não está em plist nenhum
(`dart-ui.poc20.r.2121`), o que confirma que o launchd cria o serviço sob
demanda para um processo não-sandboxed. Sob App Sandbox isso vira
`1100 BOOTSTRAP_NOT_PRIVILEGED` — relevante quando houver empacotamento.

## O que ainda não foi medido

O custo por frame pelo caminho do port. Deveria ser idêntico aos 80–130 µs
medidos, porque o mecanismo muda apenas como a superfície é **adquirida** e o
`PRESENT` é o mesmo código — mas "deveria" não é medição, e a próxima é essa.

## Detalhe conhecido

Nem o host desaloca o send right recebido, nem o Dart desaloca o port da
superfície. É vazamento deliberado: soltar o último right de uma superfície que
o compositor está escaneando é uma falha muito pior do que um nome de port
vazado num processo que termina em segundos. Revisar quando isso virar
processo de longa duração.
