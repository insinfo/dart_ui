# POC-21 — matriz de transportes X11

Compara três maneiras de chegar ao mesmo protocolo X11 core:

1. `libxcb` chamada por Dart FFI;
2. codec do protocolo em Dart sobre `dart:io Socket` e Unix domain socket;
3. o mesmo codec Dart sobre `socket/connect/read/write/close` da libc via FFI.

As três alternativas abrem a mesma tela, criam uma janela não mapeada e um GC,
e executam as mesmas barreiras de protocolo. A matriz mede:

- conexão, autenticação e setup;
- throughput de `NoOperation` em lote;
- latência de `GetInputFocus` sequencial;
- throughput de payload `PutImage` BGRA 128×128.

O benchmark direto implementa somente conexão Unix local, byte order little
endian, `MIT-MAGIC-COOKIE-1` e o subconjunto core necessário. Essa limitação é
intencional: o volume de código que falta para equivaler à libxcb faz parte do
resultado de engenharia.

## Execução

Em uma sessão X11 local:

```sh
dart run poc/poc_21_x11_transport_matrix/bin/compare.dart
dart run poc/poc_21_x11_transport_matrix/bin/compare.dart --quick
dart run poc/poc_21_x11_transport_matrix/bin/compare.dart --json
```

Cada alternativa também pode ser executada isoladamente:

```sh
dart run poc/poc_21_x11_transport_matrix/bin/libxcb.dart --quick
dart run poc/poc_21_x11_transport_matrix/bin/dart_io.dart --quick
dart run poc/poc_21_x11_transport_matrix/bin/libc_ffi.dart --quick
```

Com Xvfb:

```sh
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp -ac &
DISPLAY=:99 dart run poc/poc_21_x11_transport_matrix/bin/compare.dart --quick
```

O modo `-ac` é aceitável apenas para o Xvfb efêmero do benchmark. Em uma
sessão real, a POC lê `XAUTHORITY` ou `$HOME/.Xauthority`.

## Como interpretar

- `NoOp/s` favorece deliberadamente os transportes diretos, que concatenam os
  pacotes em Dart antes de uma escrita; o caminho XCB faz uma chamada FFI por
  `xcb_no_operation`.
- `RTT médio` mede principalmente servidor, syscall e scheduling, não o codec.
- `PutImage MB/s` mede o caminho core que carrega pixels no socket. Não mede
  MIT-SHM nem EGL/OpenGL; essas alternativas eliminam esse payload e devem ser
  avaliadas separadamente.
- uma diferença pequena de throughput não demonstra equivalência funcional:
  o cliente direto não implementa extensões, XKB, XIM, sequências completas,
  reconnect, TCP, sockets abstratos, BIG-REQUESTS ou despacho geral de eventos.

O relatório e a decisão arquitetural estão em
[`doc/RELATORIO_POC_21_TRANSPORTES_X11.md`](../../doc/RELATORIO_POC_21_TRANSPORTES_X11.md).
