/// The chrome around a text field - label, hint, helper, error, counter,
/// prefix and suffix, border and fill - with Flutter's `InputDecoration`,
/// `InputBorder`, `OutlineInputBorder`, `UnderlineInputBorder` and
/// `InputDecorator`.
///
/// ## Drawn in this framework's theme
///
/// The *shapes* are Flutter's: an [OutlineInputBorder] is a rounded outline
/// whose top edge opens a gap for the floating label, an
/// [UnderlineInputBorder] a line under the text. The *colours* come from the
/// ambient [Theme], not from Material: the accent when focused, the theme's
/// error colour for an error, its secondary foreground for the label, the
/// helper text and the counter.
///
/// An [InputDecoration] that names no [InputDecoration.border] gets the
/// theme's own field - the filled, rounded box a plain `TextField` draws -
/// with the label above it, which is where a desktop toolkit puts a field's
/// caption. Flutter's default there is an underline; asking for
/// `UnderlineInputBorder()` gets that.
///
/// ## What differs from Flutter
///
///  * **No animation.** The label floats - moves from inside the field to
///    above it on focus or when the field has text - in one frame, rather
///    than over Flutter's 167 ms.
///  * **Text-only label, hint and prefix.** [InputDecoration.labelText],
///    [InputDecoration.hintText] and [InputDecoration.prefixText] are
///    supported; Flutter's widget forms `label` and `hint` are not.
///    [InputDecoration.helper], [InputDecoration.error] and
///    [InputDecoration.counter] *are* widgets, as in Flutter.
///  * **The label and hint styles are read for colour and size only.**
///  * **[InputBorder.paint] draws into a [DisplayList]**, the framework's
///    recording surface, where Flutter's takes a `Canvas`.
///  * **As in Flutter, [InputDecoration.border]'s colour is replaced by the
///    state's colour**; a border whose colour should stick is given as
///    [InputDecoration.enabledBorder], [InputDecoration.focusedBorder] and
///    the other per-state borders.
library;

import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/path.dart' show PathBuilder;
import '../geometry/rect.dart';
import '../geometry/rrect.dart' show Radius;
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../layout/border_radius.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_flex.dart' show CrossAxisAlignment, MainAxisSize;
import '../layout/render_table.dart' show BorderSide;
import '../rendering/text/font_registry.dart';
import '../text/shaper.dart' show GlyphRun, TextDirection;
import '../text/typeface.dart' show ScaledTypeface;
import 'basic.dart';
import 'element.dart';
import 'icon.dart';
import 'pointer_router.dart' show HoverEventTarget;
import 'proxy.dart' show Opacity;
import 'sizing.dart' show LimitedBox;
import 'theme.dart';
import 'widget.dart';

// ---------------------------------------------------------------------------
// Borders
// ---------------------------------------------------------------------------

/// The line around - or under - a decorated field.
///
/// [borderSide]'s colour and width are replaced by the decorator's
/// state colour when this is given as [InputDecoration.border], as in
/// Flutter; given as one of the per-state borders, they are drawn as they
/// are. A border whose side is [BorderSide.none] is never recoloured.
abstract class InputBorder {
  const InputBorder({this.borderSide = const BorderSide()});

  /// No border at all - and no gap reserved for one.
  static const InputBorder none = _NoInputBorder();

  /// The colour and width of the line.
  final BorderSide borderSide;

  /// Whether this border goes all the way round, so the floating label sits
  /// in a gap in its top edge rather than inside the field.
  bool get isOutline;

  /// This border with another [borderSide].
  InputBorder copyWith({BorderSide? borderSide});

  /// Fills [rect] with [color] in this border's shape.
  void paintFill(DisplayList list, Rect rect, Color color);

  /// Draws the border round [rect].
  ///
  /// [gapStart] and [gapExtent] open a gap in the top edge, measured from
  /// [rect]'s left, for an outline's floating label; [gapPercentage] is how
  /// open it is, 0 to 1. [textDirection] is accepted for Flutter's signature
  /// and not used: the gap is placed by its own start.
  void paint(
    DisplayList list,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  });
}

final class _NoInputBorder extends InputBorder {
  const _NoInputBorder() : super(borderSide: BorderSide.none);

  @override
  bool get isOutline => false;

  @override
  InputBorder copyWith({BorderSide? borderSide}) => this;

  @override
  void paintFill(DisplayList list, Rect rect, Color color) =>
      list.drawRectangle(
        rect,
        list.addPaint(colorArgb: color.value, antiAlias: false),
      );

  @override
  void paint(
    DisplayList list,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {}
}

/// A line along the bottom of the field: Material's default.
class UnderlineInputBorder extends InputBorder {
  const UnderlineInputBorder({
    super.borderSide = const BorderSide(),
    this.borderRadius = const BorderRadius.only(
      topLeft: Radius.circular(4.0),
      topRight: Radius.circular(4.0),
    ),
  });

  /// The corners of the fill, when the decoration is filled. The line itself
  /// is straight.
  final BorderRadius borderRadius;

  @override
  bool get isOutline => false;

