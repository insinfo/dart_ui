# POC-11 — UI responsiva durante download de imagem

Aplicação Win32 em Dart puro que combina a janela/framebuffer do POC-01 com o
event loop cooperativo do POC-10. O botão azul inicia um download HTTP em
streaming; durante a transferência, ele se torna um botão de cancelamento.

A janela apresenta uma barra de progresso, um pulso animado de responsividade e
a imagem baixada. A rede usa `HttpClient` assíncrono e a decodificação acontece
em `Isolate.run`, evitando bloquear mensagens, timers e renderização.

```powershell
dart run poc/poc_11_async_image_download/bin/main.dart
dart run poc/poc_11_async_image_download/bin/main.dart --smoke-test
```

O smoke test usa um servidor HTTP local que entrega uma PNG em pequenos blocos,
portanto valida rede, progresso, isolate, framebuffer e janela sem depender de
um serviço externo.
