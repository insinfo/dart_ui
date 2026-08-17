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

import '../graphics/color.dart';
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

/// Whether a theme uses a light or dark colour palette.
///
/// The name intentionally matches Flutter's public contract so widgets can be
/// ported without translating an otherwise identical enum at every boundary.
enum Brightness { light, dark }

/// Compatibility spelling used by the first pre-release dart_ui themes.
typedef ThemeBrightness = Brightness;

/// Material-style semantic colours used by widgets that should not need to
/// know the framework's older palette field names.
final class ColorScheme {
  const ColorScheme({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.surface,
    required this.onSurface,
    required this.surfaceContainer,
    required this.outline,
    required this.error,
    required this.onError,
  });

  const ColorScheme.light({
    this.primary = const Color(0xFF2563EB),
    this.onPrimary = const Color(0xFFFFFFFF),
    this.surface = const Color(0xFFFFFFFF),
    this.onSurface = const Color(0xFF172033),
    this.surfaceContainer = const Color(0xFFF1F5F9),
    this.outline = const Color(0xFFCBD5E1),
    this.error = const Color(0xFFB3261E),
    this.onError = const Color(0xFFFFFFFF),
  }) : brightness = Brightness.light;

  const ColorScheme.dark({
    this.primary = const Color(0xFF8AB4FF),
    this.onPrimary = const Color(0xFF002E69),
    this.surface = const Color(0xFF111827),
    this.onSurface = const Color(0xFFF1F5F9),
    this.surfaceContainer = const Color(0xFF1F2937),
    this.outline = const Color(0xFF475569),
    this.error = const Color(0xFFFFB4AB),
    this.onError = const Color(0xFF690005),
  }) : brightness = Brightness.dark;

  final Brightness brightness;
  final Color primary;
  final Color onPrimary;
  final Color surface;
  final Color onSurface;
  final Color surfaceContainer;
  final Color outline;
  final Color error;
  final Color onError;

  ColorScheme copyWith({
    Brightness? brightness,
    Color? primary,
    Color? onPrimary,
    Color? surface,
    Color? onSurface,
    Color? surfaceContainer,
    Color? outline,
    Color? error,
    Color? onError,
  }) =>
      ColorScheme(
        brightness: brightness ?? this.brightness,
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        surface: surface ?? this.surface,
        onSurface: onSurface ?? this.onSurface,
        surfaceContainer: surfaceContainer ?? this.surfaceContainer,
        outline: outline ?? this.outline,
        error: error ?? this.error,
        onError: onError ?? this.onError,
      );
}

/// Font weights follow the numeric OpenType/CSS scale used by Flutter.
final class FontWeight {
  const FontWeight._(this.value);

  final int value;

  static const FontWeight w100 = FontWeight._(100);
  static const FontWeight w200 = FontWeight._(200);
  static const FontWeight w300 = FontWeight._(300);
  static const FontWeight w400 = FontWeight._(400);
  static const FontWeight w500 = FontWeight._(500);
  static const FontWeight w600 = FontWeight._(600);
  static const FontWeight w700 = FontWeight._(700);
  static const FontWeight w800 = FontWeight._(800);
  static const FontWeight w900 = FontWeight._(900);
  static const FontWeight normal = w400;
  static const FontWeight bold = w700;
}

/// The stable, portable subset of Flutter's TextStyle contract.
final class TextStyle {
  const TextStyle({
    this.color,
    this.fontSize,
    this.fontFamily,
    this.fontWeight,
  });

  final Color? color;
  final double? fontSize;
  final String? fontFamily;
  final FontWeight? fontWeight;

  TextStyle merge(TextStyle? other) => other == null
      ? this
      : TextStyle(
          color: other.color ?? color,
          fontSize: other.fontSize ?? fontSize,
          fontFamily: other.fontFamily ?? fontFamily,
          fontWeight: other.fontWeight ?? fontWeight,
        );

  TextStyle copyWith({
    Color? color,
    double? fontSize,
    String? fontFamily,
    FontWeight? fontWeight,
  }) =>
      TextStyle(
        color: color ?? this.color,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily ?? this.fontFamily,
        fontWeight: fontWeight ?? this.fontWeight,
      );
}

final class TextTheme {
  const TextTheme({
    this.bodyMedium = const TextStyle(fontSize: 14),
    this.titleMedium =
        const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    this.titleLarge =
        const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
    this.labelLarge =
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
  });

  final TextStyle bodyMedium;
  final TextStyle titleMedium;
  final TextStyle titleLarge;
  final TextStyle labelLarge;
}

final class IconThemeData {
  const IconThemeData({this.color, this.size});

  final Color? color;
  final double? size;

