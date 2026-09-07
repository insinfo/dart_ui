# Kart Racer

```powershell
dart run examples/kart_racer/main.dart
dart run examples/kart_racer/main.dart --replay=1800 --headless
```

## Navegador

Compile o launcher portátil, sirva a raiz do repositório e abra
`examples/kart_racer/web/`:

```powershell
dart compile js examples/kart_racer/web/main.dart -o examples/kart_racer/web/main.dart.js
python -m http.server 8080
```

`dart compile wasm examples/kart_racer/web/main.dart -o build/kart_racer/main.wasm`
confere o segundo compilador. A página tenta WebGPU e usa WebGL2 como fallback.
O parâmetro desktop `--prop` não existe na página porque depende do sistema de
arquivos; a pista e os karts procedurais são iguais nos dois launchers.