  @override
  UnderlineInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
  }) =>
      UnderlineInputBorder(
        borderSide: borderSide ?? this.borderSide,
        borderRadius: borderRadius ?? this.borderRadius,
      );

  @override
  void paintFill(DisplayList list, Rect rect, Color color) =>
      _fillRounded(list, rect, borderRadius, color);

  @override
  void paint(
    DisplayList list,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (!borderSide.isVisible) return;
    list.drawRectangle(
      Rect.fromLTWH(
        rect.left,
        rect.bottom - borderSide.width,
        rect.width,
        borderSide.width,
      ),
      list.addPaint(colorArgb: borderSide.color.value, antiAlias: false),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UnderlineInputBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius);
}

/// A rounded outline all the way round, with a gap in the top edge where the
/// floating label sits.
class OutlineInputBorder extends InputBorder {
  const OutlineInputBorder({
    super.borderSide = const BorderSide(),
    this.borderRadius = const BorderRadius.all(Radius.circular(4.0)),
    this.gapPadding = 4.0,
  });

  /// The space either side of the floating label inside the gap.
  final double gapPadding;

  /// The corners.
  final BorderRadius borderRadius;

  @override
  bool get isOutline => true;

  @override
  OutlineInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) =>
      OutlineInputBorder(
        borderSide: borderSide ?? this.borderSide,
        borderRadius: borderRadius ?? this.borderRadius,
        gapPadding: gapPadding ?? this.gapPadding,
      );

  @override
  void paintFill(DisplayList list, Rect rect, Color color) =>
      _fillRounded(list, rect, borderRadius, color);

  @override
  void paint(
    DisplayList list,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (!borderSide.isVisible) return;
    final double width = borderSide.width;
    final Rect r = rect.deflate(width / 2);
    final double open = gapExtent * gapPercentage.clamp(0.0, 1.0);
    final PathBuilder path = PathBuilder();
    final _Corners c = _Corners(r, borderRadius);
    if (gapStart == null || open <= 0) {
      path.moveTo(r.left + c.tl, r.top);
      c.around(path);
      path.close();
    } else {
      final double from = (r.left + gapStart).clamp(r.left + c.tl, r.right);
      final double to = (from + open).clamp(from, r.right - c.tr);
      path.moveTo(to, r.top);
      c.around(path);
      path.lineTo(from, r.top);
    }
    list.drawPath(
      list.addPath(path.build()),
      list.addPaint(
        colorArgb: borderSide.color.value,
        style: paintStyleStroke,
        strokeWidth: width,
        antiAlias: true,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OutlineInputBorder &&
      other.borderSide == borderSide &&
      other.borderRadius == borderRadius &&
      other.gapPadding == gapPadding;

  @override
  int get hashCode => Object.hash(borderSide, borderRadius, gapPadding);
}

/// The theme's own field: a filled box with the theme's corner radius. What
/// a decoration with no [InputDecoration.border] draws, and what a plain
/// `TextField` has always looked like.
final class _ThemeInputBorder extends InputBorder {
  const _ThemeInputBorder(this.radius, {super.borderSide});

  final double radius;

  @override
  bool get isOutline => false;

  @override
  _ThemeInputBorder copyWith({BorderSide? borderSide}) =>
      _ThemeInputBorder(radius, borderSide: borderSide ?? this.borderSide);

  @override
  void paintFill(DisplayList list, Rect rect, Color color) => _fillRounded(
      list, rect, BorderRadius.all(Radius.circular(radius)), color);

  @override
  void paint(
    DisplayList list,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (!borderSide.isVisible) return;
    final double inset = borderSide.width / 2;
    list.drawRRectUniform(
      rect.left + inset,
      rect.top + inset,
      rect.right - inset,
      rect.bottom - inset,
      radius,
      radius,
      list.addPaint(
        colorArgb: borderSide.color.value,
        style: paintStyleStroke,
        strokeWidth: borderSide.width,
        antiAlias: true,
      ),
    );
  }
}

/// The four corner radii of a rectangle, clamped to fit, and the path round
/// them clockwise from the top edge.
final class _Corners {
  _Corners(this.r, BorderRadius radius)
      : tl = _fit(radius.topLeft.x, r),
        tr = _fit(radius.topRight.x, r),
        br = _fit(radius.bottomRight.x, r),
        bl = _fit(radius.bottomLeft.x, r);

  final Rect r;
  final double tl, tr, br, bl;

  static double _fit(double radius, Rect r) =>
      radius.clamp(0.0, math.min(r.width, r.height) / 2);

  /// How far along a quarter circle's tangent the Bézier controls sit.
  static const double _k = 0.5522847498;

  /// From wherever the path is on the top edge, clockwise all the way round
  /// to the top-left corner's end.
  void around(PathBuilder p) {
    p
      ..lineTo(r.right - tr, r.top)
      ..cubicTo(r.right - tr + tr * _k, r.top, r.right, r.top + tr - tr * _k,
          r.right, r.top + tr)
      ..lineTo(r.right, r.bottom - br)
      ..cubicTo(r.right, r.bottom - br + br * _k, r.right - br + br * _k,
          r.bottom, r.right - br, r.bottom)
      ..lineTo(r.left + bl, r.bottom)
      ..cubicTo(r.left + bl - bl * _k, r.bottom, r.left,
          r.bottom - bl + bl * _k, r.left, r.bottom - bl)
      ..lineTo(r.left, r.top + tl)
      ..cubicTo(r.left, r.top + tl - tl * _k, r.left + tl - tl * _k, r.top,
          r.left + tl, r.top);
  }
}

void _fillRounded(
  DisplayList list,
  Rect rect,
  BorderRadius radius,
  Color color,
) {
  final int paint = list.addPaint(colorArgb: color.value, antiAlias: true);
  final _Corners c = _Corners(rect, radius);
  if (c.tl == 0 && c.tr == 0 && c.br == 0 && c.bl == 0) {
    list.drawRectangle(rect, paint);
    return;
  }
  if (c.tl == c.tr && c.tr == c.br && c.br == c.bl) {
    list.drawRRectUniform(
        rect.left, rect.top, rect.right, rect.bottom, c.tl, c.tl, paint);
    return;
  }
  final PathBuilder path = PathBuilder()..moveTo(rect.left + c.tl, rect.top);
  c.around(path);
  path.close();
  list.drawPath(list.addPath(path.build()), paint);
}

// ---------------------------------------------------------------------------
// The decoration
// ---------------------------------------------------------------------------

/// When the label moves from inside the field to above it.
enum FloatingLabelBehavior {
  /// Never: the label is a placeholder, and disappears once there is text.
  never,

  /// When the field is focused or has text.
  auto,

  /// Always above the field.
  always,
}

/// What a decorated field shows around its text - Flutter's
/// `InputDecoration`. See the library comment for what is drawn and how it
/// differs.
class InputDecoration {
  const InputDecoration({
    this.icon,
    this.iconColor,
    this.labelText,
    this.labelStyle,
    this.floatingLabelStyle,
    this.helper,
    this.helperText,
    this.helperStyle,
    this.helperMaxLines,
    this.hintText,
    this.hintStyle,
    this.hintMaxLines,
    this.error,
    this.errorText,
    this.errorStyle,
    this.errorMaxLines,
    this.floatingLabelBehavior,
    this.isCollapsed,
    this.isDense,
    this.contentPadding,
    this.prefixIcon,
    this.prefix,
    this.prefixText,
    this.prefixStyle,
    this.prefixIconColor,
    this.suffixIcon,
    this.suffix,
    this.suffixText,
    this.suffixStyle,
    this.suffixIconColor,
    this.counter,
    this.counterText,
    this.counterStyle,
    this.filled,
    this.fillColor,
    this.hoverColor,
    this.errorBorder,
    this.focusedBorder,
    this.focusedErrorBorder,
    this.disabledBorder,
    this.enabledBorder,
    this.border,
    this.enabled = true,
    this.semanticCounterText,
    this.constraints,
  });

  /// Only the borders and the fill: no label, no helper, no padding - for a
  /// field placed inside something that already looks like one.
  const InputDecoration.collapsed({
    required this.hintText,
    this.floatingLabelBehavior,
    this.hintStyle,
    this.filled = false,
    this.fillColor,
    this.hoverColor,
    this.border = InputBorder.none,
    this.enabled = true,
    this.constraints,
  })  : icon = null,
        iconColor = null,
        labelText = null,
        labelStyle = null,
        floatingLabelStyle = null,
        helper = null,
        helperText = null,
        helperStyle = null,
        helperMaxLines = null,
        hintMaxLines = null,
        error = null,
        errorText = null,
        errorStyle = null,
        errorMaxLines = null,
        isCollapsed = true,
        isDense = false,
        contentPadding = null,
        prefixIcon = null,
        prefix = null,
        prefixText = null,
        prefixStyle = null,
        prefixIconColor = null,
        suffixIcon = null,
        suffix = null,
        suffixText = null,
        suffixStyle = null,
        suffixIconColor = null,
        counter = null,
        counterText = null,
        counterStyle = null,
        errorBorder = null,
        focusedBorder = null,
        focusedErrorBorder = null,
        disabledBorder = null,
        enabledBorder = null,
        semanticCounterText = null;

  /// Shown before the field, outside its border.
  final Widget? icon;
  final Color? iconColor;

  /// The field's caption: inside it while it is empty and unfocused, above
  /// it otherwise ([floatingLabelBehavior]).
  final String? labelText;
  final TextStyle? labelStyle;
  final TextStyle? floatingLabelStyle;

  /// Below the field when there is no error: a widget, or [helperText].
  final Widget? helper;
  final String? helperText;
  final TextStyle? helperStyle;
  final int? helperMaxLines;

  /// Shown inside the empty field while the label is above it, or when there
  /// is no label.
  final String? hintText;
  final TextStyle? hintStyle;
  final int? hintMaxLines;

  /// Below the field in the error colour, in place of the helper; also
  /// turns the border to the error colour. An empty [errorText] does that
  /// without a message.
  final Widget? error;
  final String? errorText;
  final TextStyle? errorStyle;
  final int? errorMaxLines;

  /// When the label floats; null is [FloatingLabelBehavior.auto].
  final FloatingLabelBehavior? floatingLabelBehavior;

  /// No padding, no label space: the field is only its text.
  final bool? isCollapsed;

  /// A tighter field.
  final bool? isDense;

  /// Space between the border and the text row. Null is the theme's.
  final EdgeInsetsGeometry? contentPadding;

  /// Inside the border, before the text.
  final Widget? prefixIcon;

  /// Before the text, shown while the field is focused or has text.
  final Widget? prefix;
  final String? prefixText;
  final TextStyle? prefixStyle;
  final Color? prefixIconColor;

  /// Inside the border, after the text.
  final Widget? suffixIcon;

  /// After the text, shown while the field is focused or has text.
  final Widget? suffix;
  final String? suffixText;
  final TextStyle? suffixStyle;
  final Color? suffixIconColor;

  /// Below the field at the end: a widget, or [counterText]. A field with a
  /// `maxLength` fills [counterText] in itself unless it is given.
  final Widget? counter;
  final String? counterText;
  final TextStyle? counterStyle;

  /// Whether the box is filled with [fillColor]. The theme's own field - no
  /// [border] - is always filled.
  final bool? filled;
  final Color? fillColor;

  /// The fill while the pointer is over a filled field.
  final Color? hoverColor;

  /// The border in each state; each falls back to [border], recoloured.
  final InputBorder? errorBorder;
  final InputBorder? focusedBorder;
  final InputBorder? focusedErrorBorder;
  final InputBorder? disabledBorder;
  final InputBorder? enabledBorder;

  /// The shape of the border. Null is the theme's own field.
  final InputBorder? border;

  /// Whether the field looks enabled. A `TextField` is disabled when either
  /// it or this says so.
  final bool enabled;

  /// What a screen reader reads for the counter.
  final String? semanticCounterText;

  /// Bounds on the decorator's size.
  final BoxConstraints? constraints;

  /// Whether there is an error to show - [errorText], even empty, or
  /// [error].
  bool get hasError => errorText != null || error != null;

  InputDecoration copyWith({
    Widget? icon,
    Color? iconColor,
    String? labelText,
    TextStyle? labelStyle,
    TextStyle? floatingLabelStyle,
    Widget? helper,
    String? helperText,
    TextStyle? helperStyle,
    int? helperMaxLines,
    String? hintText,
    TextStyle? hintStyle,
    int? hintMaxLines,
    Widget? error,
    String? errorText,
    TextStyle? errorStyle,
    int? errorMaxLines,
    FloatingLabelBehavior? floatingLabelBehavior,
    bool? isCollapsed,
    bool? isDense,
    EdgeInsetsGeometry? contentPadding,
    Widget? prefixIcon,
    Widget? prefix,
    String? prefixText,
    TextStyle? prefixStyle,
    Color? prefixIconColor,
    Widget? suffixIcon,
    Widget? suffix,
    String? suffixText,
    TextStyle? suffixStyle,
    Color? suffixIconColor,
    Widget? counter,
    String? counterText,
    TextStyle? counterStyle,
    bool? filled,
    Color? fillColor,
    Color? hoverColor,
    InputBorder? errorBorder,
    InputBorder? focusedBorder,
    InputBorder? focusedErrorBorder,
    InputBorder? disabledBorder,
    InputBorder? enabledBorder,
    InputBorder? border,
    bool? enabled,
    String? semanticCounterText,
    BoxConstraints? constraints,
  }) =>
      InputDecoration(
        icon: icon ?? this.icon,
        iconColor: iconColor ?? this.iconColor,
        labelText: labelText ?? this.labelText,
        labelStyle: labelStyle ?? this.labelStyle,
        floatingLabelStyle: floatingLabelStyle ?? this.floatingLabelStyle,
        helper: helper ?? this.helper,
        helperText: helperText ?? this.helperText,
        helperStyle: helperStyle ?? this.helperStyle,
        helperMaxLines: helperMaxLines ?? this.helperMaxLines,
        hintText: hintText ?? this.hintText,
        hintStyle: hintStyle ?? this.hintStyle,
        hintMaxLines: hintMaxLines ?? this.hintMaxLines,
        error: error ?? this.error,
        errorText: errorText ?? this.errorText,
        errorStyle: errorStyle ?? this.errorStyle,
        errorMaxLines: errorMaxLines ?? this.errorMaxLines,
        floatingLabelBehavior:
            floatingLabelBehavior ?? this.floatingLabelBehavior,
        isCollapsed: isCollapsed ?? this.isCollapsed,
        isDense: isDense ?? this.isDense,
        contentPadding: contentPadding ?? this.contentPadding,
        prefixIcon: prefixIcon ?? this.prefixIcon,
        prefix: prefix ?? this.prefix,
        prefixText: prefixText ?? this.prefixText,
        prefixStyle: prefixStyle ?? this.prefixStyle,
        prefixIconColor: prefixIconColor ?? this.prefixIconColor,
        suffixIcon: suffixIcon ?? this.suffixIcon,
        suffix: suffix ?? this.suffix,
        suffixText: suffixText ?? this.suffixText,
        suffixStyle: suffixStyle ?? this.suffixStyle,
        suffixIconColor: suffixIconColor ?? this.suffixIconColor,
        counter: counter ?? this.counter,
        counterText: counterText ?? this.counterText,
        counterStyle: counterStyle ?? this.counterStyle,
        filled: filled ?? this.filled,
        fillColor: fillColor ?? this.fillColor,
        hoverColor: hoverColor ?? this.hoverColor,
        errorBorder: errorBorder ?? this.errorBorder,
        focusedBorder: focusedBorder ?? this.focusedBorder,
        focusedErrorBorder: focusedErrorBorder ?? this.focusedErrorBorder,
        disabledBorder: disabledBorder ?? this.disabledBorder,
        enabledBorder: enabledBorder ?? this.enabledBorder,
        border: border ?? this.border,
        enabled: enabled ?? this.enabled,
        semanticCounterText: semanticCounterText ?? this.semanticCounterText,
        constraints: constraints ?? this.constraints,
      );

  @override
  String toString() => 'InputDecoration('
      '${<String>[
        if (labelText != null) 'labelText: "$labelText"',
        if (hintText != null) 'hintText: "$hintText"',
        if (helperText != null) 'helperText: "$helperText"',
        if (errorText != null) 'errorText: "$errorText"',
        if (counterText != null) 'counterText: "$counterText"',
        if (border != null) 'border: $border',
        if (!enabled) 'enabled: false',
      ].join(', ')})';
}

