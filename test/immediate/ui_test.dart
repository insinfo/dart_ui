import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/immediate.dart';
import 'package:test/test.dart';

/// Paints nothing: these tests are about what the controls return and
/// remember, frame by frame.
final class _NullPainter implements ImmediatePainter {
  _NullPainter([this.theme = ThemeData.neutralLight]);

  @override
  final ThemeData theme;
  int keyboardRequests = 0;

  @override
  void paintRoundedFill(DisplayList list, Rect rect, Color color, double r) {}

  @override
  void paintRoundedBorder(DisplayList list, Rect rect, Color color, double r,
      {double width = 1}) {}

  @override
  void paintCheckMark(DisplayList list, Rect box, Color color) {}

  @override
  void requestKeyboardFocus() => keyboardRequests++;
}

/// Runs frames against one memory, the way the host does.
final class _Harness {
  _Harness({ThemeData theme = ThemeData.neutralLight})
      : painter = _NullPainter(theme);

  final _NullPainter painter;
  final ImmediateMemory memory = ImmediateMemory();
  final ImmediateInput input = ImmediateInput();
  Offset? _last;

  bool frame(void Function(Ui ui) build) {
    final Ui ui = Ui.frame(
      list: DisplayList(),
      painter: painter,
      input: input,
      memory: memory,
      region: const Rect.fromLTWH(0, 0, 600, 400),
      lastPointer: _last,
    );
    build(ui);
    final bool again = ui.finish();
    _last = input.pointer;
    input.endFrame();
    return again;
  }

  void move(Offset at) => input.pointer = at;

  void press(Offset at) => input
    ..pointer = at
    ..down = true
    ..pressed = true;

  void release(Offset at) => input
    ..pointer = at
    ..down = false
    ..released = true;
}

