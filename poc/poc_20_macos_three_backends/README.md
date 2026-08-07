# POC-20 — matriz dos três backends macOS

Esta POC começa a separar explicitamente as três estratégias macOS do projeto:

1. SkyLight/CGS via Dart FFI;
2. AppKit via signal hijack, apenas para investigação;
3. executável Objective-C mínimo que possui a process main thread.

O primeiro artefato implementado é o witness do terceiro caminho:
[`native/minimal_appkit_host.m`](native/minimal_appkit_host.m). Ele não embute a
VM Dart ainda. Sua função é estabelecer o limite mínimo correto do host:
`main()` nativo, autorelease pool, `NSApplication`, delegate, janela e event
loop AppKit, todos sob ownership normal da thread principal.

Compilar e executar no macOS:

```bash
mkdir -p build
clang -fobjc-arc -Wall -Wextra -framework Cocoa \
  native/minimal_appkit_host.m -o build/minimal_appkit_host
./build/minimal_appkit_host --smoke-seconds 2
```

O smoke é aprovado somente se imprimir:

```text
MAIN_THREAD=1
WINDOW_ID=<id positivo>
```

Próximas etapas:

- extrair o backend SkyLight comprovado do probe para uma classe com teardown;
- encapsular o signal hijack como backend explicitamente `experimentalUnsafe`;
- escolher para o host `.m` entre embedder Dart no mesmo processo e protocolo
  IPC com um processo Dart worker;
- executar a mesma aplicação counter sobre os três contratos.

Arquitetura e critérios completos: [MACOS_TRES_BACKENDS.md](../../doc/MACOS_TRES_BACKENDS.md).

