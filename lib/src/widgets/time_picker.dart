/// A time of day and the picker that chooses one.
///
/// [TimePicker] is the field form, as [DatePicker] is for a date: a button
/// showing the time that opens a [Flyout] of columns - hours, minutes and,
/// on a 12-hour clock, the half of the day - each a list the arrows move
/// through. The choice is kept by OK or Enter and dropped by Cancel, Escape
/// or a click outside: scrolling a column is browsing, not choosing, the way
/// WinUI's picker behaves.
///
/// The clock follows the locale ([CalendarLocalizations.use24HourClock]):
/// `14:05` in Portuguese, `2:05 PM` in English, unless the picker is told.
library;

import '../layout/render_flex.dart';
import '../layout/render_viewport.dart' show ScrollPosition;
import '../platform/input_events.dart';
import '../platform/logical_keys.dart';
import 'basic.dart';
import 'calendar.dart';
import 'controls.dart';
import 'element.dart';
import 'flyout.dart';
import 'list_box.dart';
import 'scrollbar.dart' show ScrollbarVisibility;
import 'theme.dart';
import 'widget.dart';

/// An hour and a minute, with no date and no time zone: when an alarm rings
/// or a shop opens, the same every day.
final class TimeOfDay implements Comparable<TimeOfDay> {
  const TimeOfDay({required this.hour, required this.minute})
      : assert(hour >= 0 && hour < 24, 'hour is 0..23'),
        assert(minute >= 0 && minute < 60, 'minute is 0..59');

  /// The time [date] shows on its clock.
  TimeOfDay.fromDateTime(DateTime date)
      : hour = date.hour,
        minute = date.minute;

  /// 0..23.
  final int hour;

  /// 0..59.
  final int minute;

  /// Minutes since midnight.
  int get inMinutes => hour * 60 + minute;

  /// Whether this is before noon.
  bool get isMorning => hour < 12;

  TimeOfDay replacing({int? hour, int? minute}) =>
      TimeOfDay(hour: hour ?? this.hour, minute: minute ?? this.minute);

  @override
  int compareTo(TimeOfDay other) => inMinutes - other.inMinutes;

  @override
  bool operator ==(Object other) =>
      other is TimeOfDay && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => inMinutes;

  /// `HH:MM`, the same in every locale - for logs and keys, not for people.
  @override
  String toString() => '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
}

/// A button showing a time, which opens columns to choose another.
final class TimePicker extends StatefulWidget {
  const TimePicker({
    super.key,
    this.selectedTime,
    this.onTimeSelected,
    this.placeholder = 'Select time',
    this.use24HourClock,
    this.minuteIncrement = 1,
    this.enabled = true,
  }) : assert(minuteIncrement > 0 && 60 % minuteIncrement == 0,
            'minuteIncrement divides the hour');

  final TimeOfDay? selectedTime;
  final void Function(TimeOfDay time)? onTimeSelected;

  /// Shown while no time is selected.
  final String placeholder;

  /// The clock to show; null for the locale's.
  final bool? use24HourClock;

  /// The minutes column's step: 15 offers :00, :15, :30 and :45. A selected
  /// time between steps opens on the step before it.
  final int minuteIncrement;

  final bool enabled;

  @override
  State<TimePicker> createState() => _TimePickerState();
}

final class _TimePickerState extends State<TimePicker> {
  final FlyoutController _flyout = FlyoutController();

  @override
  void dispose() {
    _flyout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CalendarLocalizations strings =
        CalendarLocalizations.resolve(context);
    final bool use24 = widget.use24HourClock ?? strings.use24HourClock;
    final TimeOfDay? selected = widget.selectedTime;
    return Flyout(
      controller: _flyout,
      // The hours column names itself; it builds as the popup lays out,
      // after the buttons, which would otherwise take the keyboard first.
      autofocus: false,
      builder: (BuildContext context, FlyoutController flyout) => Button(
        label: selected == null
            ? widget.placeholder
            : strings.formatTime(selected.hour, selected.minute,
                use24Hour: use24),
        onPressed: widget.enabled ? flyout.toggle : null,
      ),
      content: (BuildContext context, FlyoutController flyout) =>
          _TimePickerPanel(
        initial: selected ?? const TimeOfDay(hour: 12, minute: 0),
        use24: use24,
        minuteIncrement: widget.minuteIncrement,
        strings: strings,
        onAccept: (TimeOfDay time) {
          flyout.close();
          if (time != widget.selectedTime) widget.onTimeSelected?.call(time);
        },
        onCancel: flyout.close,
      ),
    );
  }
}

