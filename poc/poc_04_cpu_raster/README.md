# POC-04 — Rasterização CPU

Valida um renderer 2D mínimo, 100% Dart, que escreve diretamente em um
`Uint8List` BGRA8888 premultiplicado. O buffer é top-down e tem
`stride = width * 4`, pronto para ser copiado por um backend nativo futuro.

O benchmark renderiza fundo, dez cartões, texto bitmap e uma região parcial
translúcida. A memória do pixel buffer é criada uma única vez e reutilizada em
cada frame.

```powershell
dart test poc/poc_04_cpu_raster
dart run poc/poc_04_cpu_raster/bin/main.dart
dart run poc/poc_04_cpu_raster/bin/main.dart --quick
```
