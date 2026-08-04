# POC-02 — Janela X11/XCB

Implementação mínima, 100% Dart FFI, para conectar ao X server, criar/mapear
uma janela, receber `XCB_EXPOSE` e enviar um buffer BGRA via `xcb_put_image`.

O teste é exclusivo de Linux e deve ser executado com `DISPLAY` configurado.
O workflow `POC Tests` já inicializa o Xvfb no GitHub Actions.

```bash
DISPLAY=:99 dart test poc/poc_02_x11_window
DISPLAY=:99 dart run poc/poc_02_x11_window/bin/main.dart --smoke-test
```
