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

## Resultado AOT no GitHub Actions

Na execução `30886674910`, com 180 frames e área cliente de 1028×681:

| Pipeline | FPS | Raster | Apresentação | Frame |
|---|---:|---:|---:|---:|
| `dartCopy` | 304,1 | 529,7 µs | 2375,6 µs | 3288,3 µs |
| `nativeDib` | 898,3 | 533,3 µs | 247,6 µs | 1113,2 µs |

O DIB persistente reduziu o custo médio de apresentação em 9,60× e elevou o
throughput completo em 2,95×. O ganho vem da remoção da cópia integral do
framebuffer, pois o custo de raster ficou praticamente igual entre os modos.
