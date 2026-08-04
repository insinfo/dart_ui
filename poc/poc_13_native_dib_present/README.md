# POC-13 — Framebuffer DIB nativo persistente

Compara dois pipelines Win32 completos:

1. `dartCopy`: raster em `Uint8List`, alocação/cópia nativa por frame e
   `StretchDIBits`;
2. `nativeDib`: `CreateDIBSection` persistente, raster direto por
   `Pointer<Uint32>` e apresentação do mesmo `HBITMAP` por `BitBlt`.

O segundo caminho não copia o framebuffer entre o heap Dart e memória nativa.
A aplicação executa os dois modos sequencialmente e informa FPS, tempo médio de
raster e tempo médio de apresentação.

```powershell
dart run poc/poc_13_native_dib_present/bin/main.dart
dart run poc/poc_13_native_dib_present/bin/main.dart --smoke-test
```