  IconThemeData merge(IconThemeData? other) => other == null
      ? this
      : IconThemeData(
          color: other.color ?? color,
          size: other.size ?? size,
        );
}

final class ProgressIndicatorThemeData {
  const ProgressIndicatorThemeData({
    this.color,
    this.linearTrackColor,
    this.circularTrackColor,
  });

  final Color? color;
  final Color? linearTrackColor;
  final Color? circularTrackColor;
}

/// Visual defaults for framework scrollbars.
///
/// The nullable colours inherit from the surrounding [ThemeData]. Metrics are
/// deliberately independent: a slim resting thumb can still grow to a generous
/// pointer target while hovered or dragged.
final class ScrollbarThemeData {
  const ScrollbarThemeData({
    this.thumbColor,
    this.hoveredThumbColor,
    this.trackColor,
    this.thickness = 6,
    this.hoveredThickness = 10,
    this.radius = 999,
    this.minThumbLength = 36,
    this.mainAxisMargin = 4,
    this.crossAxisMargin = 3,
    this.trackVisibility = true,
    this.showButtons = true,
    this.buttonExtent = 16,
    this.buttonColor,
    this.buttonIconColor,
  });

  final Color? thumbColor;
  final Color? hoveredThumbColor;
  final Color? trackColor;
  final double thickness;
  final double hoveredThickness;
  final double radius;
  final double minThumbLength;
  final double mainAxisMargin;
  final double crossAxisMargin;
  final bool trackVisibility;
  final bool showButtons;
  final double buttonExtent;
  final Color? buttonColor;
  final Color? buttonIconColor;

  @override
  bool operator ==(Object other) =>
      other is ScrollbarThemeData &&
      other.thumbColor == thumbColor &&
      other.hoveredThumbColor == hoveredThumbColor &&
      other.trackColor == trackColor &&
      other.thickness == thickness &&
      other.hoveredThickness == hoveredThickness &&
      other.radius == radius &&
      other.minThumbLength == minThumbLength &&
      other.mainAxisMargin == mainAxisMargin &&
      other.crossAxisMargin == crossAxisMargin &&
      other.trackVisibility == trackVisibility &&
      other.showButtons == showButtons &&
      other.buttonExtent == buttonExtent &&
      other.buttonColor == buttonColor &&
      other.buttonIconColor == buttonIconColor;

  @override
  int get hashCode => Object.hash(
        thumbColor,
        hoveredThumbColor,
        trackColor,
        thickness,
        hoveredThickness,
        radius,
        minThumbLength,
        mainAxisMargin,
        crossAxisMargin,
        trackVisibility,
        showButtons,
        buttonExtent,
        buttonColor,
        buttonIconColor,
      );
}

/// The named palette and metrics of one theme.
///
/// Colours use the Flutter-shaped immutable [Color] value type. Conversion to
/// packed 0xAARRGGBB integers happens only at the display-list boundary.
final class ThemeData {
  const ThemeData({
    this.name = 'dart-ui-light',
    this.brightness = Brightness.light,
    this.accent = const Color(0xFF2563EB),
    this.accentPressed = const Color(0xFF1D4ED8),
    this.accentHovered = const Color(0xFF3B82F6),
    this.surface = const Color(0xFFF8FAFC),
    this.surfaceAlternate = const Color(0xFFFFFFFF),
    this.border = const Color(0xFFCBD5E1),
    this.foreground = const Color(0xFF172033),
    this.foregroundSecondary = const Color(0xFF64748B),
    this.disabledForeground = const Color(0xFF94A3B8),
    this.disabledSurface = const Color(0xFFE2E8F0),
    this.focusRing = const Color(0xFF2563EB),
    this.selection = const Color(0xFFBFDBFE),
    this.colorScheme = const ColorScheme.light(),
    this.textTheme = const TextTheme(),
    this.iconTheme = const IconThemeData(size: 20),
    this.progressIndicatorTheme = const ProgressIndicatorThemeData(),
    this.scrollbarTheme = const ScrollbarThemeData(),
    this.useMaterial3 = true,
    this.density = ThemeDensity.comfortable,
    this.highContrast = false,
    this.reducedMotion = false,
    this.cornerRadius = 8.0,
    this.controlHeight = 36.0,
    this.controlPadding = 10.0,
    this.focusRingWidth = 2.0,
    this.fontSize = 14.0,
  });

  final String name;
  final ThemeBrightness brightness;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final IconThemeData iconTheme;
  final ProgressIndicatorThemeData progressIndicatorTheme;
  final ScrollbarThemeData scrollbarTheme;
  final bool useMaterial3;

  final Color accent;
  final Color accentPressed;
  final Color accentHovered;
  final Color surface;
  final Color surfaceAlternate;
  final Color border;
  final Color foreground;
  final Color foregroundSecondary;
  final Color disabledForeground;
  final Color disabledSurface;
  final Color focusRing;
  final Color selection;