// ---------------------------------------------------------------------------
// The decorator
// ---------------------------------------------------------------------------

/// Draws an [InputDecoration] around [child] - Flutter's `InputDecorator`.
///
/// `TextField` uses one when it is given a decoration; it can also wrap any
/// control that should look like a field - a read-only value with a
/// dropdown arrow, say - in which case it draws the label resting inside the
/// field and the hint itself while [isEmpty].
class InputDecorator extends StatelessWidget {
  const InputDecorator({
    super.key,
    required this.decoration,
    this.baseStyle,
    this.isFocused = false,
    this.isHovering = false,
    this.isEmpty = false,
    this.child,
  });

  final InputDecoration decoration;

  /// The style of the text in the field; its size is what the resting label
  /// and the hint are drawn at.
  final TextStyle? baseStyle;

  /// Whether the field has the keyboard: floats the label and draws the
  /// focused border.
  final bool isFocused;

  /// Whether to draw the hover state; the decorator also follows the pointer
  /// itself.
  final bool isHovering;

  /// Whether the field has no text: the label rests inside it and the hint
  /// shows.
  final bool isEmpty;

  /// The input itself.
  final Widget? child;

  @override
  Widget build(BuildContext context) => DecoratedField(
        decoration: decoration,
        isFocused: isFocused,
        isHovering: isHovering,
        isEmpty: isEmpty,
        childIsField: false,
        baseStyle: baseStyle,
        child: child ?? const SizedBox(),
      );
}

