# macOS — estratégia de três backends

## Decisão

O projeto manterá três implementações macOS atrás do mesmo contrato de janela,
input, apresentação e lifecycle. Elas não são três nomes para a mesma técnica:
cada uma tem ownership de thread, risco e finalidade diferentes.

| Backend | Processo principal | API de janela | Main thread | Uso pretendido |
|---|---|---|---|---|
| `skylight` | Dart standalone | SkyLight/CGS privada | não exige thread 0 no caminho medido | laboratório avançado e fallback controlado |
| `appkitSignal` | Dart standalone | AppKit por ObjC runtime | sequestrada por sinal | pesquisa e comparação; nunca default |
| `appkitNativeHost` | executável `.m` | AppKit normal | possuída desde `main()` | caminho recomendado para robustez |

Distribuição pela App Store não decide esta matriz. Os critérios são correção,
recuperação após falha, compatibilidade por versão e capacidade de teardown.

## Contrato comum

O código de widgets não pode conhecer qual estratégia está ativa. O adaptador
macOS deverá fornecer, no mínimo:

```dart
enum MacosBackendKind { skylight, appkitSignal, appkitNativeHost }

abstract interface class MacosWindowBackend {
  MacosBackendKind get kind;
  MacosBackendCapabilities get capabilities;

  Future<void> initialize();
  Future<MacosWindow> createWindow(MacosWindowOptions options);
  Stream<MacosInputEvent> get inputEvents;
  Future<void> present(MacosWindow window, MacosFrame frame);
  Future<void> closeWindow(MacosWindow window);
  Future<void> shutdown();
}
```

O contrato concreto deve incluir tokens geracionais para rejeitar callbacks
tardios, estados explícitos (`new`, `initializing`, `running`, `stopping`,
`stopped`, `failed`) e shutdown idempotente.

O contrato, a máquina de estados e os testes dessas invariantes agora vivem em
[`poc/poc_20_macos_three_backends/lib`](../poc/poc_20_macos_three_backends/lib).
O estado inicial concreto chama-se `created` (equivalente ao `new` conceitual
acima, que é palavra reservada em Dart).

## Backend 1 — SkyLight/CGS

### Evidência já confirmada

- `SLSMainConnectionID` fora da main thread;
- janela via `SLSNewWindow`;
- pixels via `SLWindowContextCreate`/Core Graphics;
- porta via `SLSGetEventPort` + `CFMachPort`;
- input direcionado com `SLEventPostToPid`;
- três eventos obrigatórios no CI: `[10, 11, 5]`.

### Regra de consumo medida

No cliente CGS mínimo, cada mensagem da Mach port deve consumir um evento. A
leitura adicional usada para procurar `null` bloqueou; uma leitura por mensagem
entregou key-down, key-up e mouse-move.

### Trabalho restante

- extrair o código de `probe.dart` para tipos pequenos com ownership explícito;
- invalidar e liberar source, Mach port, callbacks, regions, contexts e janelas
  em ordem inversa;
- input físico, IME, acessibilidade, clipboard, cursores e drag-and-drop;
- reconciliação após Spaces, fullscreen, monitores, sleep/wake e WindowServer
  restart;
- tabela de símbolos/ABIs por versão do macOS e falha rápida quando incompatível.

## Backend 2 — AppKit com signal hijack

### O que ele demonstra

O processo Dart mantém a thread 0 estacionada no launcher. O probe instala
`CFRunLoopRun` como handler de `SIGUSR2`, sinaliza a thread principal e passa a
enfileirar trabalho AppKit nela. Isso já criou uma `NSWindow` real e manteve o
runtime Dart ativo.

### Por que é experimental e inseguro

- `CFRunLoopRun` não é async-signal-safe;
- o handler não estabelece um frame normal de entrada do AppKit;
- `[NSApp run]` e alguns pumps produziram traps/crashes;
- shutdown usa `_exit`, não unwind normal;
- bibliotecas do processo podem disputar o mesmo sinal;
- não há contrato do Dart que preserve o estado estacionado da thread 0.

Esse backend deve exigir opção explícita, emitir diagnóstico visível e nunca
ser escolhido automaticamente. Seu valor é comparar comportamento AppKit e
testar APIs enquanto o SDK não oferece takeover suportado da process main
thread.

## Backend 3 — host Objective-C mínimo

### Limite correto

O executável `.m` é o `main()` real. Ele cria `NSApplication`, instala delegate,
abre a janela e entra em `[NSApp run]` normalmente. Carregar uma dylib `.m` por
FFI dentro do executável Dart **não** resolve o problema: o código continuaria
sem possuir a thread 0 desde o início do processo.

O witness inicial está em
[`poc/poc_20_macos_three_backends/native/minimal_appkit_host.m`](../poc/poc_20_macos_three_backends/native/minimal_appkit_host.m).
Ele já inclui um protocolo stdin/stdout versão 1: um cliente Dart comprova
`PING`, alteração do título na main queue e `CLOSE` com shutdown normal. Isso
valida o limite de processo da opção IPC, mas ainda não transporta frames ou
input.

### Duas evoluções possíveis

1. **Embedder no mesmo processo.** O host liga a VM/engine Dart, cria o isolate
   worker e integra seus eventos ao `CFRunLoop`. Menor latência e memória
   compartilhada, maior custo de build e dependência de API de embedder.
2. **Dart como processo worker.** O host inicia o executável Dart e usa IPC mais
   memória compartilhada para comandos, input e frames. Isola crashes e mantém
   o host pequeno, mas adiciona protocolo, cópias/sincronização e lifecycle de
   dois processos.

A escolha será feita por um spike separado; o witness atual não finge ter
resolvido essa integração.

## Seleção e fallback

Ordem recomendada inicialmente:

1. `appkitNativeHost`, quando o aplicativo aceitar artefato nativo;
2. `skylight`, quando for exigido executável Dart standalone e a versão tiver
   ABI validado;
3. `appkitSignal` somente com flag de laboratório.

Fallback não pode ser silencioso. O relatório deve registrar backend pedido,
backend escolhido, versão/build do macOS, símbolos encontrados, resultado do
registro de processo, permissões relevantes e motivo exato da rejeição.

## Critérios comparáveis

Cada backend deverá executar a mesma suíte:

- criar, mostrar, redimensionar e fechar duas janelas;
- apresentar framebuffer CPU e, depois, Metal;
- teclado, mouse, scroll, foco e captura;
- timer/frame pacing e latência input→frame;
- fullscreen/Spaces, dois monitores e mudança de escala;
- sleep/wake e restart do processo auxiliar, quando existir;
- teardown sem callback tardio, handle vazado ou `_exit` no caminho normal.

## Sequência de implementação

1. CI do witness `.m` e captura de `MAIN_THREAD=1`/`WINDOW_ID`;
2. interface Dart e capability report sem selecionar backend automaticamente;
3. extração do SkyLight funcional para código reutilizável;
4. encapsulamento do signal hijack com opt-in e watchdog;
5. spike embedder-vs-IPC do host `.m`;
6. counter comum nos três backends;
7. matriz de robustez e decisão do default.