  final ThemeDensity density;

  /// High contrast is a distinct flag rather than another palette name,
  /// because it changes *rules* as well as colours: focus rings widen and
  /// borders stop being optional.
  final bool highContrast;

  /// Whether transitions should jump to their final value instead of animating.
  ///
  /// Section 32.4 requires the framework to respect a reduced-motion
  /// preference, and it is a genuine accessibility need rather than a taste:
  /// large or repeated motion triggers nausea and migraine in people with
  /// vestibular disorders, and for them an animated interface is not merely
  /// busier, it is unusable.
  ///
  /// ## What it does, precisely
  ///
  /// It shortens transitions to nothing. A [StyleTransitionRunner] constructed
  /// with `reducedMotion: true` writes no [PropertyPrecedence.animation] value
  /// at all: the style layer already holds the destination, so leaving that
  /// slot empty *is* arriving instantly.
  ///
  /// ## What it deliberately does not do
  ///
  /// **It does not stop the clock.** The [AnimationClock] keeps ticking and
  /// the frame loop keeps running, for three reasons:
  ///
  ///   * reduced motion is a request to remove *decorative* motion, not to
  ///     freeze the interface. A progress spinner, a caret blink and a video
  ///     scrubber are all animations, and stopping them would remove
  ///     information rather than distraction;
  ///   * the flag can be toggled at runtime, and a stopped clock would have to
  ///     be restarted with a rebased timestamp - a step that is easy to forget
  ///     and whose failure looks like a mysteriously frozen window;
  ///   * an animation that is *running* when the flag flips must still land on
  ///     its final value. That is a job for the transition runner, which knows
  ///     what the final value is; a clock cannot know.
  ///
  /// Turning the flag off does not replay anything. Motion that was skipped is
  /// skipped; only subsequent changes animate.
  final bool reducedMotion;

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
    bool? reducedMotion,
    double? cornerRadius,
    double? controlHeight,
    double? fontSize,
    ColorScheme? colorScheme,
    TextTheme? textTheme,
    IconThemeData? iconTheme,
    ProgressIndicatorThemeData? progressIndicatorTheme,
    ScrollbarThemeData? scrollbarTheme,
    bool? useMaterial3,
  }) =>
      ThemeData(
        name: name ?? this.name,
        brightness: brightness ?? this.brightness,
        colorScheme: colorScheme ?? this.colorScheme,
        textTheme: textTheme ?? this.textTheme,
        iconTheme: iconTheme ?? this.iconTheme,
        progressIndicatorTheme:
            progressIndicatorTheme ?? this.progressIndicatorTheme,
        scrollbarTheme: scrollbarTheme ?? this.scrollbarTheme,
        useMaterial3: useMaterial3 ?? this.useMaterial3,
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
        reducedMotion: reducedMotion ?? this.reducedMotion,
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
      other.reducedMotion == reducedMotion &&
      other.cornerRadius == cornerRadius &&
      other.controlHeight == controlHeight &&
      other.controlPadding == controlPadding &&
      other.focusRingWidth == focusRingWidth &&
      other.fontSize == fontSize &&
      other.scrollbarTheme == scrollbarTheme;

  @override
  int get hashCode => Object.hash(
        name,
        brightness,
        Object.hash(accent, accentPressed, accentHovered),
        Object.hash(surface, surfaceAlternate, border),
        Object.hash(foreground, foregroundSecondary, disabledForeground),
        Object.hash(disabledSurface, focusRing, selection),
        density,
        Object.hash(highContrast, reducedMotion),
        Object.hash(
            cornerRadius, controlHeight, controlPadding, focusRingWidth),
        Object.hash(fontSize, scrollbarTheme),
      );

  /// The neutral base: no platform's look, and the one every test uses so a
  /// golden never depends on which OS ran it.
  static const ThemeData neutralLight = ThemeData(
    name: 'neutral-light',
    brightness: ThemeBrightness.light,
    accent: Color(0xFF2D6CDF),
    accentPressed: Color(0xFF1F4FA8),
    accentHovered: Color(0xFF4682E8),
    surface: Color(0xFFF3F3F3),
    surfaceAlternate: Color(0xFFFFFFFF),
    border: Color(0xFFB8B8B8),
    foreground: Color(0xFF111111),
    foregroundSecondary: Color(0xFF555555),
    disabledForeground: Color(0xFF9A9A9A),
    disabledSurface: Color(0xFFE6E6E6),
    focusRing: Color(0xFF1F4FA8),
    selection: Color(0xFFBBD6FF),
    colorScheme: ColorScheme.light(),
    cornerRadius: 3,
    controlHeight: 28,
    controlPadding: 8,
    fontSize: kDefaultUiFontSize,
  );

  static const ThemeData neutralDark = ThemeData(
    name: 'neutral-dark',
    brightness: ThemeBrightness.dark,
    accent: Color(0xFF4C8DFF),
    accentPressed: Color(0xFF2F6ACC),
    accentHovered: Color(0xFF6BA3FF),
    surface: Color(0xFF202020),
    surfaceAlternate: Color(0xFF2B2B2B),
    border: Color(0xFF4A4A4A),
    foreground: Color(0xFFF2F2F2),
    foregroundSecondary: Color(0xFFBFBFBF),
    disabledForeground: Color(0xFF6E6E6E),
    disabledSurface: Color(0xFF303030),
    focusRing: Color(0xFF8AB8FF),
    selection: Color(0xFF2C4E7A),
    colorScheme: ColorScheme.dark(),
    iconTheme: IconThemeData(color: Color(0xFFF2F2F2), size: 20),
    cornerRadius: 3,
    controlHeight: 28,
    controlPadding: 8,
    fontSize: kDefaultUiFontSize,
  );

  /// Modern defaults for new applications.
  static const ThemeData materialLight = ThemeData();

  static const ThemeData materialDark = ThemeData(
    name: 'dart-ui-dark',
    brightness: Brightness.dark,
    accent: Color(0xFF2563EB),
    accentPressed: Color(0xFF1D4ED8),
    accentHovered: Color(0xFF3B82F6),
    surface: Color(0xFF111827),
    surfaceAlternate: Color(0xFF182235),
    border: Color(0xFF475569),
    foreground: Color(0xFFF1F5F9),
    foregroundSecondary: Color(0xFFCBD5E1),
    disabledForeground: Color(0xFF64748B),
    disabledSurface: Color(0xFF273449),
    focusRing: Color(0xFF60A5FA),
    selection: Color(0xFF1E4976),
    colorScheme: ColorScheme.dark(
      primary: Color(0xFF2563EB),
      onPrimary: Color(0xFFFFFFFF),
    ),
    iconTheme: IconThemeData(color: Color(0xFFF1F5F9), size: 20),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: Color(0xB38FA3B8),
      hoveredThumbColor: Color(0xE6CBD5E1),
      trackColor: Color(0x55334455),
      buttonColor: Color(0x66334455),
      buttonIconColor: Color(0xFFF1F5F9),
    ),
  );

  /// A Fluent-*like* light theme: squarer corners, flatter surfaces. Built
  /// from our own values; nothing is copied from a vendor resource file.
  static const ThemeData fluentLight = ThemeData(
    name: 'fluent-light',
    brightness: ThemeBrightness.light,
    accent: Color(0xFF0078D4),
    accentPressed: Color(0xFF005A9E),
    accentHovered: Color(0xFF106EBE),
    surface: Color(0xFFFAFAFA),
    surfaceAlternate: Color(0xFFFFFFFF),
    border: Color(0xFFD1D1D1),
    foreground: Color(0xFF201F1E),
    foregroundSecondary: Color(0xFF605E5C),
    disabledForeground: Color(0xFFA19F9D),
    disabledSurface: Color(0xFFF3F2F1),
    focusRing: Color(0xFF005A9E),
    selection: Color(0xFFCCE4F7),
    colorScheme: ColorScheme.light(primary: Color(0xFF0078D4)),
    cornerRadius: 2.0,
    controlHeight: 32.0,
  );

  /// High contrast, per section 28.3's `high-contrast` pseudo-class: pure
  /// extremes, always-visible borders, a thicker focus ring.
  static const ThemeData highContrastDark = ThemeData(
    name: 'high-contrast-dark',
    brightness: ThemeBrightness.dark,
    accent: Color(0xFFFFFF00),
    accentPressed: Color(0xFFFFD700),
    accentHovered: Color(0xFFFFFF66),
    surface: Color(0xFF000000),
    surfaceAlternate: Color(0xFF000000),
    border: Color(0xFFFFFFFF),
    foreground: Color(0xFFFFFFFF),
    foregroundSecondary: Color(0xFFFFFFFF),
    disabledForeground: Color(0xFF3FF23F),
    disabledSurface: Color(0xFF000000),
    focusRing: Color(0xFFFFFF00),
    selection: Color(0xFF1AEBFF),
    colorScheme: ColorScheme.dark(
      primary: Color(0xFFFFFF00),
      onPrimary: Color(0xFF000000),
      surface: Color(0xFF000000),
      onSurface: Color(0xFFFFFFFF),
      surfaceContainer: Color(0xFF000000),
      outline: Color(0xFFFFFFFF),
    ),
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