/// The columns and the two buttons, holding the time being browsed.
final class _TimePickerPanel extends StatefulWidget {
  const _TimePickerPanel({
    required this.initial,
    required this.use24,
    required this.minuteIncrement,
    required this.strings,
    required this.onAccept,
    required this.onCancel,
  });

  final TimeOfDay initial;
  final bool use24;
  final int minuteIncrement;
  final CalendarLocalizations strings;
  final void Function(TimeOfDay time) onAccept;
  final void Function() onCancel;

  @override
  State<_TimePickerPanel> createState() => _TimePickerPanelState();
}

final class _TimePickerPanelState extends State<_TimePickerPanel> {
  /// How many rows a column shows; odd, so the choice can sit in the middle.
  static const int _visibleRows = 7;
  static const double _columnWidth = 56;

  late int _hour = widget.initial.hour;
  late int _minute =
      widget.initial.minute - widget.initial.minute % widget.minuteIncrement;
  final List<ScrollPosition> _scrolls = <ScrollPosition>[];
  BuildOwner? _owner;

  @override
  void initState() {
    super.initState();
    _owner = (context as Element).owner;
    // Enter keeps the time from whichever column holds the keyboard; ahead
    // of the dialog layer, like the flyout's own Escape.
    _owner?.addWindowKeyHandler(_enter, modalDepth: 1 << 30, first: true);
  }

  @override
  void dispose() {
    _owner?.removeWindowKeyHandler(_enter);
    super.dispose();
  }

  bool _enter(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != logicalKeyEnter) {
      return false;
    }
    _accept();
    return true;
  }

  void _accept() => widget.onAccept(TimeOfDay(hour: _hour, minute: _minute));

  /// A scroll that opens with row [index] in the middle of the column.
  ScrollPosition _scrollFor(int column, int index, double extent) {
    while (_scrolls.length <= column) {
      _scrolls.add(ScrollPosition(
        pixels: ((index - _visibleRows ~/ 2) * extent).clamp(0.0, 1e9),
      ));
    }
    return _scrolls[column];
  }

  Widget _column({
    required int column,
    required int count,
    required int selected,
    required String Function(int index) label,
    required void Function(int index) onSelected,
    required double extent,
  }) =>
      SizedBox(
        width: _columnWidth,
        height: extent * _visibleRows,
        child: ListBox(
          itemCount: count,
          itemExtent: extent,
          selectedIndex: selected,
          controller: _scrollFor(column, selected, extent),
          scrollbar: ScrollbarVisibility.never,
          autofocus: column == 0,
          onSelected: (int index) => setState(() => onSelected(index)),
          itemBuilder: (BuildContext context, int index) =>
              Align(child: Text(label(index))),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double extent = theme.effectiveRowHeight;
    final int step = widget.minuteIncrement;
    String two(int value) => value.toString().padLeft(2, '0');
    final List<Widget> columns = <Widget>[
      if (widget.use24)
        _column(
          column: 0,
          count: 24,
          selected: _hour,
          label: two,
          onSelected: (int index) => _hour = index,
          extent: extent,
        )
      else
        // 12, 1, 2 .. 11: the half of the day lives in its own column.
        _column(
          column: 0,
          count: 12,
          selected: _hour % 12,
          label: (int index) => '${index == 0 ? 12 : index}',
          onSelected: (int index) => _hour = index + (_hour < 12 ? 0 : 12),
          extent: extent,
        ),
      _column(
        column: 1,
        count: 60 ~/ step,
        selected: _minute ~/ step,
        label: (int index) => two(index * step),
        onSelected: (int index) => _minute = index * step,
        extent: extent,
      ),
      if (!widget.use24)
        _column(
          column: 2,
          count: 2,
          selected: _hour < 12 ? 0 : 1,
          label: (int index) => widget.strings.amPm[index],
          onSelected: (int index) => _hour = _hour % 12 + index * 12,
          extent: extent,
        ),
    ];
    // The columns' width, which the buttons below share: in a popup an
    // unbounded row would stretch the panel across the window.
    return SizedBox(
      width: columns.length * _columnWidth + (columns.length - 1) * Spacing.xs,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < columns.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: Spacing.xs),
                columns[i],
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Expanded(
                child: Button(
                  label: widget.strings.acceptLabel,
                  accent: true,
                  onPressed: _accept,
                ),
              ),
              const SizedBox(width: Spacing.xs),
              Expanded(
                child: Button(
                  label: widget.strings.cancelLabel,
                  accent: false,
                  onPressed: widget.onCancel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