/// The body of [InputDecorator], with one switch `TextField` needs:
/// [childIsField] says the child is a field that draws its own placeholder and
/// pads its own text, so the decorator neither draws the resting label nor
/// adds horizontal padding.
///
/// Framework-internal: public so `text_field.dart` can reach it, and hidden
/// from the package's exports.
final class DecoratedField extends StatelessWidget {
  const DecoratedField({
    super.key,
    required this.decoration,
    required this.isFocused,
    required this.isHovering,
    required this.isEmpty,
    required this.childIsField,
    this.baseStyle,
    required this.child,
  });

  final InputDecoration decoration;
  final bool isFocused;
  final bool isHovering;
  final bool isEmpty;
  final bool childIsField;
  final TextStyle? baseStyle;
  final Widget child;

  /// Whether [decoration]'s label is above the field rather than in it.
  static bool labelFloats(
    InputDecoration decoration, {
    required bool isFocused,
    required bool isEmpty,
  }) =>
      switch (decoration.floatingLabelBehavior ?? FloatingLabelBehavior.auto) {
        FloatingLabelBehavior.never => false,
        FloatingLabelBehavior.always => true,
        FloatingLabelBehavior.auto => isFocused || !isEmpty,
      };

  /// The placeholder a field child shows while empty: the label while it
  /// rests inside, the hint once it has floated - or when there is no label.
  static String placeholderFor(
    InputDecoration decoration, {
    required bool isFocused,
    required bool isEmpty,
  }) {
    final String? label = decoration.labelText;
    if (label != null &&
        !labelFloats(decoration, isFocused: isFocused, isEmpty: isEmpty) &&
        (decoration.floatingLabelBehavior ?? FloatingLabelBehavior.auto) !=
            FloatingLabelBehavior.always) {
      return label;
    }
    return decoration.hintText ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final InputDecoration d = decoration;
    final bool enabled = d.enabled;
    final bool hasError = d.hasError;
    final bool affixVisible = !isEmpty || isFocused;
    final Color secondary =
        enabled ? theme.foregroundSecondary : theme.disabledForeground;
    final double small = math.max(9.0, (theme.fontSize * 0.85).roundToDouble());

    Widget affixText(String text, TextStyle? style) => Opacity(
          opacity: affixVisible ? 1.0 : 0.0,
          child: Text(text, style: style, color: style?.color ?? secondary),
        );

    Widget iconSlot(Widget icon, Color? color, {required bool leading}) =>
        IconTheme(
          data: IconThemeData(
              color: color ??
                  (hasError && !leading ? theme.colorScheme.error : secondary)),
          child: Padding(
            padding: EdgeInsets.only(
              left: leading ? 8 : 2,
              right: leading ? 2 : 8,
            ),
            child: icon,
          ),
        );

    final bool collapsed = d.isCollapsed ?? false;
    final double textPad = theme.effectiveControlPadding;
    final Widget? prefix = d.prefix ??
        (d.prefixText == null ? null : affixText(d.prefixText!, d.prefixStyle));
    final Widget? suffix = d.suffix ??
        (d.suffixText == null ? null : affixText(d.suffixText!, d.suffixStyle));
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (d.prefixIcon != null)
          iconSlot(d.prefixIcon!, d.prefixIconColor, leading: true),
        if (prefix != null)
          Padding(
            // The field pads its own text, so the prefix is moved in to
            // where the text would have started and the field's padding
            // becomes the space between the two.
            padding: EdgeInsets.only(
              left: childIsField && d.prefixIcon == null ? textPad : 0,
            ),
            child: prefix,
          ),
        Expanded(child: _InputSlot(child: child)),
        if (suffix != null)
          Padding(
            padding: EdgeInsets.only(
              right: childIsField && d.suffixIcon == null ? textPad : 0,
            ),
            child: suffix,
          ),
        if (d.suffixIcon != null)
          iconSlot(d.suffixIcon!, d.suffixIconColor, leading: false),
      ],
    );

    final Widget frame = _InputFrame(
      decoration: d,
      theme: theme,
      isFocused: isFocused,
      isHovering: isHovering,
      isEmpty: isEmpty,
      childIsField: childIsField,
      baseFontSize: baseStyle?.fontSize ?? theme.fontSize,
      labelFontSize: small,
      child: row,
    );

    // Below the field: the error in place of the helper, and the counter at
    // the end.
    final Widget? message = hasError
        ? (d.error ??
            (d.errorText!.isEmpty
                ? null
                : Text(
                    d.errorText!,
                    style: d.errorStyle,
                    fontSize: d.errorStyle?.fontSize ?? small,
                    color: d.errorStyle?.color ?? theme.colorScheme.error,
                    softWrap: true,
                    maxLines: d.errorMaxLines,
                    ellipsis: d.errorMaxLines == null ? null : '…',
                  )))
        : (d.helper ??
            (d.helperText == null
                ? null
                : Text(
                    d.helperText!,
                    style: d.helperStyle,
                    fontSize: d.helperStyle?.fontSize ?? small,
                    color: d.helperStyle?.color ?? secondary,
                    softWrap: true,
                    maxLines: d.helperMaxLines,
                    ellipsis: d.helperMaxLines == null ? null : '…',
                  )));
    final Widget? counter = d.counter ??
        (d.counterText == null || d.counterText!.isEmpty
            ? null
            : Text(
                d.counterText!,
                style: d.counterStyle,
                fontSize: d.counterStyle?.fontSize ?? small,
                color: d.counterStyle?.color ?? secondary,
              ));

    Widget result = frame;
    if (!collapsed && (message != null || counter != null)) {
      final double indent = d.border is OutlineInputBorder ||
              d.border is UnderlineInputBorder ||
              d.border == InputBorder.none
          ? textPad
          : 2;
      result = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          frame,
          Padding(
            padding: EdgeInsets.only(left: indent, right: indent, top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: message ?? const SizedBox()),
                if (counter != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: counter,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    if (d.icon != null) {
      result = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(
              right: 12,
              top: (theme.effectiveControlHeight - kDefaultIconSize) / 2 +
                  (d.labelText != null ? small : 0),
            ),
            child: IconTheme(
              data: IconThemeData(color: d.iconColor ?? secondary),
              child: d.icon!,
            ),
          ),
          Expanded(child: result),
        ],
      );
    }
    return LimitedBox(maxWidth: 240, child: result);
  }
}

