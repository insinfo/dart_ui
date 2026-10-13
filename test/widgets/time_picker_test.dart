/// TimeOfDay and the TimePicker: the face follows the locale's clock, the
/// columns browse, and only OK or Enter keeps what they show.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

KeyDownEvent _down(int key) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: key,
      logicalKey: key,
    );

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  group('TimeOfDay', () {
    test('compares, equals and prints as HH:MM', () {
      const TimeOfDay early = TimeOfDay(hour: 9, minute: 5);
      const TimeOfDay late = TimeOfDay(hour: 21, minute: 0);
      expect(early.compareTo(late), lessThan(0));
      expect(early, const TimeOfDay(hour: 9, minute: 5));
      expect(early.toString(), '09:05');
      expect(early.isMorning, isTrue);
      expect(late.isMorning, isFalse);
      expect(TimeOfDay.fromDateTime(DateTime(2026, 1, 1, 13, 45)),
          const TimeOfDay(hour: 13, minute: 45));
      expect(early.replacing(minute: 30).inMinutes, 9 * 60 + 30);
    });

    test('the locales format a 12- and a 24-hour clock', () {
      expect(CalendarLocalizations.english.formatTime(0, 5), '12:05 AM');
      expect(CalendarLocalizations.english.formatTime(12, 0), '12:00 PM');
      expect(CalendarLocalizations.english.formatTime(14, 35), '2:35 PM');
      expect(CalendarLocalizations.portuguese.formatTime(14, 35), '14:35');
      expect(CalendarLocalizations.english.formatTime(9, 5, use24Hour: true),
          '09:05');
    });
  });

  group('TimePicker', () {
    late BuildOwner owner;
    TimeOfDay? picked;

    void frame() {
      for (var i = 0; i < 8; i++) {
        owner.buildScope();
        owner.pipelineOwner.drawFrame(DisplayList());
        if (!owner.hasScheduledBuilds) return;
      }
    }

    Widget tree({bool? use24, int increment = 1}) => Directionality(
          textDirection: TextDirection.leftToRight,
          child: PopupScope(
            child: Align(
              alignment: Alignment.topLeft,
              child: TimePicker(
                selectedTime: picked,
                use24HourClock: use24,
                minuteIncrement: increment,
                onTimeSelected: (TimeOfDay time) => picked = time,
              ),
            ),
          ),
        );

    List<T> findAll<T extends RenderBox>() {
      final List<T> found = <T>[];
      void walk(RenderBox node) {
        if (node is T) found.add(node);
        node.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      return found;
    }

    RenderButton button(String label) => findAll<RenderButton>()
        .firstWhere((RenderButton b) => b.label == label);

    void mount({bool? use24, int increment = 1, TimeOfDay? initial}) {
      picked = initial;
      owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(400, 400)),
        ),
      )..updateRoot(tree(use24: use24, increment: increment));
      frame();
    }

    void rebuild({bool? use24, int increment = 1}) {
      owner.updateRoot(tree(use24: use24, increment: increment));
      frame();
    }

    tearDown(() => owner.dispose());

    test('shows the placeholder, then the time on the locale\'s clock', () {
      mount();
      expect(findAll<RenderButton>().single.label, 'Select time');
      picked = const TimeOfDay(hour: 14, minute: 35);
      rebuild();
      expect(findAll<RenderButton>().single.label, '2:35 PM');
      rebuild(use24: true);
      expect(findAll<RenderButton>().single.label, '14:35');
    });

    test('opens on the selected time with the hours taking the keyboard', () {
      mount(initial: const TimeOfDay(hour: 14, minute: 35));
      button('2:35 PM').activate();
      frame();
      final List<RenderListBox> columns = findAll<RenderListBox>();
      expect(columns, hasLength(3), reason: 'hours, minutes, AM/PM');
      expect(
          columns.map((RenderListBox c) => c.selectedIndex), <int?>[2, 35, 1]);
      expect(owner.focusManager.primaryFocus?.debugLabel, 'ListBox');
      expect(columns.first.hasFocus, isTrue, reason: 'the hours first');
    });

    test('the arrows browse; Enter keeps the time', () {
      mount(initial: const TimeOfDay(hour: 9, minute: 0), use24: true);
      button('09:00').activate();
      frame();
      owner.dispatchKeyEvent(_down(logicalKeyArrowDown));
      frame();
      expect(picked, const TimeOfDay(hour: 9, minute: 0),
          reason: 'browsing is not choosing');
      owner.dispatchKeyEvent(_down(logicalKeyEnter));
      frame();
      expect(picked, const TimeOfDay(hour: 10, minute: 0));
      expect(findAll<RenderListBox>(), isEmpty, reason: 'closed');
    });

    test('Cancel and Escape drop what the columns show', () {
      mount(initial: const TimeOfDay(hour: 9, minute: 0), use24: true);
      button('09:00').activate();
      frame();
      owner.dispatchKeyEvent(_down(logicalKeyArrowDown));
      frame();
      button('Cancel').activate();
      frame();
      expect(findAll<RenderListBox>(), isEmpty);
      expect(picked, const TimeOfDay(hour: 9, minute: 0));

      button('09:00').activate();
      frame();
      owner.dispatchKeyEvent(_down(logicalKeyArrowDown));
      owner.dispatchKeyEvent(_down(logicalKeyEscape));
      frame();
      expect(findAll<RenderListBox>(), isEmpty);
      expect(picked, const TimeOfDay(hour: 9, minute: 0));
    });

    test(
        'a 15-minute step offers four minutes, and the half of the day '
        'moves the hour by twelve', () {
      mount(
          initial: const TimeOfDay(hour: 8, minute: 20),
          increment: 15,
          use24: false);
      button('8:20 AM').activate();
      frame();
      final List<RenderListBox> columns = findAll<RenderListBox>();
      expect(columns[1].selectedIndex, 1, reason: ':20 opens on :15');
      columns[2].select(1);
      frame();
      button('OK').activate();
      frame();
      expect(picked, const TimeOfDay(hour: 20, minute: 15));
    });
  });
}
