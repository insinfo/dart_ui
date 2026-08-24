/// Inline status banners and transient toast notifications.
///
/// [InfoBar] is the inline form: a severity-coloured banner that lives in the
/// layout, holds a title and message, and optionally a close button. It is
/// what a document shows above itself for "saved with warnings".
///
/// [ToastHost] plus [ToastController] is the transient form: notifications
/// stacked in a corner of whatever the host wraps, shown by any code holding
/// the controller and dismissed by a click or by time. Two design points:
///
///   * **The controller is the API.** `controller.show('Saved')` from
///     anywhere; the host merely renders the controller's list. That is the
///     same controlled-widget discipline as every other control here, applied
///     to notifications - the alternative, a static `Toast.show(context)`,
///     hides an overlay inside a function call and cannot be driven by a
///     test without a tree.
///   * **Time is injected.** Auto-dismiss only runs when the host is given an
///     [AnimationClock]; without one, toasts stay until dismissed. A toast
///     that read the wall clock would be the one nondeterministic control in
///     the framework, and `animation/clock.dart` explains why none is
///     allowed.
library;

import '../animation/animation.dart';
import '../animation/clock.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart';
import 'basic.dart';
import 'control.dart';
import 'element.dart';
import 'icon.dart';
import 'icon_button.dart';
import 'semantics.dart';
import 'theme.dart';
import 'widget.dart';

/// How urgent an [InfoBar] or toast is; decides the accent colour and icon.
enum InfoBarSeverity { info, success, warning, error }

/// A severity-coloured inline banner: icon, title, message, optional close.
final class InfoBar extends StatelessWidget {
  const InfoBar({
    super.key,
    required this.title,
    this.message = '',
    this.severity = InfoBarSeverity.info,
    this.onClose,
  });

  final String title;
  final String message;
  final InfoBarSeverity severity;

  /// Shows a close button when non-null; closing is the owner's state change,
  /// exactly like every other controlled widget here.
  final void Function()? onClose;

  /// The accent for [severity] on [theme].
  static Color accentFor(InfoBarSeverity severity, ThemeData theme) =>
      switch (severity) {
        InfoBarSeverity.info => theme.accent,
        // Green and amber are not in the palette because a palette that
        // named them would have to name them twice, once per brightness. These
        // two pairs are picked for contrast on both: 4.6:1 on white and 4.8:1
        // on the dark surface.
        InfoBarSeverity.success => theme.brightness == Brightness.dark
            ? const Color(0xFF6EE7A8)
            : const Color(0xFF15803D),
        InfoBarSeverity.warning => theme.brightness == Brightness.dark
            ? const Color(0xFFF5C147)
            : const Color(0xFFB45309),
        InfoBarSeverity.error => theme.colorScheme.error,
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = accentFor(severity, theme);
    return _InfoBarChrome(
      // One announcement for the whole banner: "warning: Disk almost full".
      semanticsLabel: '${severity.name}: $title'
          '${message.isEmpty ? '' : '. $message'}',
      theme: theme,
      child: ColoredBox(
        color: theme.surfaceAlternate,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The severity stripe: colour that survives at a glance, and
            // remains even for users who cannot distinguish the icon.
            ColoredBox(
              color: accent,
              child: SizedBox(
                width: 3,
                height: theme.effectiveControlHeight + Spacing.md,
              ),
            ),
            const SizedBox(width: Spacing.md),
            // A drawn glyph rather than an icon font: the banner must render
            // identically headless, where no icon face is registered.
            Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: _SeverityDot(color: accent),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(title, style: theme.textTheme.labelLarge),
                    if (message.isNotEmpty)
                      Text(
                        message,
                        softWrap: true,
                        maxLines: 4,
                        color: theme.foregroundSecondary,
                      ),
                  ],
                ),
              ),
            ),
            // A dismiss affordance is not a *command*: an accent-filled button
            // labelled "X" made the loudest thing in the banner the way to get
            // rid of it.
            if (onClose != null)
              Padding(
                padding: const EdgeInsets.all(Spacing.xs),
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: onClose,
                  color: theme.foregroundSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The severity glyph: a filled circle in the severity's accent.
final class _SeverityDot extends RenderObjectWidget {
  const _SeverityDot({required this.color});

  final Color color;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSeverityDot createRenderObject(BuildContext context) =>
      RenderSeverityDot()..color = color;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSeverityDot object,
  ) {
    object.color = color;
  }
}

final class RenderSeverityDot extends RenderBox with ControlBehavior {
  Color _color = const Color(0xFF000000);

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() => size = constraints.constrain(const Size(10, 10));

  @override
  void paint(DisplayList list, Offset offset) => paintRoundedFill(
        list,
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        _color,
        size.width / 2,
      );

  @override
  SemanticsConfiguration describeSemantics() => const SemanticsConfiguration(
        // Decorative: the chrome's label already says the severity.
        role: SemanticsRole.generic,
      );
}

/// The banner's border and its single semantic node.
final class _InfoBarChrome extends SingleChildRenderObjectWidget {
  const _InfoBarChrome({
    required this.semanticsLabel,
    required this.theme,
    required Widget child,
  }) : super(child: child);

