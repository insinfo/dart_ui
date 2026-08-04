# POC-10 — Loop de eventos Win32 + Dart

Valida que um loop que espera por mensagens Win32 usando
`MsgWaitForMultipleObjectsEx` pode cooperar com `Future` e `Timer` do Dart.
Cada iteração drena a fila Win32 e cria uma fronteira assíncrona para permitir
que tarefas Dart sejam executadas. `wake()` usa `PostThreadMessage(WM_APP)`.

```powershell
dart test poc/poc_10_event_loop
dart run poc/poc_10_event_loop/bin/main.dart
```
