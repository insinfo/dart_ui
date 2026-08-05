library;

import 'package:mvp_01_win32_counter/headless.dart';

/// Host de renderização para macOS via AppKit e CoreGraphics.
class AppKitCounterHost {
  bool run({bool smokeTest = false}) {
    // Configura o backend headless independente de plataforma
    const config = HeadlessConfig(width: 800, height: 600, scale: 1.0);
    final backend = HeadlessBackend(config);
    backend.initialize();
    
    // Renderiza a primeira frame
    backend.render();
    
    print('[AppKitHost] Backend inicializado. Framebuffer pronto: ${backend.frame.pixels.length} bytes.');

    // TODO: A integração profunda com AppKit requer bindings FFI para:
    // - CGColorSpaceCreateDeviceRGB()
    // - CGDataProviderCreateWithData()
    // - CGImageCreate()
    // - NSView drawRect:
    // - NSResponder mouseDown:, mouseUp:, mouseMoved:
    // Como o projeto foca em implementações aceleradas, a infraestrutura CoreGraphics
    // será gerada num passo dedicado à expansão do poc_03.

    if (smokeTest) {
      print('[AppKitHost] Smoke test concluído silenciosamente.');
      return true;
    }

    // Mantém o loop nativo (simulado aqui)
    return true;
  }
}
