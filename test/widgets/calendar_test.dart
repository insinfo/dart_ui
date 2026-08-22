import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  group('CalendarLocalizations', () {
    test('the built-in tables format months and dates', () {
      final DateTime date = DateTime(2026, 3, 5);
      expect(CalendarLocalizations.english.monthTitle(date), 'March 2026');
      expect(CalendarLocalizations.english.formatDate(date), 'March 5, 2026');
      expect(CalendarLocalizations.portuguese.monthTitle(date), 'Março 2026');
      expect(CalendarLocalizations.portuguese.formatDate(date), '05/03/2026');
    });
  });

  group('Calendar structure', () {
    test('the grid always shows six whole weeks', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 15));
      harness.frame();

      expect(harness.grid.childCount, 42);
      expect(harness.grid.monthTitle, 'March 2026');
      // March 2026 starts on a Sunday, so the first cell is March 1st.
      expect((harness.grid.childAt(0) as RenderCalendarDay).day,
          DateTime(2026, 3, 1));
      harness.dispose();
    });

    test('the selected day and today are marked', () {
      final harness = _CalendarHarness(
        selected: DateTime(2026, 3, 15),
        today: DateTime(2026, 3, 20),
      );
      harness.frame();

      expect(harness.dayCell(DateTime(2026, 3, 15)).selected, isTrue);
      expect(harness.dayCell(DateTime(2026, 3, 20)).today, isTrue);
      harness.dispose();
    });

    test('days outside firstDate/lastDate are disabled', () {
      final harness = _CalendarHarness(
        selected: DateTime(2026, 3, 15),
        firstDate: DateTime(2026, 3, 10),
        lastDate: DateTime(2026, 3, 20),
      );
      harness.frame();

      expect(harness.dayCell(DateTime(2026, 3, 5)).enabled, isFalse);
      expect(harness.dayCell(DateTime(2026, 3, 15)).enabled, isTrue);
      expect(harness.dayCell(DateTime(2026, 3, 25)).enabled, isFalse);
      harness.dispose();
    });

    test('the portuguese locale names the month through Localizations', () {
      final harness = _CalendarHarness(
        selected: DateTime(2026, 3, 15),
        locale: Locale('pt', null, 'BR'),
      );
      harness.frame();

      expect(harness.grid.monthTitle, 'Março 2026');
      harness.dispose();
    });
  });

  group('Calendar keyboard', () {
    test('arrows move the focused day by one and seven', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 15));
      harness.frame();
      expect(harness.focusedDay, DateTime(2026, 3, 15));

      harness.grid.handleKeyEvent(_key(logicalKeyArrowRight));
      harness.frame();
      expect(harness.focusedDay, DateTime(2026, 3, 16));

      harness.grid.handleKeyEvent(_key(logicalKeyArrowDown));
      harness.frame();
      expect(harness.focusedDay, DateTime(2026, 3, 23));

      harness.grid.handleKeyEvent(_key(logicalKeyArrowUp));
      harness.frame();
      expect(harness.focusedDay, DateTime(2026, 3, 16));
      harness.dispose();
    });

    test('crossing the month edge pages the view', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 31));
      harness.frame();

      harness.grid.handleKeyEvent(_key(logicalKeyArrowRight));
      harness.frame();

      expect(harness.focusedDay, DateTime(2026, 4, 1));
      expect(harness.grid.monthTitle, 'April 2026');
      harness.dispose();
    });

    test('PageDown and PageUp move a whole month', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 15));
      harness.frame();

      harness.grid.handleKeyEvent(_key(logicalKeyPageDown));
      harness.frame();
      expect(harness.grid.monthTitle, 'April 2026');

      harness.grid.handleKeyEvent(_key(logicalKeyPageUp));
      harness.frame();
      expect(harness.grid.monthTitle, 'March 2026');
      harness.dispose();
    });

    test('Home jumps to the start of the week and Enter selects', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 18));
      harness.frame();

      harness.grid.handleKeyEvent(_key(logicalKeyHome));
      harness.frame();
      // The 18th is a Wednesday; the english week starts on Sunday the 15th.
      expect(harness.focusedDay, DateTime(2026, 3, 15));

      harness.grid.handleKeyEvent(_key(logicalKeyArrowRight));
      harness.frame();
      harness.grid.handleKeyEvent(_key(logicalKeyEnter));
      harness.frame();
      expect(harness.picked, DateTime(2026, 3, 16));
      harness.dispose();
    });
  });

  group('Calendar pointer', () {
    test('clicking a day selects it', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 15));
      harness.frame();

      final RenderCalendarDay cell = harness.dayCell(DateTime(2026, 3, 10));
      final Offset center = cell.localToGlobal(
        Offset(cell.size.width / 2, cell.size.height / 2),
      );
      cell.handlePointerEvent(_press(center));
      cell.handlePointerEvent(_release(center));
      harness.frame();

      expect(harness.picked, DateTime(2026, 3, 10));
      harness.dispose();
    });

    test('a disabled day cannot be selected', () {
      final harness = _CalendarHarness(
        selected: DateTime(2026, 3, 15),
        firstDate: DateTime(2026, 3, 10),
      );
      harness.frame();

      final RenderCalendarDay cell = harness.dayCell(DateTime(2026, 3, 5));
      // Direct activation is the strongest attempt a pointer could make.
      cell.activate();
      harness.frame();

      expect(harness.picked, isNull);
      harness.dispose();
    });
  });

  group('Calendar semantics', () {
    test('the grid is a list named for its month, days carry ISO values', () {
      final harness = _CalendarHarness(selected: DateTime(2026, 3, 15));
      harness.frame();

      final SemanticsSnapshot snapshot =
          SemanticsOwner().build(harness.owner.renderRoot);
      final SemanticsNode gridNode = snapshot.nodes.firstWhere(
        (SemanticsNode node) =>
            node.role == SemanticsRole.list && node.label == 'March 2026',
      );
      expect(gridNode.value, '42 days');

      final SemanticsNode selectedDay = snapshot.nodes.firstWhere(
        (SemanticsNode node) => node.value == '2026-03-15',
      );
      expect(selectedDay.states, contains(SemanticsState.selected));
      harness.dispose();
    });
  });

  group('DatePicker', () {
    test('opens on press, closes on selection, and shows the date', () {
      final harness = _PickerHarness();
      harness.frame();
      expect(harness.findGrid(), isNull);
      expect(harness.button.label, 'Select date');

      harness.button.activate();
      harness.frame();
      expect(harness.findGrid(), isNotNull);

      harness.dayCell(DateTime(2026, 3, 10)).activate();
      harness.frame();

      expect(harness.picked, DateTime(2026, 3, 10));
      expect(harness.findGrid(), isNull, reason: 'selection closes the popup');
      expect(harness.button.label, 'March 10, 2026');
      harness.dispose();
    });
  });
}

