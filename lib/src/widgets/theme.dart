/// Themes and control templates.
///
/// A theme is three things bundled so a subtree can be restyled at one point:
/// a palette and metrics ([ThemeData]), a resource dictionary for anything the
/// palette does not name, and a rule set ([Styles]). Section 28.6 requires at
/// least a neutral base, a Fluent-like variant, high contrast, dark/light and
/// a density switch, all built from framework values rather than copied
/// proprietary assets.
///
/// Templates (section 28.5) are the other half of "no appearance in the
/// control": the control publishes properties and states, and a
/// [ControlTemplate] turns them into a visual subtree.
library;

import '../rendering/text/font_registry.dart';
import 'style.dart';
import 'widget.dart';

/// How tightly controls are packed. Compact removes padding and height, and
/// nothing else, so a layout does not reflow into a different shape.
enum ThemeDensity {
  compact,
  comfortable;

  /// The multiplier applied to a control's default height and padding.
  double get scale => this == ThemeDensity.compact ? 0.82 : 1.0;
}

enum ThemeBrightness { light, dark }

/// The named palette and metrics of one theme.
///
/// Colours are 0xAARRGGBB, matching the display list. They are plain ints on
/// purpose: a colour class would add an allocation to every paint call for a
/// value the rasterizer immediately decomposes again.
final class ThemeData {
  const ThemeData({
    required this.name,
    required this.brightness,
    required this.accent,
    required this.accentPressed,
    required this.accentHovered,
    required this.surface,
    required this.surfaceAlternate,
    required this.border,
    required this.foreground,
    required this.foregroundSecondary,
    required this.disabledForeground,
    required this.disabledSurface,
    required this.focusRing,
    required this.selection,
    this.density = ThemeDensity.comfortable,
    this.highContrast = false,
    this.cornerRadius = 3.0,
    this.controlHeight = 28.0,
    this.controlPadding = 8.0,
    this.focusRingWidth = 2.0,
    this.fontSize = kDefaultUiFontSize,
  });

  final String name;
  final ThemeBrightness brightness;

  final int accent;
  final int accentPressed;
  final int accentHovered;
  final int surface;
  final int surfaceAlternate;
  final int border;
  final int foreground;
  final int foregroundSecondary;
  final int disabledForeground;
  final int disabledSurface;
  final int focusRing;
  final int selection;

  final ThemeDensity density;

  /// High contrast is a distinct flag rather than another palette name,
  /// because it changes *rules* as well as colours: focus rings widen and
  /// borders stop being optional.
  final bool highContrast;

  final double cornerRadius;
  final double controlHeight;
  final double controlPadding;
  final double focusRingWidth;

  /// The pixel size interface text is drawn at.
  ///
  /// A size and not a face: a face is parsed bytes and could not live in a
  /// `const` theme, so [FontRegistry] resolves it and this says how big to draw
  /// it. Unscaled by [density] on purpose - compact means tighter chrome, and
  /// shrinking the text with it is how a dense theme becomes an unreadable one.
  final double fontSize;

  /// The control height after density is applied.
  double get effectiveControlHeight => controlHeight * density.scale;

  /// The control padding after density is applied.
  double get effectiveControlPadding => controlPadding * density.scale;

  /// The pseudo-classes this theme contributes to every style target.
  Set<PseudoClass> get ambientStates => <PseudoClass>{
        if (brightness == ThemeBrightness.dark)
          PseudoClass.dark
        else
          PseudoClass.light,
        if (highContrast) PseudoClass.highContrast,
      };

