/// A month calendar and the date picker built on it.
///
/// The calendar is a grid of 42 day cells - six weeks, the fixed shape every
/// desktop calendar uses so the control does not change height as the user
/// pages through months. Three contracts worth stating:
///
///   * **The grid is one tab stop.** Arrow keys move the focused day, and
///     crossing the edge of the month pages to the neighbour, which is how
///     every platform calendar behaves. PageUp/PageDown move a whole month,
///     Home/End jump to the start and end of the focused week, Enter and
///     Space select.
///   * **"Today" is an input, not a clock read.** [Calendar.today] must be
///     passed in for the today ring to appear; the framework does not read
///     the wall clock, because a control that did would paint differently on
///     two machines running the same test. See `animation/clock.dart` for the
///     policy.
///   * **Names come from the locale** via [CalendarLocalizations.resolve],
///     which reads the ambient [Localizations] locale. The table built in
///     covers English and Portuguese; anything else falls back to English,
///     and an application with more languages installs its own
///     [CalendarLocalizations] through a [LocalizationsDelegate], the seam
///     `localizations.dart` provides for exactly this.
///
/// [DatePicker] is the field form: a button showing the formatted date that
/// opens the calendar inline below itself. Inline rather than floating: the
/// popup machinery a floating dropdown needs is `combo_box.dart`'s overlay,
/// and borrowing it here is future work noted there.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart';
import '../platform/input_events.dart';
import '../semantics/semantics.dart';
import '../text/shaper.dart' show TextDirection;
import 'basic.dart';
import 'control.dart';
import 'controls.dart';
import 'directionality.dart';
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'icon.dart';
import 'icon_button.dart';
import 'localizations.dart';
import 'theme.dart';
import 'widget.dart';

/// The names and formats a calendar draws.
///
/// English and Portuguese are compiled in because they are the languages this
/// project is written between; everything else resolves to English rather
/// than to blank labels. An application publishes its own instance through a
/// [LocalizationsDelegate] and the calendar will prefer it.
final class CalendarLocalizations {
  const CalendarLocalizations({
    required this.monthNames,
    required this.weekdayAbbreviations,
    required this.firstDayOfWeek,
  });

  /// January first, twelve entries.
  final List<String> monthNames;

  /// Monday first, seven entries - the [DateTime.weekday] order.
  final List<String> weekdayAbbreviations;

  /// A [DateTime.monday]..[DateTime.sunday] constant.
  final int firstDayOfWeek;

  static const CalendarLocalizations english = CalendarLocalizations(
    monthNames: <String>[
      'January', 'February', 'March', 'April', 'May', 'June', 'July',
      'August', 'September', 'October', 'November', 'December', //
    ],
    weekdayAbbreviations: <String>['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'],
    firstDayOfWeek: DateTime.sunday,
  );

  static const CalendarLocalizations portuguese = CalendarLocalizations(
    monthNames: <String>[
      'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho',
      'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro', //
    ],
    weekdayAbbreviations: <String>['Se', 'Te', 'Qa', 'Qi', 'Sx', 'Sá', 'Do'],
    firstDayOfWeek: DateTime.sunday,
  );

  /// The instance for [context]: an application-installed one first, then the
  /// built-in table for the ambient locale, then English.
  static CalendarLocalizations resolve(BuildContext context) {
    final CalendarLocalizations? installed =
        Localizations.of<CalendarLocalizations>(context);
    if (installed != null) return installed;
    final Locale? locale = Localizations.maybeLocaleOf(context);
    return switch (locale?.languageCode) {
      'pt' => portuguese,
      _ => english,
    };
  }

  String monthTitle(DateTime month) =>
      '${monthNames[month.month - 1]} ${month.year}';

  /// `15/03/2026` style for Portuguese, `March 15, 2026` for everything else;
  /// what [DatePicker] shows on its face.
  String formatDate(DateTime date) {
    if (this == portuguese) {
      String two(int value) => value.toString().padLeft(2, '0');
      return '${two(date.day)}/${two(date.month)}/${date.year}';
    }
    return '${monthNames[date.month - 1]} ${date.day}, ${date.year}';
  }
}