final class _CalendarHarness {
  _CalendarHarness({
    required this.selected,
    this.today,
    this.firstDate,
    this.lastDate,
    this.locale,
  }) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(240, 260)),
      ),
    );
    _mount();
  }

  DateTime selected;
  final DateTime? today;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final Locale? locale;
  DateTime? picked;
  late final BuildOwner owner;

  void _mount() {
    final Widget calendar = Calendar(
      selectedDate: selected,
      today: today,
      firstDate: firstDate,
      lastDate: lastDate,
      onDateSelected: (DateTime date) {
        picked = date;
        selected = date;
      },
    );
    owner.updateRoot(locale == null
        ? Directionality(
            textDirection: TextDirection.leftToRight,
            child: calendar,
          )
        : Localizations(locale: locale!, child: calendar));
  }

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the calendar never settled');
  }

  RenderCalendarGrid get grid {
    RenderCalendarGrid? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is RenderCalendarGrid) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found!;
  }

  RenderCalendarDay dayCell(DateTime day) {
    for (int i = 0; i < grid.childCount; i++) {
      final RenderCalendarDay cell = grid.childAt(i) as RenderCalendarDay;
      if (cell.day == day) return cell;
    }
    throw StateError('day $day is not in the grid');
  }

  /// The day the keyboard cursor is on, read off the cells themselves.
  DateTime get focusedDay {
    for (int i = 0; i < grid.childCount; i++) {
      final RenderCalendarDay cell = grid.childAt(i) as RenderCalendarDay;
      if (cell.focused) return cell.day;
    }
    throw StateError('no cell is focused');
  }

  void dispose() => owner.dispose();
}

final class _PickerHarness {
  _PickerHarness() {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(240, 300)),
      ),
    );
    _mount();
  }

  DateTime? picked;
  late final BuildOwner owner;

  void _mount() => owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: DatePicker(
          selectedDate: picked,
          // A picker opened in a test must land on a known month.
          today: DateTime(2026, 3, 15),
          onDateSelected: (DateTime date) => picked = date,
        ),
      ));

  void frame({int maxPasses = 8}) {
    for (int pass = 0; pass < maxPasses; pass++) {
      _mount();
      owner.pipelineOwner.drawFrame(DisplayList());
      if (!owner.hasScheduledBuilds) return;
    }
    throw StateError('the picker never settled');
  }

  T? _find<T extends RenderBox>() {
    T? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node is T) {
        found = node;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  RenderButton get button => _find<RenderButton>()!;

  RenderCalendarGrid? findGrid() => _find<RenderCalendarGrid>();

  RenderCalendarDay dayCell(DateTime day) {
    final RenderCalendarGrid grid = findGrid()!;
    for (int i = 0; i < grid.childCount; i++) {
      final RenderCalendarDay cell = grid.childAt(i) as RenderCalendarDay;
      if (cell.day == day) return cell;
    }
    throw StateError('day $day is not in the grid');
  }

  void dispose() => owner.dispose();
}

KeyDownEvent _key(int logicalKey) => KeyDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      physicalKey: logicalKey,
      logicalKey: logicalKey,
    );

PointerDownEvent _press(Offset position) => PointerDownEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );

PointerUpEvent _release(Offset position) => PointerUpEvent(
      windowId: const NativeWindowId(1),
      generation: 1,
      timestamp: Duration.zero,
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition: position,
      button: PointerButton.primary,
    );
