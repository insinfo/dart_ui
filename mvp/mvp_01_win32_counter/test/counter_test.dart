/// Testes do MVP-01: o mesmo widget tree roda no backend headless, sem
/// janela real. Cobre layout, estados do botão, clique, teclado (Tab/Enter/
/// Space), dirty rect (partial raster) e pixels do framebuffer.
library;

import 'package:mvp_01_win32_counter/mvp_01_win32_counter.dart';
import 'package:test/test.dart';

void main() {
  const int w = 800;
  const int h = 600;

  late HeadlessFrame frame;

  setUp(() {
    frame = HeadlessFrame(w, h);
  });

  Point centerOf(Rect r) => Point(r.left + r.width ~/ 2, r.top + r.height ~/ 2);

  group('layout', () {
    test('botões e rótulos ficam centralizados', () {
      final app = frame.app;
      expect(app.count, 0);

      final inc = app.incrementButton.bounds;
      final reset = app.resetButton.bounds;

      // Mesma largura e mesma linha central.
      expect(inc.width, CounterApp.buttonWidth);
      expect(reset.width, CounterApp.buttonWidth);
      expect(inc.left, w ~/ 2 - CounterApp.buttonWidth ~/ 2);
      expect(reset.left, inc.left);
      expect(inc.right, inc.left + inc.width);
      expect(reset.right, reset.left + reset.width);

      // Incrementar acima de Zerar, com espaçamento.
      expect(inc.bottom, lessThan(reset.top));
      expect(reset.top - inc.bottom, CounterApp.columnSpacing);

      // Contador visível acima dos botões.
      final countLabel = app.countLabel.bounds;
      expect(countLabel.bottom, lessThan(inc.top));
    });

    test('hit test encontra o botão sob o cursor', () {
      final inc = frame.app.incrementButton.bounds;
      expect(frame.app.hitTest(centerOf(inc).x, centerOf(inc).y),
          same(frame.app.incrementButton));
      expect(frame.app.hitTest(0, 0), isNull);
    });
  });

  group('mouse', () {
    test('clique no botão INCREMENTAR incrementa a contagem', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      frame.injectMouseMove(c.x, c.y);
      frame.injectMouseDown(c.x, c.y);
      expect(frame.app.incrementButton.state, ButtonState.pressed);
      frame.injectMouseUp(c.x, c.y);

      expect(frame.app.count, 1);
      expect(frame.app.incrementButton.state, ButtonState.focused);
    });

    test('hover muda o estado do botão e volta ao normal ao sair', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      frame.injectMouseMove(c.x, c.y);
      expect(frame.app.incrementButton.state, ButtonState.hover);

      frame.injectMouseMove(5, 5);
      expect(frame.app.incrementButton.state, ButtonState.normal);
    });

    test('clique fora do botão não incrementa e remove o foco', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      frame.injectMouseDown(c.x, c.y);
      frame.injectMouseUp(c.x, c.y);
      expect(frame.app.count, 1);

      frame.injectMouseDown(5, 5);
      frame.injectMouseUp(5, 5);
      expect(frame.app.count, 1);
      expect(frame.app.focused, isNull);
    });
  });

  group('teclado', () {
    test('Tab foca o primeiro botão e Enter ativa', () {
      frame.injectKeyDown(vkTab);
      expect(frame.app.focused, same(frame.app.incrementButton));
      expect(frame.app.incrementButton.state, ButtonState.focused);

      frame.injectKeyDown(vkReturn);
      expect(frame.app.count, 1);
    });

    test('Tab avança e envolve na ordem de foco', () {
      frame.injectKeyDown(vkTab);
      expect(frame.app.focused, same(frame.app.incrementButton));
      frame.injectKeyDown(vkTab);
      expect(frame.app.focused, same(frame.app.resetButton));
      frame.injectKeyDown(vkTab);
      expect(frame.app.focused, same(frame.app.incrementButton));
    });

    test('Space ativa o botão focado', () {
      frame.injectKeyDown(vkTab);
      frame.injectKeyDown(vkTab); // foca ZERAR
      frame.injectKeyDown(vkSpace);
      expect(frame.app.count, 0); // ZERAR em 0 não muda nada

      frame.injectKeyDown(vkTab); // volta para INCREMENTAR
      frame.injectKeyDown(vkSpace);
      expect(frame.app.count, 1);
    });
  });

  group('estado e texto', () {
    test('contagem aparece no rótulo', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);
      for (var i = 0; i < 3; i++) {
        frame.injectMouseDown(c.x, c.y);
        frame.injectMouseUp(c.x, c.y);
      }
      expect(frame.app.count, 3);
      expect(frame.app.countLabel.text, 'CONTAGEM: 3');
    });

    test('ZERAR volta a contagem para 0', () {
      final inc = frame.app.incrementButton.bounds;
      final reset = frame.app.resetButton.bounds;
      final ic = centerOf(inc);
      final rc = centerOf(reset);

      for (var i = 0; i < 5; i++) {
        frame.injectMouseDown(ic.x, ic.y);
        frame.injectMouseUp(ic.x, ic.y);
      }
      expect(frame.app.count, 5);

      frame.injectMouseDown(rc.x, rc.y);
      frame.injectMouseUp(rc.x, rc.y);
      expect(frame.app.count, 0);
      expect(frame.app.countLabel.text, 'CONTAGEM: 0');
    });
  });

  group('dirty rect e pixels', () {
    test('pintura inicial cobre a janela inteira', () {
      frame.renderFull();
      expect(frame.paintCount, 1);

      // Fundo escuro em um canto fora dos widgets.
      final bg = frame.pixelAt(3, 3);
      expect(bg & 0xFF, 42); // B
      expect((bg >> 8) & 0xFF, 34); // G
      expect((bg >> 16) & 0xFF, 30); // R
    });

    test('hover repinta apenas a região do botão (partial raster)', () {
      frame.renderFull();
      final paintsBefore = frame.paintCount;
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      // Sem hover ainda: sem dirty, sem paint.
      frame.app.paint();
      expect(frame.paintCount, paintsBefore);

      frame.injectMouseMove(c.x, c.y);
      final dirty = frame.render();
      expect(dirty.isEmpty, isFalse);
      expect(dirty.containsRect(inc), isTrue);
      expect(dirty.width, lessThan(w));
      expect(dirty.height, lessThan(h));
      expect(frame.paintCount, paintsBefore + 1);
    });

    test('pixels do botão hover diferem do normal', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      frame.renderFull();
      final normalColor = frame.pixelAt(c.x, c.y);

      frame.injectMouseMove(c.x, c.y);
      frame.render();
      final hoverColor = frame.pixelAt(c.x, c.y);

      expect(hoverColor, isNot(normalColor));
    });

    test('texto do contador muda após incrementar (label suja)', () {
      final inc = frame.app.incrementButton.bounds;
      final c = centerOf(inc);

      frame.renderFull();
      frame.injectMouseDown(c.x, c.y);
      frame.injectMouseUp(c.x, c.y);
      final dirty = frame.render();

      // A região suja inclui o rótulo do contador.
      expect(dirty.containsRect(frame.app.countLabel.bounds), isTrue);
    });
  });

  group('renderização determinística', () {
    test('mesma sequência de input produz o mesmo framebuffer', () {
      final a = HeadlessFrame(w, h);
      final b = HeadlessFrame(w, h);

      void drive(HeadlessFrame f) {
        f.renderFull();
        final inc = f.app.incrementButton.bounds;
        final c = centerOf(inc);
        f.injectMouseMove(c.x, c.y);
        f.render();
        f.injectMouseDown(c.x, c.y);
        f.render();
        f.injectMouseUp(c.x, c.y);
        f.render();
        f.injectKeyDown(vkTab);
        f.render();
      }

      drive(a);
      drive(b);
      expect(a.pixels, orderedEquals(b.pixels));
      expect(a.app.count, b.app.count);
    });

    test('HeadlessBackend expõe captura e checksum golden', () async {
      final backend =
          HeadlessBackend(const HeadlessConfig(width: 320, height: 240));
      await backend.initialize();

      final before = backend.captureScreenshot();
      final inc = backend.app.incrementButton.bounds;
      final point = centerOf(inc);
      backend.injectMouseDown(point.x, point.y);
      backend.injectMouseUp(point.x, point.y);
      final after = backend.captureScreenshot();

      expect(before.width, 320);
      expect(before.height, 240);
      expect(before.checksum, isNot(after.checksum));
      expect(backend.app.count, 1);
      expect(after.pixels.length, 320 * 240 * 4);
      backend.dispose();
    });

    test('HeadlessBackend exige initialize antes de usar', () {
      final backend = HeadlessBackend(const HeadlessConfig());
      expect(() => backend.captureScreenshot(), throwsStateError);
    });
  });
}
