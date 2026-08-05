import 'package:mvp_01_win32_counter/mvp_01_win32_counter.dart';
import 'package:test/test.dart';

void main() {
  test('grava e reproduz comandos básicos', () {
    final builder = DisplayListBuilder();
    builder
      ..save()
      ..translate(10, 5)
      ..drawRect(
          const Rect.fromLTWH(0, 0, 20, 10), const Color.opaque(255, 0, 0))
      ..restore();
    final list = builder.build();

    expect(list.commands, hasLength(4));
    expect(list.commands[1], isA<TranslateCommand>());
    expect(list.commands[2], isA<DrawRectCommand>());
  });

  test('CpuRenderer aplica translate e clip', () {
    final frame = HeadlessFrame(64, 48);
    frame.renderFull();
    final builder = DisplayListBuilder();
    builder
      ..translate(10, 8)
      ..clipRect(const Rect.fromLTWH(0, 0, 12, 12))
      ..drawRect(
          const Rect.fromLTWH(0, 0, 30, 30), const Color.opaque(255, 0, 0));

    CpuRenderer().render(builder.build(), frame.canvas);

    final red = const Color.opaque(255, 0, 0).packedBgra;
    expect(frame.pixelAt(10, 8), red);
    expect(frame.pixelAt(21, 19), red);
    expect(frame.pixelAt(22, 19), isNot(red));
    expect(frame.pixelAt(10, 20), isNot(red));
  });

  test('replay determinístico produz o mesmo checksum', () {
    DisplayList makeList() {
      final builder = DisplayListBuilder();
      builder
        ..drawRect(
            const Rect.fromLTWH(4, 4, 40, 20), const Color.opaque(20, 80, 160))
        ..drawText('MVP-05', const Rect.fromLTWH(0, 28, 64, 12), Color.white);
      return builder.build();
    }

    final first = HeadlessFrame(64, 48)..renderFull();
    final second = HeadlessFrame(64, 48)..renderFull();
    final list = makeList();
    final renderer = CpuRenderer();
    renderer.render(list, first.canvas);
    renderer.render(list, second.canvas);

    final firstShot = HeadlessScreenshot(64, 48, first.pixels);
    final secondShot = HeadlessScreenshot(64, 48, second.pixels);
    expect(firstShot.checksum, secondShot.checksum);
  });

  test('CounterApp grava e renderiza a cena completa via DisplayList', () {
    final frame = HeadlessFrame(320, 240);
    frame.renderDisplayList();

    final displayList = frame.app.recordDisplayList();
    expect(displayList.commands, isNotEmpty);
    expect(frame.pixelAt(0, 0), const Color.opaque(30, 34, 42).packedBgra);
    expect(frame.app.incrementButton.bounds.isEmpty, isFalse);
  });

  test('DisplayList sustenta ao menos 30 FPS na cena Counter 800x600', () {
    const frameCount = 30;
    final frame = HeadlessFrame(800, 600);
    final stopwatch = Stopwatch()..start();

    for (var index = 0; index < frameCount; index++) {
      frame.renderDisplayList();
    }

    stopwatch.stop();
    final averageFrameMs = stopwatch.elapsedMicroseconds / frameCount / 1000;
    expect(
      averageFrameMs,
      lessThan(1000 / 30),
      reason: 'DisplayList levou ${averageFrameMs.toStringAsFixed(2)} ms/frame',
    );
  });
}
