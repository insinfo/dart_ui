# POC-14 — Direct3D 11

Este POC inicializa um dispositivo do Direct3D 11 e o Contexto Imediato diretamente via Dart FFI
utilizando `D3D11CreateDevice`. Valida o uso de `package:win32` com as DLLs nativas do sistema
para a futura integração de pipeline gráfico 100% puro Dart renderizado na GPU.

## Execução

```powershell
dart run poc/poc_14_direct3d/bin/main.dart
```