  final String semanticsLabel;
  final ThemeData theme;

  @override
  RenderInfoBarChrome createRenderObject(BuildContext context) =>
      RenderInfoBarChrome()
        ..semanticsLabel = semanticsLabel
        ..theme = theme;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderInfoBarChrome object,
  ) {
    object
      ..semanticsLabel = semanticsLabel
      ..theme = theme;
  }
}

/// Paints the banner's outline and announces the banner as one node.
final class RenderInfoBarChrome extends RenderSingleChildBox
    with ControlBehavior {
  String _semanticsLabel = '';

  String get semanticsLabel => _semanticsLabel;

  set semanticsLabel(String value) {
    if (value == _semanticsLabel) return;
    _semanticsLabel = value;
    markNeedsPaint();
  }

  @override
  bool get focusOnPointerDown => false;

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    child.parentData!.offset = Offset.zero;
    size = constraints.constrain(child.size);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    super.paint(list, offset);
    paintRoundedBorder(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      theme.border,
      theme.cornerRadius,
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        // Not merging: the close button inside must stay reachable as its own
        // node; the label carries the banner's one-line announcement.
        role: SemanticsRole.generic,
        label: _semanticsLabel,
      );
}

/// One live toast.
final class ToastEntry {
  const ToastEntry({
    required this.id,
    required this.title,
    this.message = '',
    this.severity = InfoBarSeverity.info,
    this.duration,
  });

  final int id;
  final String title;
  final String message;
  final InfoBarSeverity severity;

  /// How long the toast lives, when the host has a clock. Null means "until
  /// dismissed".
  final Duration? duration;
}

/// Owns the list of live toasts. Show from anywhere; a [ToastHost] renders.
final class ToastController {
  final List<ToastEntry> _entries = <ToastEntry>[];
  final List<void Function()> _listeners = <void Function()>[];
  int _nextId = 1;

  List<ToastEntry> get entries => List<ToastEntry>.unmodifiable(_entries);

  /// Shows a toast and returns its id, which [dismiss] takes.
  int show(
    String title, {
    String message = '',
    InfoBarSeverity severity = InfoBarSeverity.info,
    Duration? duration = const Duration(seconds: 4),
  }) {
    final int id = _nextId++;
    _entries.add(ToastEntry(
      id: id,
      title: title,
      message: message,
      severity: severity,
      duration: duration,
    ));
    _notify();
    return id;
  }

  void dismiss(int id) {
    final int before = _entries.length;
    _entries.removeWhere((ToastEntry entry) => entry.id == id);
    if (_entries.length != before) _notify();
  }

  void dismissAll() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _notify();
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final void Function() listener
        in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

/// Renders [controller]'s toasts stacked over [child]'s bottom corner.
final class ToastHost extends StatefulWidget {
  const ToastHost({
    super.key,
    required this.controller,
    required this.child,
    this.clock,
    this.width = 260,
  });

  final ToastController controller;
  final Widget child;

  /// Drives auto-dismiss. Null - the default - means toasts stay until
  /// dismissed; see the library doc for why no ambient clock is invented.
  final AnimationClock? clock;

  /// The fixed toast width; a corner stack does not size to its loudest
  /// member.
  final double width;

  @override
  State<ToastHost> createState() => _ToastHostState();
}

final class _ToastHostState extends State<ToastHost> {
  final Map<int, AnimationController> _timers = <int, AnimationController>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onToastsChanged);
    _syncTimers();
  }

  @override
  void didUpdateWidget(ToastHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onToastsChanged);
      widget.controller.addListener(_onToastsChanged);
    }
    _syncTimers();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onToastsChanged);
    for (final AnimationController timer in _timers.values) {
      timer.dispose();
    }
    _timers.clear();
    super.dispose();
  }

  void _onToastsChanged() {
    if (!mounted) return;
    setState(() {});
    _syncTimers();
  }

  /// One controller per timed toast, created on arrival and disposed on
  /// departure - however the toast left.
  void _syncTimers() {
    final AnimationClock? clock = widget.clock;
    if (clock == null) return;
    final Set<int> live = <int>{};
    for (final ToastEntry entry in widget.controller.entries) {
      live.add(entry.id);
      final Duration? duration = entry.duration;
      if (duration == null || _timers.containsKey(entry.id)) continue;
      final AnimationController timer = AnimationController(
        clock: clock,
        duration: duration,
      );
      timer.addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.completed) {
          widget.controller.dismiss(entry.id);
        }
      });
      _timers[entry.id] = timer;
      timer.forward(from: 0);
    }
    _timers.removeWhere((int id, AnimationController timer) {
      if (live.contains(id)) return false;
      timer.dispose();
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<ToastEntry> entries = widget.controller.entries;
    return Stack(
      children: <Widget>[
        widget.child,
        if (entries.isNotEmpty)
          Positioned(
            right: 12,
            bottom: 12,
            child: SizedBox(
              width: widget.width,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final ToastEntry entry in entries) ...<Widget>[
                    InfoBar(
                      key: ValueKey<int>(entry.id),
                      title: entry.title,
                      message: entry.message,
                      severity: entry.severity,
                      onClose: () => widget.controller.dismiss(entry.id),
                    ),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