/// Marks where the input sits, so the frame can draw a resting label and a
/// hint over it when the input does not draw its own.
final class _InputSlot extends SingleChildRenderObjectWidget {
  const _InputSlot({super.child});

  @override
  _RenderInputSlot createRenderObject(BuildContext context) =>
      _RenderInputSlot();
}

final class _RenderInputSlot extends RenderSingleChildBox {
  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = child.size;
  }
}

final class _InputFrame extends SingleChildRenderObjectWidget {
  const _InputFrame({
    required this.decoration,
    required this.theme,
    required this.isFocused,
    required this.isHovering,
    required this.isEmpty,
    required this.childIsField,
    required this.baseFontSize,
    required this.labelFontSize,
    super.child,
  });

  final InputDecoration decoration;
  final ThemeData theme;
  final bool isFocused;
  final bool isHovering;
  final bool isEmpty;
  final bool childIsField;
  final double baseFontSize;
  final double labelFontSize;

  @override
  RenderInputDecorator createRenderObject(BuildContext context) =>
      RenderInputDecorator(
        decoration: decoration,
        theme: theme,
        isFocused: isFocused,
        isHovering: isHovering,
        isEmpty: isEmpty,
        childIsField: childIsField,
        baseFontSize: baseFontSize,
        labelFontSize: labelFontSize,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderInputDecorator renderObject,
  ) {
    renderObject
      ..decoration = decoration
      ..theme = theme
      ..isFocused = isFocused
      ..isHovering = isHovering
      ..isEmpty = isEmpty
      ..childIsField = childIsField
      ..baseFontSize = baseFontSize
      ..labelFontSize = labelFontSize;
  }
}