  ThemeData copyWith({
    String? name,
    ThemeBrightness? brightness,
    ThemeDensity? density,
    bool? highContrast,
    double? cornerRadius,
    double? controlHeight,
    double? fontSize,
  }) =>
      ThemeData(
        name: name ?? this.name,
        brightness: brightness ?? this.brightness,
        accent: accent,
        accentPressed: accentPressed,
        accentHovered: accentHovered,
        surface: surface,
        surfaceAlternate: surfaceAlternate,
        border: border,
        foreground: foreground,
        foregroundSecondary: foregroundSecondary,
        disabledForeground: disabledForeground,
        disabledSurface: disabledSurface,
        focusRing: focusRing,
        selection: selection,
        density: density ?? this.density,
        highContrast: highContrast ?? this.highContrast,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        controlHeight: controlHeight ?? this.controlHeight,
        controlPadding: controlPadding,
        focusRingWidth: focusRingWidth,
        fontSize: fontSize ?? this.fontSize,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemeData &&
      other.name == name &&
      other.brightness == brightness &&
      other.accent == accent &&
      other.accentPressed == accentPressed &&
      other.accentHovered == accentHovered &&
      other.surface == surface &&
      other.surfaceAlternate == surfaceAlternate &&
      other.border == border &&
      other.foreground == foreground &&
      other.foregroundSecondary == foregroundSecondary &&
      other.disabledForeground == disabledForeground &&
      other.disabledSurface == disabledSurface &&
      other.focusRing == focusRing &&
      other.selection == selection &&
      other.density == density &&
      other.highContrast == highContrast &&
      other.cornerRadius == cornerRadius &&
      other.controlHeight == controlHeight &&
      other.controlPadding == controlPadding &&
      other.focusRingWidth == focusRingWidth &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(
        name,
        brightness,
        Object.hash(accent, accentPressed, accentHovered),
        Object.hash(surface, surfaceAlternate, border),
        Object.hash(foreground, foregroundSecondary, disabledForeground),
        Object.hash(disabledSurface, focusRing, selection),
        density,
        highContrast,
        Object.hash(
            cornerRadius, controlHeight, controlPadding, focusRingWidth),
        fontSize,
      );

  /// The neutral base: no platform's look, and the one every test uses so a
  /// golden never depends on which OS ran it.
  static const ThemeData neutralLight = ThemeData(
    name: 'neutral-light',
    brightness: ThemeBrightness.light,
    accent: 0xFF2D6CDF,
    accentPressed: 0xFF1F4FA8,
    accentHovered: 0xFF4682E8,
    surface: 0xFFF3F3F3,
    surfaceAlternate: 0xFFFFFFFF,
    border: 0xFFB8B8B8,
    foreground: 0xFF111111,
    foregroundSecondary: 0xFF555555,
    disabledForeground: 0xFF9A9A9A,
    disabledSurface: 0xFFE6E6E6,
    focusRing: 0xFF1F4FA8,
    selection: 0xFFBBD6FF,
  );

  static const ThemeData neutralDark = ThemeData(
    name: 'neutral-dark',
    brightness: ThemeBrightness.dark,
    accent: 0xFF4C8DFF,
    accentPressed: 0xFF2F6ACC,
    accentHovered: 0xFF6BA3FF,
    surface: 0xFF202020,
    surfaceAlternate: 0xFF2B2B2B,
    border: 0xFF4A4A4A,
    foreground: 0xFFF2F2F2,
    foregroundSecondary: 0xFFBFBFBF,
    disabledForeground: 0xFF6E6E6E,
    disabledSurface: 0xFF303030,
    focusRing: 0xFF8AB8FF,
    selection: 0xFF2C4E7A,
  );

  /// A Fluent-*like* light theme: squarer corners, flatter surfaces. Built
  /// from our own values; nothing is copied from a vendor resource file.
  static const ThemeData fluentLight = ThemeData(
    name: 'fluent-light',
    brightness: ThemeBrightness.light,
    accent: 0xFF0078D4,
    accentPressed: 0xFF005A9E,
    accentHovered: 0xFF106EBE,
    surface: 0xFFFAFAFA,
    surfaceAlternate: 0xFFFFFFFF,
    border: 0xFFD1D1D1,
    foreground: 0xFF201F1E,
    foregroundSecondary: 0xFF605E5C,
    disabledForeground: 0xFFA19F9D,
    disabledSurface: 0xFFF3F2F1,
    focusRing: 0xFF005A9E,
    selection: 0xFFCCE4F7,
    cornerRadius: 2.0,
    controlHeight: 32.0,
  );

  /// High contrast, per section 28.3's `high-contrast` pseudo-class: pure
  /// extremes, always-visible borders, a thicker focus ring.
  static const ThemeData highContrastDark = ThemeData(
    name: 'high-contrast-dark',
    brightness: ThemeBrightness.dark,
    accent: 0xFFFFFF00,
    accentPressed: 0xFFFFD700,
    accentHovered: 0xFFFFFF66,
    surface: 0xFF000000,
    surfaceAlternate: 0xFF000000,
    border: 0xFFFFFFFF,
    foreground: 0xFFFFFFFF,
    foregroundSecondary: 0xFFFFFFFF,
    disabledForeground: 0xFF3FF23F,
    disabledSurface: 0xFF000000,
    focusRing: 0xFFFFFF00,
    selection: 0xFF1AEBFF,
    highContrast: true,
    focusRingWidth: 3.0,
  );
}

/// Builds a control's visual subtree from the control itself.
///
/// [T] is the control type, so the builder receives it typed and can read its
/// published properties without a cast. This is the mechanism section 28.5
/// sketches; a control declares a default template and a theme may replace it.
final class ControlTemplate<T extends Widget> {
  const ControlTemplate(this.builder);

  final Widget Function(BuildContext context, T control) builder;

  Widget build(BuildContext context, T control) => builder(context, control);
}

/// A theme's replaceable templates, keyed by the control type they target.
final class TemplateRegistry {
  TemplateRegistry([Map<Type, ControlTemplate<Widget>>? templates, this.parent])
      : _templates = <Type, ControlTemplate<Widget>>{...?templates};

  final Map<Type, ControlTemplate<Widget>> _templates;
  final TemplateRegistry? parent;

  void register<T extends Widget>(ControlTemplate<T> template) {
    _templates[T] = ControlTemplate<Widget>(
      (BuildContext context, Widget control) =>
          template.build(context, control as T),
    );
  }

  /// The template for [T], innermost registry first, or null to use the
  /// control's own default.
  ControlTemplate<Widget>? find(Type type) =>
      _templates[type] ?? parent?.find(type);
}

/// Publishes a theme, its styles, its resources and its templates to a
/// subtree.
///
/// One inherited widget rather than four, because they change together: a
/// theme swap that updated the palette but left the old rules matching would
/// produce a half-restyled frame.
final class Theme extends InheritedWidget {
  Theme({
    super.key,
    required this.data,
    Styles? styles,
    ResourceDictionary? resources,
    TemplateRegistry? templates,
    required super.child,
  })  : styles = styles ?? Styles(),
        resources = resources ?? ResourceDictionary(),
        templates = templates ?? TemplateRegistry();

  final ThemeData data;
  final Styles styles;
  final ResourceDictionary resources;
  final TemplateRegistry templates;

  /// The nearest theme, or [ThemeData.neutralLight] when none is installed.
  ///
  /// Never throws: a control must be usable outside an application shell -
  /// that is what makes a widget test able to mount one control alone.
  static ThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Theme>()?.data ??
      ThemeData.neutralLight;

  /// The nearest theme widget itself, for styles/resources/templates.
  static Theme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Theme>();

  @override
  bool updateShouldNotify(Theme oldWidget) =>
      data != oldWidget.data ||
      !identical(styles, oldWidget.styles) ||
      !identical(resources, oldWidget.resources) ||
      !identical(templates, oldWidget.templates);
}