/// A navigable month grid.
///
/// Controlled for the *selection*: the widget shows [selectedDate] and
/// reports intent through [onDateSelected]. The displayed month and the
/// keyboard's focused day are view state and live here.
final class Calendar extends StatefulWidget {
  const Calendar({
    super.key,
    this.selectedDate,
    this.onDateSelected,
    this.initialMonth,
    this.today,
    this.firstDate,
    this.lastDate,
  });

  final DateTime? selectedDate;
  final void Function(DateTime date)? onDateSelected;

  /// The month shown first; defaults to the selected date's month, then to
  /// [today]'s, then to [firstDate]'s, then to January 2001 - an arbitrary
  /// but *stable* fallback, for the reasons the library doc gives.
  final DateTime? initialMonth;

  /// The date the today ring marks, or null for no ring.
  final DateTime? today;

  /// Days before [firstDate] or after [lastDate] are disabled.
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  State<Calendar> createState() => _CalendarState();
}

/// Midnight of [date]: calendar arithmetic must ignore the time of day.
DateTime _dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

bool _sameDay(DateTime? a, DateTime? b) =>
    a != null &&
    b != null &&
    a.year == b.year &&
    a.month == b.month &&
    a.day == b.day;

final class _CalendarState extends State<Calendar> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'Calendar');
  late DateTime _month;
  late DateTime _focusedDay;

  @override
  void initState() {
    super.initState();
    final DateTime anchor = widget.selectedDate ??
        widget.today ??
        widget.firstDate ??
        DateTime(2001);
    _month = DateTime(anchor.year, anchor.month);
    _focusedDay = _dayOf(anchor);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool _isDisabled(DateTime day) {
    final DateTime? first = widget.firstDate;
    final DateTime? last = widget.lastDate;
    if (first != null && day.isBefore(_dayOf(first))) return true;
    if (last != null && _dayOf(last).isBefore(day)) return true;
    return false;
  }

  void _moveFocus(int days) {
    final DateTime next = DateTime(
      _focusedDay.year,
      _focusedDay.month,
      _focusedDay.day + days,
    );
    setState(() {
      _focusedDay = next;
      // Crossing the month's edge pages the view: the focused day must stay
      // visible or the arrows would move an invisible cursor.
      if (next.month != _month.month || next.year != _month.year) {
        _month = DateTime(next.year, next.month);
      }
    });
  }

  void _movePage(int months) {
    final DateTime month = DateTime(_month.year, _month.month + months);
    final int day = _focusedDay.day.clamp(1, _daysInMonth(month));
    setState(() {
      _month = month;
      _focusedDay = DateTime(month.year, month.month, day);
    });
  }

  static int _daysInMonth(DateTime month) =>
      DateTime(month.year, month.month + 1, 0).day;

  void _select(DateTime day) {
    if (_isDisabled(day)) return;
    setState(() {
      _focusedDay = day;
      if (day.month != _month.month || day.year != _month.year) {
        _month = DateTime(day.year, day.month);
      }
    });
    if (!_sameDay(day, widget.selectedDate)) {
      widget.onDateSelected?.call(day);
    }
  }

  bool _handleKey(
    KeyEvent event,
    TextDirection direction,
    CalendarLocalizations strings,
  ) {
    if (event is! KeyDownEvent) return false;
    final bool rtl = direction.isRightToLeft;
    switch (event.logicalKey) {
      case logicalKeyArrowRight:
        _moveFocus(rtl ? -1 : 1);
        return true;
      case logicalKeyArrowLeft:
        _moveFocus(rtl ? 1 : -1);
        return true;
      case logicalKeyArrowDown:
        _moveFocus(7);
        return true;
      case logicalKeyArrowUp:
        _moveFocus(-7);
        return true;
      case logicalKeyPageDown:
        _movePage(1);
        return true;
      case logicalKeyPageUp:
        _movePage(-1);
        return true;
      case logicalKeyHome:
        // Start of the focused week, in the locale's week order.
        _moveFocus(-((_focusedDay.weekday - strings.firstDayOfWeek) % 7));
        return true;
      case logicalKeyEnd:
        _moveFocus(6 - ((_focusedDay.weekday - strings.firstDayOfWeek) % 7));
        return true;
      case logicalKeyEnter || logicalKeySpace:
        _select(_focusedDay);
        return true;
      default:
        return false;
    }
  }

  /// The 42 days the grid shows: the month plus what pads it to whole weeks.
  List<DateTime> _gridDays(CalendarLocalizations strings) {
    final DateTime firstOfMonth = DateTime(_month.year, _month.month);
    final int leading = (firstOfMonth.weekday - strings.firstDayOfWeek) % 7;
    return List<DateTime>.generate(
      42,
      (int i) => DateTime(_month.year, _month.month, 1 - leading + i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CalendarLocalizations strings =
        CalendarLocalizations.resolve(context);
    final TextDirection direction = Directionality.of(context);
    final ThemeData theme = Theme.of(context);
    final List<DateTime> days = _gridDays(strings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The month strip: the title is the loud thing, and the two arrows are
        // navigation. Filled accent buttons here - which is what `Button` gives
        // - made "previous month" the most emphatic control on a date picker.
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.xs,
            vertical: Spacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              IconButton(
                icon: const Chevron(direction: ChevronDirection.back),
                tooltip: 'Previous month',
                onPressed: () => _movePage(-1),
              ),
              Expanded(
                child: Align(
                  child: Text(
                    strings.monthTitle(_month),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ),
              IconButton(
                icon: const Chevron(direction: ChevronDirection.forward),
                tooltip: 'Next month',
                onPressed: () => _movePage(1),
              ),
            ],
          ),
        ),
        FocusAttachment(
          node: _focusNode,
          child: _CalendarGridWidget(
            theme: theme,
            focusNode: _focusNode,
            weekdayAbbreviations: <String>[
              for (int i = 0; i < 7; i++)
                strings
                    .weekdayAbbreviations[(strings.firstDayOfWeek - 1 + i) % 7],
            ],
            textDirection: direction,
            monthTitle: strings.monthTitle(_month),
            onKeyEvent: (KeyEvent event) =>
                _handleKey(event, direction, strings),
            children: <Widget>[
              for (final DateTime day in days)
                _CalendarDayWidget(
                  key: ValueKey<String>('${day.year}-${day.month}-${day.day}'),
                  day: day,
                  outsideMonth: day.month != _month.month,
                  selected: _sameDay(day, widget.selectedDate),
                  today: _sameDay(day, widget.today),
                  focused: _sameDay(day, _focusedDay),
                  enabled: !_isDisabled(day) && widget.onDateSelected != null,
                  theme: theme,
                  onActivate: () {
                    _focusNode.requestFocus(FocusChangeReason.pointer);
                    _select(day);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// The grid
// ---------------------------------------------------------------------------

final class _CalendarGridWidget extends MultiChildRenderObjectWidget {
  const _CalendarGridWidget({
    required this.theme,
    required this.focusNode,
    required this.weekdayAbbreviations,
    required this.textDirection,
    required this.monthTitle,
    required this.onKeyEvent,
    required super.children,
  });

  final ThemeData theme;
  final FocusNode focusNode;
  final List<String> weekdayAbbreviations;
  final TextDirection textDirection;
  final String monthTitle;
  final bool Function(KeyEvent event) onKeyEvent;

  @override
  RenderCalendarGrid createRenderObject(BuildContext context) =>
      RenderCalendarGrid()
        ..weekdayAbbreviations = weekdayAbbreviations
        ..textDirection = textDirection
        ..monthTitle = monthTitle
        ..onKeyEvent = onKeyEvent
        ..theme = theme
        ..focusNode = focusNode;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCalendarGrid object,
  ) {
    object
      ..weekdayAbbreviations = weekdayAbbreviations
      ..textDirection = textDirection
      ..monthTitle = monthTitle
      ..onKeyEvent = onKeyEvent
      ..theme = theme
      ..focusNode = focusNode;
  }
}

/// Seven columns: a weekday strip it paints itself, then six rows of cells.
final class RenderCalendarGrid extends RenderBoxContainer<BoxParentData>
    with ControlBehavior {
  List<String> _weekdayAbbreviations = const <String>[];
  TextDirection _textDirection = TextDirection.leftToRight;
  String monthTitle = '';
  bool Function(KeyEvent event)? onKeyEvent;

  List<String> get weekdayAbbreviations => _weekdayAbbreviations;

  set weekdayAbbreviations(List<String> value) {
    _weekdayAbbreviations = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// One cell's square side.
  double get _cellExtent => theme.effectiveControlHeight;

  double get _stripExtent => labelLineHeight + 4;

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final double cell = _cellExtent;
    size = constraints.constrain(Size(cell * 7, _stripExtent + cell * 6));
    final BoxConstraints cellConstraints = BoxConstraints.tight(
      Size(cell, cell),
    );
    for (int i = 0; i < childCount; i++) {
      final RenderBox child = childAt(i);
      child.layout(cellConstraints, parentUsesSize: true);
      final int column = i % 7;
      final int row = i ~/ 7;
      // Right-to-left reads the week from the right edge, like every other
      // start-aligned strip in this framework.
      final double x = _textDirection.isRightToLeft
          ? size.width - (column + 1) * cell
          : column * cell;
      child.parentData!.offset = Offset(x, _stripExtent + row * cell);
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent?.call(event) ?? false;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    paintRoundedFill(list, rect, theme.surfaceRaised, theme.cornerRadius);
    final double cell = _cellExtent;
    for (int i = 0; i < _weekdayAbbreviations.length && i < 7; i++) {
      final double x =
          _textDirection.isRightToLeft ? size.width - (i + 1) * cell : i * cell;
      paintCenteredLabel(
        list,
        _weekdayAbbreviations[i],
        Rect.fromLTWH(offset.dx + x, offset.dy, cell, _stripExtent),
        theme.foregroundSecondary,
      );
    }
    super.paint(list, offset);
    paintRoundedBorder(list, rect, theme.border, theme.cornerRadius);
    paintFocusRing(list, rect, radius: theme.cornerRadius);
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.list,
        label: monthTitle,
        value: '42 days',
        states: <SemanticsState>{
          if (hasFocus) SemanticsState.focused,
        },
        actions: const <SemanticsAction>{SemanticsAction.focus},
      );
}

// ---------------------------------------------------------------------------
// One day
// ---------------------------------------------------------------------------

final class _CalendarDayWidget extends RenderObjectWidget {
  const _CalendarDayWidget({
    super.key,
    required this.day,
    required this.outsideMonth,
    required this.selected,
    required this.today,
    required this.focused,
    required this.enabled,
    required this.theme,
    required this.onActivate,
  });

  final DateTime day;
  final bool outsideMonth;
  final bool selected;
  final bool today;
  final bool focused;
  final bool enabled;
  final ThemeData theme;
  final void Function() onActivate;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderCalendarDay createRenderObject(BuildContext context) =>
      RenderCalendarDay()
        ..day = day
        ..outsideMonth = outsideMonth
        ..selected = selected
        ..today = today
        ..focused = focused
        ..onActivate = onActivate
        ..theme = theme
        ..enabled = enabled;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCalendarDay object,
  ) {
    object
      ..day = day
      ..outsideMonth = outsideMonth
      ..selected = selected
      ..today = today
      ..focused = focused
      ..onActivate = onActivate
      ..theme = theme
      ..enabled = enabled;
  }
}

/// One day cell. Focusable by pointer only - the grid owns the keyboard.
final class RenderCalendarDay extends RenderBox with ControlBehavior {
  DateTime _day = DateTime(2001);
  bool _outsideMonth = false;
  bool _selected = false;
  bool _today = false;
  bool _focused = false;
  void Function()? onActivate;

  DateTime get day => _day;

  set day(DateTime value) {
    if (value == _day) return;
    _day = value;
    markNeedsPaint();
  }

  bool get outsideMonth => _outsideMonth;

  set outsideMonth(bool value) {
    if (value == _outsideMonth) return;
    _outsideMonth = value;
    markNeedsPaint();
  }

  bool get selected => _selected;

  set selected(bool value) {
    if (value == _selected) return;
    _selected = value;
    markNeedsPaint();
  }

  bool get today => _today;

  set today(bool value) {
    if (value == _today) return;
    _today = value;
    markNeedsPaint();
  }

  /// Whether this cell is the keyboard cursor's day.
  bool get focused => _focused;

  set focused(bool value) {
    if (value == _focused) return;
    _focused = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void activate() => onActivate?.call();

  @override
  void performLayout() => size = constraints.constrain(
        Size(theme.effectiveControlHeight, theme.effectiveControlHeight),
      );

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect rect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      size.width,
      size.height,
    );
    // A day is a circle, the way every calendar draws one: a square selection
    // in a 7-column grid tiles into a solid block the moment two days in a row
    // are selected, and a filled square with a number in it is the 1995 look.
    final double disc =
        (rect.width < rect.height ? rect.width : rect.height) - Spacing.xs;
    final Rect cell = Rect.fromLTWH(
      (rect.left + (rect.width - disc) / 2).roundToDouble(),
      (rect.top + (rect.height - disc) / 2).roundToDouble(),
      disc,
      disc,
    );
    if (_selected) {
      paintRoundedFill(list, cell, theme.accent, disc / 2);
    } else if (isHovered && enabled) {
      paintRoundedFill(list, cell, theme.hoverSurface, disc / 2);
    }
    if (_today && !_selected) {
      paintRoundedBorder(list, cell, theme.accent, disc / 2);
    }
    // The keyboard cursor: a marker inside the cell, distinct from the
    // grid-level focus ring, so the cursor is visible while the ring marks
    // the grid as the focused control.
    if (_focused) {
      paintRoundedBorder(
        list,
        cell.deflate(1),
        theme.focusRing,
        (disc - 2) / 2,
        width: theme.focusRingWidth,
      );
    }
    paintCenteredLabel(
      list,
      '${_day.day}',
      rect,
      !enabled
          ? theme.disabledForeground
          : _selected
              ? theme.colorScheme.onPrimary
              : _outsideMonth
                  ? theme.disabledForeground
                  : theme.foreground,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.listItem,
        label: '${_day.day}',
        value: '${_day.year}-'
            '${_day.month.toString().padLeft(2, '0')}-'
            '${_day.day.toString().padLeft(2, '0')}',
        states: <SemanticsState>{
          if (_selected) SemanticsState.selected,
          if (!enabled) SemanticsState.disabled,
        },
        actions: enabled
            ? const <SemanticsAction>{SemanticsAction.activate}
            : const <SemanticsAction>{},
        mergesDescendants: true,
      );
}

// ---------------------------------------------------------------------------
// The picker
// ---------------------------------------------------------------------------

/// A field showing the selected date that opens a [Calendar] below itself.
final class DatePicker extends StatefulWidget {
  const DatePicker({
    super.key,
    this.selectedDate,
    this.onDateSelected,
    this.placeholder = 'Select date',
    this.today,
    this.firstDate,
    this.lastDate,
    this.enabled = true,
  });

  final DateTime? selectedDate;
  final void Function(DateTime date)? onDateSelected;

  /// Shown while no date is selected.
  final String placeholder;

  final DateTime? today;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool enabled;

  @override
  State<DatePicker> createState() => _DatePickerState();
}

final class _DatePickerState extends State<DatePicker> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final CalendarLocalizations strings =
        CalendarLocalizations.resolve(context);
    final DateTime? selected = widget.selectedDate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Button(
          label: selected == null
              ? widget.placeholder
              : strings.formatDate(selected),
          onPressed:
              widget.enabled ? () => setState(() => _open = !_open) : null,
        ),
        if (_open)
          Calendar(
            selectedDate: widget.selectedDate,
            today: widget.today,
            firstDate: widget.firstDate,
            lastDate: widget.lastDate,
            onDateSelected: (DateTime date) {
              // Choosing a date is the end of the interaction: the calendar
              // closes, which is what makes the button the picker's identity.
              setState(() => _open = false);
              widget.onDateSelected?.call(date);
            },
          ),
      ],
    );
  }
}
