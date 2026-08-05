/// MVP-01: Counter app — janela Win32 real com renderização CPU em Dart puro.
///
/// Uso:
///   dart run bin/main.dart               # janela interativa
///   dart run bin/main.dart --smoke-test  # cria janela, renderiza, fecha e sai
///
/// AOT:
///   dart compile exe bin/main.dart -o build/mvp_01.exe
///   build\mvp_01.exe
library;

import 'dart:io';

import 'package:mvp_01_win32_counter/mvp_01_win32_counter.dart';
import 'package:poc_01_win32_window/poc_01_win32_window.dart';

void main(List<String> args) {
  final smokeTest = args.contains('--smoke-test');

  if (!Platform.isWindows) {
    print('[MVP-01] Este binário cria uma janela Win32; '
        'em outras plataformas use os testes headless: dart test');
    return;
  }

  print('--------------------------------------------');
  print('  MVP-01: Win32 + CPU Render + Button');
  print('  100% Dart (dart:ffi, sem wrapper C/C++)');
  print('--------------------------------------------');

  final host = Win32MvpHost();

  if (smokeTest) {
    _runSmokeTest(host);
    return;
  }

  final exitCode = host.run();
  Win32Window.shutdownWin32();
  exit(exitCode);
}

/// Cria a janela, injeta input sintético por frame (mouse + teclado) e
/// fecha sozinho depois de validar o ciclo completo.
void _runSmokeTest(Win32MvpHost host) {
  Win32Window.initializeWin32();
  final window = Win32Window(framebufferBackend: FramebufferBackend.nativeDib);
  host.attachTo(window);

  var frames = 0;
  var countAfterMouse = 0;
  var countAfterKeyboard = 0;
  host.onFrame = (h) {
    final app = h.app;
    if (app == null) return;
    final cx = window.clientWidth ~/ 2;
    final incY = app.incrementButton.bounds.top + 8;
    switch (frames) {
      case 0:
        app.handleMouseMove(cx, incY); // hover
      case 1:
        app.handleMouseDown(cx, incY, 0); // press
      case 2:
        app.handleMouseUp(cx, incY, 0); // click → count = 1
        countAfterMouse = app.count;
      case 3:
        app.setFocus(null); // começa o teste de Tab desde o início da ordem
        app.handleKeyDown(vkTab); // foco
      case 4:
        app.handleKeyDown(vkSpace); // ativa via teclado → count = 2
        countAfterKeyboard = app.count;
    }
    frames++;
    if (frames >= 6) {
      window.close();
    } else {
      // Sobe para o próximo frame: repinta a região suja do input injetado.
      window.invalidate();
    }
  };

  window.create(title: 'DartUI MVP-01 — Smoke', width: 800, height: 600);
  window.show();

  runMessageLoop();
  Win32Window.shutdownWin32();

  var failed = false;
  if (frames < 6) {
    stderr
        .writeln('[MVP-01] Smoke falhou: apenas $frames frames renderizados.');
    failed = true;
  }
  if (countAfterMouse != 1) {
    stderr.writeln('[MVP-01] Smoke falhou: clique não incrementou '
        '(count = $countAfterMouse).');
    failed = true;
  }
  if (countAfterKeyboard != 2) {
    stderr.writeln('[MVP-01] Smoke falhou: teclado não incrementou '
        '(count = $countAfterKeyboard).');
    failed = true;
  }
  if (!failed) {
    print('[MVP-01] Smoke OK: janela, render, mouse, teclado, dirty rect e '
        'close funcionaram ($frames frames, count=$countAfterKeyboard).');
  }
  exit(failed ? 1 : 0);
}