/// The box of a decorated field: fill, border, floating label, and the row
/// of prefix, input and suffix inside.
///
/// Framework-internal; exposed for tests that read [labelIsFloating] and
/// [effectiveBorder].
final class RenderInputDecorator extends RenderSingleChildBox
    implements HoverEventTarget {
  RenderInputDecorator({
    required InputDecoration decoration,
    required ThemeData theme,
    required bool isFocused,
    required bool isHovering,
    required bool isEmpty,
    required bool childIsField,
    required double baseFontSize,
    required double labelFontSize,
  })  : _decoration = decoration,
        _theme = theme,
        _isFocused = isFocused,
        _isHovering = isHovering,
        _isEmpty = isEmpty,
        _childIsField = childIsField,
        _baseFontSize = baseFontSize,
        _labelFontSize = labelFontSize;

  InputDecoration _decoration;
  InputDecoration get decoration => _decoration;
  set decoration(InputDecoration value) {
    if (identical(value, _decoration)) return;
    _decoration = value;
    markNeedsLayout();
  }

  ThemeData _theme;
  set theme(ThemeData value) {
    if (value == _theme) return;
    _theme = value;
    markNeedsLayout();
  }

  bool _isFocused;
  set isFocused(bool value) {
    if (value == _isFocused) return;
    _isFocused = value;
    markNeedsPaint();
  }

  bool _isHovering;
  set isHovering(bool value) {
    if (value == _isHovering) return;
    _isHovering = value;
    markNeedsPaint();
  }

  bool _isEmpty;
  set isEmpty(bool value) {
    if (value == _isEmpty) return;
    _isEmpty = value;
    markNeedsPaint();
  }

  bool _childIsField;
  set childIsField(bool value) {
    if (value == _childIsField) return;
    _childIsField = value;
    markNeedsLayout();
  }

  double _baseFontSize;
  set baseFontSize(double value) {
    if (value == _baseFontSize) return;
    _baseFontSize = value;
    markNeedsPaint();
  }

  double _labelFontSize;
  set labelFontSize(double value) {
    if (value == _labelFontSize) return;
    _labelFontSize = value;
    markNeedsLayout();
  }

  bool _pointerOver = false;

  @override
  void handleHoverChanged(bool hovered) {
    if (hovered == _pointerOver) return;
    _pointerOver = hovered;
    markNeedsPaint();
  }

  bool get _hovered => (_isHovering || _pointerOver) && _decoration.enabled;

  bool get _collapsed => _decoration.isCollapsed ?? false;

  bool get _hasLabel => _decoration.labelText != null && !_collapsed;

  /// Whether the label is drawn above the field rather than resting in it.
  bool get labelIsFloating =>
      _hasLabel &&
      DecoratedField.labelFloats(_decoration,
          isFocused: _isFocused, isEmpty: _isEmpty);

  ScaledTypeface? get _labelFont =>
      FontRegistry.instance.uiFont(_labelFontSize);

  double get _labelHeight =>
      _labelFont?.lineHeight ??
      FontRegistry.estimatedLineHeight(_labelFontSize);

  /// The shape the field's border is drawn in, before the state picks a
  /// colour: the theme's own box when the decoration names none.
  InputBorder get _shape =>
      _decoration.border ??
      _ThemeInputBorder(_theme.cornerRadius, borderSide: const BorderSide());

  bool get _themeBox => _decoration.border == null;

  /// The border drawn right now, with the colour and width the state gives
  /// it - Flutter's resolution: a per-state border as it is, else [border]
  /// recoloured.
  InputBorder get effectiveBorder {
    final InputDecoration d = _decoration;
    final bool error = d.hasError;
    final InputBorder? specific = !d.enabled
        ? (error ? d.errorBorder : d.disabledBorder)
        : _isFocused
            ? (error ? d.focusedErrorBorder ?? d.errorBorder : d.focusedBorder)
            : (error ? d.errorBorder : d.enabledBorder);
    if (specific != null) return specific;
    final InputBorder shape = _shape;
    if (shape.borderSide == BorderSide.none) return shape;
    final bool focused = _isFocused && d.enabled;
    final Color color = !d.enabled
        ? _theme.disabledForeground
        : error
            ? _theme.colorScheme.error
            : focused
                ? _theme.accent
                : _hovered
                    ? (_themeBox
                        ? _theme.foregroundSecondary
                        : _theme.foreground)
                    : _theme.borderStrong;
    final double width = focused ? (_themeBox ? 1.5 : 2.0) : 1.0;
    return shape.copyWith(borderSide: BorderSide(color: color, width: width));
  }

  EdgeInsets get _padding {
    final EdgeInsetsGeometry? given = _decoration.contentPadding;
    if (given != null) return given.resolve(TextDirection.leftToRight);
    if (_collapsed) return EdgeInsets.zero;
    // A field child pads its own text; anything else is padded here to the
    // same place.
    final double h = _childIsField ? 0 : _theme.effectiveControlPadding;
    return EdgeInsets.symmetric(horizontal: h);
  }

  /// Above the box: room for the label when it floats outside the box.
  double get _topReserve {
    if (!_hasLabel) return 0;
    if (_themeBox) return _labelHeight + 4;
    if (_shape.isOutline) return (_labelHeight / 2).roundToDouble();
    return 0;
  }

  /// Inside the box, above the text row: where an underlined field's label
  /// floats.
  double get _innerTop {
    if (!_hasLabel || _themeBox) return 0;
    if (_shape.isOutline) return 2;
    return _labelHeight - ((_decoration.isDense ?? false) ? 4 : 2);
  }

  double get _minBoxHeight {
    if (_collapsed) return 0;
    final double base = _theme.effectiveControlHeight -
        ((_decoration.isDense ?? false) ? 4 : 0);
    return base + _innerTop;
  }

  /// The box the border is drawn round, in local coordinates.
  Rect get boxRect =>
      Rect.fromLTWH(0, _topReserve, size.width, size.height - _topReserve);

  @override
  void performLayout() {
    final BoxConstraints? limits = _decoration.constraints;
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : math.max(constraints.minWidth, limits?.minWidth ?? 0);
    final EdgeInsets pad = _padding;
    final double inner = math.max(0.0, width - pad.horizontal);
    final RenderBox? child = this.child;
    double childHeight = 0;
    if (child != null) {
      child.layout(
        BoxConstraints(minWidth: inner, maxWidth: inner),
        parentUsesSize: true,
      );
      childHeight = child.size.height;
    }
    final double box = math.max(
      _minBoxHeight,
      childHeight + pad.vertical + _innerTop,
    );
    if (child != null) {
      // Centred in what is left of the box below the label space.
      final double free = box - _innerTop - pad.vertical - childHeight;
      child.parentData!.offset = Offset(
        pad.left,
        _topReserve + _innerTop + pad.top + math.max(0.0, free / 2),
      );
    }
    size = constraints.constrain(Size(width, _topReserve + box));
  }

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
        _topReserve + _minBoxHeight,
        _topReserve +
            _innerTop +
            _padding.vertical +
            (child?.getMinIntrinsicHeight(width) ?? 0),
      );

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  /// The input's rectangle in local coordinates, found through the slot.
  Rect? _inputRect() {
    _RenderInputSlot? slot;
    void find(RenderBox node) {
      if (slot != null) return;
      if (node is _RenderInputSlot) {
        slot = node;
        return;
      }
      node.visitChildren(find);
    }

    final RenderBox? child = this.child;
    if (child == null) return null;
    find(child);
    final _RenderInputSlot? found = slot;
    if (found == null || !found.hasSize) return null;
    Offset at = Offset.zero;
    for (RenderBox? node = found;
        node != null && !identical(node, this);
        node = node.parent) {
      at = at + node.offsetFromParent;
    }
    return Rect.fromLTWH(at.dx, at.dy, found.size.width, found.size.height);
  }

  Color _labelColor({required bool floating}) {
    final InputDecoration d = _decoration;
    final Color? styled =
        floating ? (d.floatingLabelStyle?.color ?? d.labelStyle?.color) : null;
    if (styled != null) return styled;
    if (!d.enabled) return _theme.disabledForeground;
    if (d.hasError && floating) return _theme.colorScheme.error;
    if (_isFocused && floating) return _theme.accent;
    return d.labelStyle?.color ?? _theme.foregroundSecondary;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    final Rect box = boxRect.shift(offset);
    final InputDecoration d = _decoration;
    final InputBorder border = effectiveBorder;

    // The fill.
    if (_themeBox || (d.filled ?? false)) {
      final Color fill = !d.enabled
          ? _theme.disabledSurface
          : _hovered && d.hoverColor != null
              ? d.hoverColor!
              : d.fillColor ?? _theme.surfaceAlternate;
      border.paintFill(list, box, fill);
    }

    final RenderBox? child = this.child;
    if (child != null) paintChild(list, child, offset);

    // The label: floating above (or in the outline's gap), or resting where
    // the text would be when the input does not draw it itself.
    final String? label = _hasLabel ? d.labelText : null;
    final ScaledTypeface? font = _labelFont;
    double? gapStart;
    double gapExtent = 0;
    if (label != null && font != null && labelIsFloating) {
      final GlyphRun run = uiTextPainter.shapeRun(label, font);
      final double maxWidth = math.max(0.0, size.width - 24);
      final double labelWidth = math.min(run.width, maxWidth);
      final double x;
      final double y;
      if (_themeBox) {
        x = box.left + 2;
        y = offset.dy;
      } else if (border.isOutline) {
        final double gapPadding =
            border is OutlineInputBorder ? border.gapPadding : 4.0;
        x = box.left + math.max(_theme.effectiveControlPadding, 12);
        y = box.top - _labelHeight / 2;
        gapStart = x - box.left - gapPadding;
        gapExtent = labelWidth + gapPadding * 2;
      } else {
        x = box.left + _theme.effectiveControlPadding;
        y = box.top + 2;
      }
      _paintRun(
          list, run, font, Offset(x, y), _labelColor(floating: true), maxWidth);
    }
    border.paint(
      list,
      box,
      gapStart: gapStart,
      gapExtent: gapExtent,
      gapPercentage: gapStart == null ? 0 : 1,
    );

    if (!_childIsField) {
      // A plain child: the resting label or the hint, over the input while
      // the field is empty.
      final String? resting = label != null && !labelIsFloating
          ? (_isEmpty ? label : null)
          : (_isEmpty ? d.hintText : null);
      final ScaledTypeface? base = FontRegistry.instance.uiFont(_baseFontSize);
      final Rect? input = _inputRect();
      if (resting != null && base != null && input != null) {
        final GlyphRun run = uiTextPainter.shapeRun(resting, base);
        _paintRun(
          list,
          run,
          base,
          Offset(offset.dx + input.left,
              offset.dy + input.center.dy - base.lineHeight / 2),
          d.hintStyle?.color ?? _theme.foregroundSecondary,
          input.width,
        );
      }
    }
  }

  static void _paintRun(
    DisplayList list,
    GlyphRun run,
    ScaledTypeface font,
    Offset topLeft,
    Color color,
    double maxWidth,
  ) {
    final bool clip = run.width > maxWidth;
    if (clip) {
      list
        ..save()
        ..clipRectangle(
            Rect.fromLTWH(topLeft.dx, topLeft.dy, maxWidth, font.lineHeight));
    }
    uiTextPainter.emitRun(
      list,
      run,
      Offset(topLeft.dx, topLeft.dy + font.ascent),
      list.addPaint(colorArgb: color.value, antiAlias: true),
    );
    if (clip) list.restore();
  }
}
