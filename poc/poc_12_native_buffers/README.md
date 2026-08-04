# POC-12 — Buffers nativos com ponteiros FFI

Compara seis caminhos para limpar e copiar framebuffers BGRA:

- loop byte a byte em `Uint8List` no heap Dart;
- loop e `fillRange` em `Uint32List` no heap Dart;
- escrita estilo C por `Pointer<Uint32>` em memória `calloc`;
- `fillRange` em uma view Dart que referencia a memória nativa;
- pipeline completo de fill no heap Dart seguido de cópia ao buffer nativo.

A POC mede nanossegundos por pixel e largura de banda efetiva, confirma que as
estratégias produzem os mesmos pixels e testa alinhamento, aliasing e lifecycle
manual. Não há wrapper C/C++: toda alocação e acesso nativo usa `dart:ffi` e
`package:ffi`.

```powershell
dart run poc/poc_12_native_buffers/bin/main.dart
dart run poc/poc_12_native_buffers/bin/main.dart --ci
```

O objetivo é decidir se o framebuffer principal deve viver no heap Dart, em
memória nativa, ou em um pipeline híbrido com view tipada e double buffering.