void main() {
  setUpAll(() {
    FrameworkFonts.install();
  });

  group('button', () {
    test('clicks on release over it, not on press', () {
      final _Harness h = _Harness();
      final List<bool> clicks = <bool>[];
      void build(Ui ui) => clicks.add(ui.button('Aplicar'));
      h.frame(build);
      h.press(const Offset(5, 5));
      h.frame(build);
      h.release(const Offset(5, 5));
      h.frame(build);
      h.frame(build);
      expect(clicks, <bool>[false, false, true, false]);
    });

    test('a press dragged off before release is not a click', () {
      final _Harness h = _Harness();
      final List<bool> clicks = <bool>[];
      void build(Ui ui) => clicks.add(ui.button('Ok'));
      h.press(const Offset(5, 5));
      h.frame(build);
      h.release(const Offset(500, 300));
      h.frame(build);
      expect(clicks, everyElement(isFalse));
    });

    test('a disabled button never clicks', () {
      final _Harness h = _Harness();
      final List<bool> clicks = <bool>[];
      void build(Ui ui) => clicks.add(ui.button('Ok', enabled: false));
      h.press(const Offset(5, 5));
      h.frame(build);
      h.release(const Offset(5, 5));
      h.frame(build);
      expect(clicks, everyElement(isFalse));
    });
  });

  test('check box toggles on click and keeps the caller as the state', () {
    final _Harness h = _Harness();
    var value = false;
    void build(Ui ui) => value = ui.checkbox('Máscara', value);
    h.frame(build);
    h.press(const Offset(4, 10));
    h.frame(build);
    expect(value, isFalse);
    h.release(const Offset(4, 10));
    h.frame(build);
    expect(value, isTrue);
  });

  test('radio returns its value when clicked', () {
    final _Harness h = _Harness();
    var choice = 'a';
    void build(Ui ui) {
      choice = ui.radio('A', 'a', choice);
      choice = ui.radio('B', 'b', choice);
    }

    h.frame(build);
    // The second radio sits one control and one gap below the first.
    final double y = ThemeData.neutralLight.effectiveControlHeight +
        ThemeData.neutralLight.effectiveGap +
        10;
    h.press(Offset(4, y));
    h.frame(build);
    h.release(Offset(4, y));
    h.frame(build);
    expect(choice, 'b');
  });

  test('slider follows the pointer while pressed and clamps', () {
    final _Harness h = _Harness();
    var value = 0.0;
    void build(Ui ui) =>
        value = ui.slider('', value, min: 0, max: 10, width: 216);
    h.frame(build);
    // Thumb 16: the usable track runs from x=8 to x=208.
    h.press(const Offset(108, 10));
    h.frame(build);
    expect(value, closeTo(5, 0.01));
    h.move(const Offset(1000, 10));
    h.input.down = true;
    h.frame(build);
    expect(value, 10);
    h.release(const Offset(1000, 10));
    h.frame(build);
    h.move(const Offset(108, 10));
    h.frame(build);
    expect(value, 10, reason: 'released: moving no longer drags');
  });

  test('text field focuses on click, types, deletes and ends on Enter', () {
    final _Harness h = _Harness();
    var text = '';
    void build(Ui ui) => text = ui.textField(text, key: 'name');
    h.frame(build);
    h.input.text.write('ignored');
    h.frame(build);
    expect(text, '', reason: 'not focused yet');
    h.press(const Offset(10, 10));
    h.frame(build);
    h.release(const Offset(10, 10));
    h.frame(build);
    expect(h.memory.focused, isNotNull);
    expect(h.painter.keyboardRequests, 1);
    h.input.text.write('olá');
    h.frame(build);
    expect(text, 'olá');
    h.input.keys.add(0x08);
    h.frame(build);
    expect(text, 'ol');
    h.input.keys.add(0x0D);
    h.frame(build);
    expect(h.memory.focused, isNull);
    h.input.text.write('x');
    h.frame(build);
    expect(text, 'ol');
  });

  test('a press on nothing takes the focus away', () {
    final _Harness h = _Harness();
    var text = '';
    void build(Ui ui) => text = ui.textField(text, key: 'name');
    h.press(const Offset(10, 10));
    h.frame(build);
    h.release(const Offset(10, 10));
    h.frame(build);
    expect(h.memory.focused, isNotNull);
    h.press(const Offset(500, 350));
    h.frame(build);
    expect(h.memory.focused, isNull);
  });

  test('collapsing remembers being open and runs its contents only then', () {
    final _Harness h = _Harness();
    var ran = 0;
    void build(Ui ui) => ui.collapsing('Detalhes', (Ui ui) {
          ran++;
          ui.label('dentro');
        });
    h.frame(build);
    expect(ran, 0);
    h.press(const Offset(10, 10));
    h.frame(build);
    h.release(const Offset(10, 10));
    h.frame(build);
    h.frame(build);
    expect(ran, greaterThanOrEqualTo(1));
    final int before = ran;
    h.frame(build);
    expect(ran, before + 1, reason: 'still open next frame');
  });

  test('horizontal lays controls side by side, vertical stacks them', () {
    final _Harness h = _Harness();
    late Rect a, b, c;
    h.frame((Ui ui) {
      ui.horizontal((Ui row) {
        a = row.allocate(const Size(50, 20));
        b = row.allocate(const Size(30, 40));
      });
      c = ui.allocate(const Size(10, 10));
    });
    final double gap = ThemeData.neutralLight.effectiveGap;
    expect(a.top, b.top);
    expect(b.left, a.right + gap);
    expect(c.top, 40 + gap, reason: 'below the row, which is as tall as b');
  });

  test('scroll area scrolls with the wheel and stops at the end', () {
    final _Harness h = _Harness();
    late Rect first;
    void build(Ui ui) => ui.scrollArea(height: 100, key: 'list', (Ui inner) {
          first = inner.allocate(const Size(50, 20));
          for (var i = 0; i < 9; i++) {
            inner.allocate(const Size(50, 20));
          }
        });
    h.frame(build);
    h.frame(build); // learns the content height
    expect(first.top, 0);
    h.move(const Offset(10, 50));
    h.input.scroll = const Offset(0, 30);
    h.frame(build);
    h.frame(build);
    expect(first.top, -30);
    h.input.scroll = const Offset(0, 10000);
    h.frame(build);
    h.frame(build);
    final double content = 10 * 20 + 9 * ThemeData.neutralLight.effectiveGap;
    expect(first.top, -(content - 100));
  });

  test('an idle frame asks for no other', () {
    final _Harness h = _Harness();
    void build(Ui ui) {
      ui.label('parado');
      ui.button('Ok');
    }

    h.frame(build);
    expect(h.frame(build), isFalse);
  });
}
