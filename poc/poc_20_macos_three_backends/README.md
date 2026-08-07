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

O segundo artefato é a política Dart em
[`lib/src/backend_policy.dart`](lib/src/backend_policy.dart). Ela torna a
seleção observável: cada tentativa registra aprovação ou rejeição e seu motivo.
O host nativo é o padrão; SkyLight exige permissão para API privada e ABI
validada; signal hijack exige seleção e permissão explícitas e nunca participa
do fallback automático.

O contrato reutilizável está em
[`lib/src/backend_contract.dart`](lib/src/backend_contract.dart). Além de
janela, framebuffer e input, ele fornece uma máquina de estados comum e tokens
geracionais: assim que shutdown ou falha começa, callbacks nativos antigos são
rejeitados antes de alcançar widgets Dart.

Validar a política em qualquer plataforma:

```bash
dart analyze
dart test
```

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
- ligar as implementações reais aos descritores e ao resultado da seleção;
- escolher para o host `.m` entre embedder Dart no mesmo processo e protocolo
  IPC com um processo Dart worker;
- executar a mesma aplicação counter sobre os três contratos.

Arquitetura e critérios completos: [MACOS_TRES_BACKENDS.md](../../doc/MACOS_TRES_BACKENDS.md).
