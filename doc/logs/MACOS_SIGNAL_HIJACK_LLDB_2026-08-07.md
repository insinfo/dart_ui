# Backend 2 — unwind do signal hijack observado com LLDB

Data: 2026-08-07  
Runner: `macos-14`, arm64  
Commit: `f2fb875`  
Run: <https://github.com/insinfo/dart_ui/actions/runs/31162694435>

## Pergunta

Depois de usar `SIGUSR2` para colocar a thread 0 em `CFRunLoopRun`, é possível
encerrar esse run loop e devolver a thread ao launcher da VM sem `_exit`?

## Procedimento

O probe `graceful-hijack-shutdown`:

1. cria e adiciona um `CFRunLoopSource` keep-alive;
2. salva o handler anterior de `SIGUSR2`;
3. instala `CFRunLoopRun` e sinaliza a thread principal;
4. confirma que a main dispatch queue está drenando;
5. restaura o handler anterior;
6. remove e libera o source;
7. chama `CFRunLoopStop` e `CFRunLoopWakeUp`;
8. retorna normalmente de `main()` Dart.

O LLDB colocou breakpoint em `CFRunLoopRun` e executou `thread step-out` enquanto
o isolate worker solicitava o teardown.

## Evidência

Na entrada do run loop, a pilha da thread principal era:

```text
CFRunLoopRun
_sigtramp
_pthread_cond_wait
Dart_RunLoop
dyld start
```

Depois de `CFRunLoopStop` + `WakeUp`, `thread step-out` parou em:

```text
_sigtramp
_pthread_cond_wait
Dart_RunLoop
dyld start
```

O processo então produziu:

```text
NORMAL_SHUTDOWN=PASS
Process exited with status = 0
```

Isso prova que `CFRunLoopRun` retornou ao trampoline do signal e o controle
voltou ao frame da VM que havia sido interrompido. O backend não precisa mais
de `_exit` no caminho normal de shutdown.

## O que não foi provado

- `CFRunLoopRun` continua não sendo async-signal-safe;
- não há garantia do Dart de que o frame estacionado permanecerá igual;
- ainda faltam repetição start/stop, múltiplas janelas, falha parcial e
  sleep/wake;
- retornar corretamente não torna segura a entrada pelo handler;
- o backend continua `experimentalUnsafe` e opt-in.

## Diagnóstico adicional do pump

Os traces do mesmo CI mostram timers funcionando após `finishLaunching`. O
`hold-appkit` recebeu um `NSEvent` com pump periódico. A falha restante está no
pump síncrono/reentrante com `nextEventMatchingMask`, que pode bloquear a thread
principal mesmo com `distantPast`; não é ausência total da fila AppKit.
