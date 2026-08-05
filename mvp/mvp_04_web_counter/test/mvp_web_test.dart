@TestOn('browser')
library;

import 'package:mvp_01_win32_counter/headless.dart';
import 'package:test/test.dart';

void main() {
  test('Web MVP Headless Backend initializes', () async {
    const config = HeadlessConfig(width: 800, height: 600, scale: 1.0);
    final headless = HeadlessBackend(config);
    await headless.initialize();
    
    // Testa se consegue renderizar e injetar input na engine UI
    headless.injectMouseMove(10, 10);
    headless.render();
    
    expect(headless.frame.pixels.length, 800 * 600 * 4);
  });
}
