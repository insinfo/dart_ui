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

/// The 4 px spacing grid every gap, inset and margin in the framework is a
/// multiple of.
///
/// A scale rather than free numbers because the eye reads rhythm: eight gaps
/// of 6, 7 and 9 px look accidental, and three of 4, 8 and 16 px look
/// deliberate even when the reader could not say why. [hair] is the one
/// half-step, reserved for optical corrections - the 2 px a separator is
/// inset by, not the space between two buttons.
abstract final class Spacing {
  static const double none = 0;
  static const double hair = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// The scale as a list, so a gallery or a document can show it in order.
  static const List<double> scale = <double>[2, 4, 8, 12, 16, 24, 32];
}

/// How tightly controls are packed.
///
/// Three steps rather than a free multiplier, because the numbers a control
/// needs are not one number scaled: a row in a list is shorter than a button
/// at every density, and the ratio between them is not constant. Each step
/// therefore carries its own resolved metrics, all of them multiples of 4.
///
///   * [compact] - professional desktop tools: a vector editor, an IDE, a
///     trading screen. Maximum information per pixel, and the density a
///     toolbar-heavy application should pick;
///   * [standard] - the default. Forms, CRUD screens, settings;
///   * [comfortable] - touch-adjacent or presentation surfaces, and the
///     density to pick when the pointer might be a finger.
///
/// Type size is deliberately *not* part of this: a dense theme is one with
/// tighter chrome, and shrinking the text with it is how a dense theme becomes
/// an unreadable one. [ThemeData.fontSize] is chosen separately.
enum ThemeDensity {
  compact(controlHeight: 28, rowHeight: 24, controlPadding: 8, gap: 4),
  standard(controlHeight: 32, rowHeight: 28, controlPadding: 12, gap: 8),
  comfortable(controlHeight: 40, rowHeight: 36, controlPadding: 16, gap: 12);

  const ThemeDensity({
    required this.controlHeight,
    required this.rowHeight,
    required this.controlPadding,
    required this.gap,
  });

  /// The height of a control that holds one line of text: button, text field,
  /// combo box, tab, spin box.
  final double controlHeight;

  /// The height of one row in a dense collection: list, tree, grid, menu.
  ///
  /// Shorter than [controlHeight] on purpose. A row is scanned in bulk and a
  /// control is aimed at, so the row trades pointer target for how much of the
  /// collection is visible at once - and a list whose rows are as tall as
  /// buttons is a list that shows a third fewer of them.
  final double rowHeight;

  /// The horizontal breathing room between a control's edge and its content.
  final double controlPadding;

  /// The gap between two adjacent controls in a bar or a form row.
  final double gap;

  /// The multiplier this density applies to a theme's declared metrics.
  ///
  /// Kept as the ratio to [standard] so that a theme which declares a taller
  /// [ThemeData.controlHeight] than the standard 32 keeps its proportions at
  /// every density instead of snapping to these absolute numbers.
  double get scale => controlHeight / 32.0;
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
    this.height,
  });

  final Color? color;
  final double? fontSize;
  final String? fontFamily;
  final FontWeight? fontWeight;

  /// Line height as a multiple of [fontSize], or null for the face's own.
  ///
  /// A multiplier rather than a pixel value because it has to survive a change
  /// of type size: 20 px of leading is generous under 13 px text and cramped
  /// under 22 px text, while 1.45 is the same relationship at both. It reaches
  /// the layout as [ParagraphStyle.heightMultiplier], so it is what separates
  /// two wrapped lines - a single-line label has no leading to place and is
  /// unaffected.
  final double? height;

  TextStyle merge(TextStyle? other) => other == null
      ? this
      : TextStyle(
          color: other.color ?? color,
          fontSize: other.fontSize ?? fontSize,
          fontFamily: other.fontFamily ?? fontFamily,
          fontWeight: other.fontWeight ?? fontWeight,
          height: other.height ?? height,
        );

  TextStyle copyWith({
    Color? color,
    double? fontSize,
    String? fontFamily,
    FontWeight? fontWeight,
    double? height,
  }) =>
      TextStyle(
        color: color ?? this.color,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily ?? this.fontFamily,
        fontWeight: fontWeight ?? this.fontWeight,
        height: height ?? this.height,
      );

  @override
  bool operator ==(Object other) =>
      other is TextStyle &&
      other.color == color &&
      other.fontSize == fontSize &&
      other.fontFamily == fontFamily &&
      other.fontWeight == fontWeight &&
      other.height == height;

  @override
  int get hashCode => Object.hash(color, fontSize, fontFamily, fontWeight, height);
}

/// The type scale, derived from one number.
///
/// Seven roles, each a fixed step from [base], because a scale is what stops a
/// screen from carrying five sizes that differ by a point and mean nothing.
/// Deriving them instead of listing them is what keeps the relationship true
/// after a theme changes its base size: a caption stays two steps under body
/// text at 13 px and at 15 px, where two literal values would drift apart.
///
/// The steps, in order:
///
/// | role          | size    | weight | leading | used for                   |
/// |---------------|---------|--------|---------|----------------------------|
/// | [labelSmall]  | base-2  | 500    | 1.30    | captions, status bars, meta|
/// | [bodySmall]   | base-1  | 400    | 1.40    | dense secondary text       |
/// | [bodyMedium]  | base    | 400    | 1.45    | the default for prose      |
/// | [labelLarge]  | base    | 500    | 1.20    | control labels, buttons    |
/// | [titleSmall]  | base+1  | 600    | 1.30    | panel and group headers    |
/// | [titleMedium] | base+2  | 600    | 1.30    | dialog and section titles  |
/// | [titleLarge]  | base+8  | 600    | 1.20    | page titles                |
///
/// Any role can still be overridden one at a time; an override is merged over
/// the derived value, so naming a colour does not also drop the size.
final class TextTheme {
  const TextTheme({
    this.base = 14,
    this.fontFamily,
    TextStyle? labelSmall,
    TextStyle? bodySmall,
    TextStyle? bodyMedium,
    TextStyle? labelLarge,
    TextStyle? titleSmall,
    TextStyle? titleMedium,
    TextStyle? titleLarge,
  })  : _labelSmall = labelSmall,
        _bodySmall = bodySmall,
        _bodyMedium = bodyMedium,
        _labelLarge = labelLarge,
        _titleSmall = titleSmall,
        _titleMedium = titleMedium,
        _titleLarge = titleLarge;

  /// The size body text is drawn at; every other role is a step from it.
  final double base;

  /// The face every role uses, or null for the interface face.
  final String? fontFamily;

  final TextStyle? _labelSmall;
  final TextStyle? _bodySmall;
  final TextStyle? _bodyMedium;
  final TextStyle? _labelLarge;
  final TextStyle? _titleSmall;
  final TextStyle? _titleMedium;
  final TextStyle? _titleLarge;

  TextStyle _role(
    double size,
    FontWeight weight,
    double height,
    TextStyle? override,
  ) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        height: height,
        fontFamily: fontFamily,
      ).merge(override);

  TextStyle get labelSmall =>
      _role(base - 2, FontWeight.w500, 1.30, _labelSmall);

  TextStyle get bodySmall => _role(base - 1, FontWeight.w400, 1.40, _bodySmall);

  TextStyle get bodyMedium => _role(base, FontWeight.w400, 1.45, _bodyMedium);

  TextStyle get labelLarge => _role(base, FontWeight.w500, 1.20, _labelLarge);

  TextStyle get titleSmall =>
      _role(base + 1, FontWeight.w600, 1.30, _titleSmall);

  TextStyle get titleMedium =>
      _role(base + 2, FontWeight.w600, 1.30, _titleMedium);

  TextStyle get titleLarge => _role(base + 8, FontWeight.w600, 1.20, _titleLarge);

  /// The same scale rebuilt around a different [base], overrides kept.
  TextTheme rebase(double base) => TextTheme(
        base: base,
        fontFamily: fontFamily,
        labelSmall: _labelSmall,
        bodySmall: _bodySmall,
        bodyMedium: _bodyMedium,
        labelLarge: _labelLarge,
        titleSmall: _titleSmall,
        titleMedium: _titleMedium,
        titleLarge: _titleLarge,
      );

  @override
  bool operator ==(Object other) =>
      other is TextTheme &&
      other.base == base &&
      other.fontFamily == fontFamily &&
      other._labelSmall == _labelSmall &&
      other._bodySmall == _bodySmall &&
      other._bodyMedium == _bodyMedium &&
      other._labelLarge == _labelLarge &&
      other._titleSmall == _titleSmall &&
      other._titleMedium == _titleMedium &&
      other._titleLarge == _titleLarge;

  @override
  int get hashCode => Object.hash(
        base,
        fontFamily,
        _labelSmall,
        _bodySmall,
        _bodyMedium,
        _labelLarge,
        _titleSmall,
        _titleMedium,
        _titleLarge,
      );
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
    this.trackVisibility = false,
    this.showButtons = false,
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
  /// Whether the track behind the thumb is painted while the bar is at rest.
  ///
  /// Off by default. A permanently visible groove down the side of every
  /// scrollable is the 1995 drawing; the track still appears while the pointer
  /// is on the bar, which is when it says how far the thumb can travel.
  final bool trackVisibility;

  /// Whether stepper arrows are drawn at the two ends.
  ///
  /// Off by default. Every current desktop dropped them - they are a two-pixel
  /// target that repeats what the wheel, the track and the keyboard already
  /// do - and an application that wants them back sets this.
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
///
/// ## The token contract
///
/// Every control in the framework reads its geometry from four numbers and its
/// colours from a fixed vocabulary, and never from a literal of its own. The
/// numbers are [cornerRadius], [controlHeight], [controlPadding] and
/// [focusRingWidth], each declared *at the standard density* and re-resolved
/// through [density] by the `effective*` getters. The vocabulary is layered:
///
///   * **surfaces**, from furthest back to nearest the reader:
///     [surfaceBase] (the window behind everything), [surface] (a panel),
///     [surfaceAlternate] (content and input fields sitting on that panel),
///     [surfaceRaised] (menus, pop-ups and dialogs, which float above it);
///   * **borders**, by how loudly they speak: [borderSubtle] for a divider
///     inside one surface, [border] for the edge between two, [borderStrong]
///     for the outline of something the user can type into or aim at;
///   * **states**: [hoverSurface] and [pressedSurface] tint a neutral control,
///     [accentSubtle] marks a selected one, [selection] marks selected text or
///     rows, and [disabledSurface]/[disabledForeground] mark what cannot be
///     used;
///   * **accent**: [accent], [accentHovered], [accentPressed] for filled
///     emphasis, with [ColorScheme.onPrimary] as the text on top of them.
///
/// A 1 px grey line around every bar is the "Windows 95" look, and it is what
/// this vocabulary exists to replace: hierarchy is carried by the surface step
/// first, and a border is drawn only where two surfaces genuinely meet.
final class ThemeData {
  const ThemeData({
    this.name = 'dart-ui-light',
    this.brightness = Brightness.light,
    this.accent = const Color(0xFF2563EB),
    this.accentPressed = const Color(0xFF1E40AF),
    this.accentHovered = const Color(0xFF1D4ED8),
    this.accentSubtle = const Color(0xFFE3ECFD),
    this.surfaceBase = const Color(0xFFEEF0F4),
    this.surface = const Color(0xFFF6F7F9),
    this.surfaceAlternate = const Color(0xFFFFFFFF),
    this.surfaceRaised = const Color(0xFFFFFFFF),
    this.borderSubtle = const Color(0xFFE7E9ED),
    this.border = const Color(0xFFD5D9E0),
    this.borderStrong = const Color(0xFF888E98),
    this.foreground = const Color(0xFF14181F),
    this.foregroundSecondary = const Color(0xFF5A6472),
    this.disabledForeground = const Color(0xFF9AA1AC),
    this.disabledSurface = const Color(0xFFECEEF1),
    this.hoverSurface = const Color(0xFFEBEDF1),
    this.pressedSurface = const Color(0xFFDFE3E9),
    this.focusRing = const Color(0xFF2563EB),
    this.selection = const Color(0xFFD8E5FE),
    Color? onSelection,
    this.colorScheme = const ColorScheme.light(),
    this.textTheme = const TextTheme(),
    this.iconTheme = const IconThemeData(size: 20),
    this.progressIndicatorTheme = const ProgressIndicatorThemeData(),
    this.scrollbarTheme = const ScrollbarThemeData(),
    this.useMaterial3 = true,
    this.density = ThemeDensity.standard,
    this.highContrast = false,
    this.reducedMotion = false,
    this.cornerRadius = 6.0,
    this.controlHeight = 32.0,
    this.controlPadding = 12.0,
    this.focusRingWidth = 2.0,
  }) : _onSelection = onSelection;

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

  /// A wash of the accent, for a control that is *selected* rather than
  /// activated: a pressed-in toolbar toggle, the current tab, a checked menu
  /// item. Filling those with [accent] makes a toolbar read as a row of
  /// primary buttons, which is what a tool palette must not look like.
  final Color accentSubtle;

  /// The colour behind everything: the window, and the gap between panels.
  final Color surfaceBase;

  /// A panel's own background.
  final Color surface;

  /// Content that sits on a panel: a text field, a list, a card, a bar.
  final Color surfaceAlternate;

  /// Something that floats: a menu, a pop-up list, a dialog, a tooltip.
  final Color surfaceRaised;

  /// A divider *inside* one surface - between two rows, between two groups of
  /// toolbar buttons. Barely visible on purpose.
  final Color borderSubtle;

  /// The edge where two surfaces meet.
  final Color border;

  /// The outline of something interactive: a text field, a combo box, an
  /// unfilled button. Strong enough to say "this is a target".
  final Color borderStrong;

  final Color foreground;
  final Color foregroundSecondary;
  final Color disabledForeground;
  final Color disabledSurface;

  /// The tint a neutral (unfilled) control takes under the pointer.
  final Color hoverSurface;

  /// The tint a neutral control takes while it is held down.
  final Color pressedSurface;

  final Color focusRing;
  final Color selection;
  final Color? _onSelection;

  /// The colour of text sitting on [selection].
  ///
  /// Defaults to [foreground], which is right whenever the selection is a
  /// tint of the surface. It exists as its own token for the theme where that
  /// is false: a high-contrast selection is a *saturated* fill, and white text
  /// on cyan is 1.4:1 - a selected row that only the sighted-and-lucky can
  /// read.
  Color get onSelection => _onSelection ?? foreground;

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

  /// The corner radius of an ordinary control, at the standard density.
  ///
  /// The other two radii are steps from it rather than fields of their own:
  /// what makes a screen look designed is that its corners agree, and three
  /// independent numbers is three chances for them not to.
  final double cornerRadius;

  final double controlHeight;
  final double controlPadding;
  final double focusRingWidth;

  /// The pixel size interface text is drawn at.
  ///
  /// A size and not a face: a face is parsed bytes and could not live in a
  /// `const` theme, so [FontRegistry] resolves it and this says how big to draw
  /// it. It reads through to [TextTheme.base] rather than being a second
  /// number, because the framework had exactly that bug - controls drew their
  /// labels at `fontSize` while [Text] drew at `textTheme.bodyMedium`, so a
  /// button beside a label rendered two type sizes on one line.
  ///
  /// Unscaled by [density] on purpose: compact means tighter chrome, and
  /// shrinking the text with it is how a dense theme becomes an unreadable one.
  double get fontSize => textTheme.base;

  /// The control height after density is applied.
  double get effectiveControlHeight => _onGrid(controlHeight * density.scale);

  /// The control padding after density is applied.
  double get effectiveControlPadding =>
      _onGrid(controlPadding * density.controlPadding / 12.0);

  /// The height of one row of a list, tree, grid or menu.
  double get effectiveRowHeight =>
      _onGrid(density.rowHeight * controlHeight / 32.0);

  /// Snaps a resolved metric onto the 4 px grid.
  ///
  /// Enforced rather than assumed. Density is a *ratio*, so a theme that
  /// declares 34 px controls would otherwise resolve to 29.75 at the compact
  /// step - and one number off the grid is enough to put a whole bar half a
  /// pixel out of alignment with the bar above it. A theme that wants exact
  /// numbers declares numbers that are already multiples of four.
  static double _onGrid(double value) => (value / 4).roundToDouble() * 4;

  /// The gap between two adjacent controls.
  double get effectiveGap => density.gap;

  /// The radius of something small: a check box, a chip, a swatch, a toolbar
  /// button.
  double get cornerRadiusSmall =>
      cornerRadius <= 2 ? cornerRadius : cornerRadius - 2;

  /// The radius of something large: a card, a dialog, a pop-up, a panel.
  double get cornerRadiusLarge =>
      cornerRadius <= 2 ? cornerRadius : cornerRadius + 2;

  /// The size of an icon drawn inside a control, snapped to the pixel grid.
  ///
  /// Icon outlines are drawn on a 16- or 24-unit grid and land on whole pixels
  /// only at those sizes, so this is one of 16, 20 or 24 rather than a
  /// fraction of the type size.
  double get iconSize =>
      iconTheme.size ?? (density == ThemeDensity.comfortable ? 20 : 16);

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
    double? controlPadding,
    double? fontSize,
    Color? accent,
    Color? surface,
    Color? surfaceAlternate,
    Color? border,
    Color? foreground,
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
        textTheme: fontSize == null
            ? (textTheme ?? this.textTheme)
            : (textTheme ?? this.textTheme).rebase(fontSize),
        iconTheme: iconTheme ?? this.iconTheme,
        progressIndicatorTheme:
            progressIndicatorTheme ?? this.progressIndicatorTheme,
        scrollbarTheme: scrollbarTheme ?? this.scrollbarTheme,
        useMaterial3: useMaterial3 ?? this.useMaterial3,
        accent: accent ?? this.accent,
        accentPressed: accentPressed,
        accentHovered: accentHovered,
        accentSubtle: accentSubtle,
        surfaceBase: surfaceBase,
        surface: surface ?? this.surface,
        surfaceAlternate: surfaceAlternate ?? this.surfaceAlternate,
        surfaceRaised: surfaceRaised,
        borderSubtle: borderSubtle,
        border: border ?? this.border,
        borderStrong: borderStrong,
        foreground: foreground ?? this.foreground,
        foregroundSecondary: foregroundSecondary,
        disabledForeground: disabledForeground,
        disabledSurface: disabledSurface,
        hoverSurface: hoverSurface,
        pressedSurface: pressedSurface,
        focusRing: focusRing,
        selection: selection,
        onSelection: _onSelection,
        density: density ?? this.density,
        highContrast: highContrast ?? this.highContrast,
        reducedMotion: reducedMotion ?? this.reducedMotion,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        controlHeight: controlHeight ?? this.controlHeight,
        controlPadding: controlPadding ?? this.controlPadding,
        focusRingWidth: focusRingWidth,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemeData &&
      other.name == name &&
      other.brightness == brightness &&
      other.accent == accent &&
      other.accentPressed == accentPressed &&
      other.accentHovered == accentHovered &&
      other.accentSubtle == accentSubtle &&
      other.surfaceBase == surfaceBase &&
      other.surface == surface &&
      other.surfaceAlternate == surfaceAlternate &&
      other.surfaceRaised == surfaceRaised &&
      other.borderSubtle == borderSubtle &&
      other.border == border &&
      other.borderStrong == borderStrong &&
      other.foreground == foreground &&
      other.foregroundSecondary == foregroundSecondary &&
      other.disabledForeground == disabledForeground &&
      other.disabledSurface == disabledSurface &&
      other.hoverSurface == hoverSurface &&
      other.pressedSurface == pressedSurface &&
      other.focusRing == focusRing &&
      other.selection == selection &&
      other.onSelection == onSelection &&
      other.density == density &&
      other.highContrast == highContrast &&
      other.reducedMotion == reducedMotion &&
      other.cornerRadius == cornerRadius &&
      other.controlHeight == controlHeight &&
      other.controlPadding == controlPadding &&
      other.focusRingWidth == focusRingWidth &&
      other.textTheme == textTheme &&
      other.scrollbarTheme == scrollbarTheme;

  @override
  int get hashCode => Object.hash(
        name,
        brightness,
        Object.hash(accent, accentPressed, accentHovered, accentSubtle),
        Object.hash(surfaceBase, surface, surfaceAlternate, surfaceRaised),
        Object.hash(borderSubtle, border, borderStrong),
        Object.hash(foreground, foregroundSecondary, disabledForeground),
        Object.hash(disabledSurface, hoverSurface, pressedSurface),
        Object.hash(focusRing, selection, onSelection),
        density,
        Object.hash(highContrast, reducedMotion),
        Object.hash(
            cornerRadius, controlHeight, controlPadding, focusRingWidth),
        Object.hash(textTheme, scrollbarTheme),
      );

  /// The neutral base: no platform's look, and the one every test uses so a
  /// golden never depends on which OS ran it.
  ///
  /// Standard density and a 13 px base: a desktop framework's default screen is
  /// a form, not a touch surface and not a trading terminal.
  static const ThemeData neutralLight = ThemeData(
    name: 'neutral-light',
    brightness: ThemeBrightness.light,
    accent: Color(0xFF2563EB),
    accentHovered: Color(0xFF1D4ED8),
    accentPressed: Color(0xFF1E40AF),
    accentSubtle: Color(0xFFE3ECFD),
    surfaceBase: Color(0xFFEEF0F4),
    surface: Color(0xFFF6F7F9),
    surfaceAlternate: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFFE7E9ED),
    border: Color(0xFFD5D9E0),
    borderStrong: Color(0xFF888E98),
    foreground: Color(0xFF14181F),
    foregroundSecondary: Color(0xFF5A6472),
    disabledForeground: Color(0xFF9AA1AC),
    disabledSurface: Color(0xFFECEEF1),
    hoverSurface: Color(0xFFEBEDF1),
    pressedSurface: Color(0xFFDFE3E9),
    focusRing: Color(0xFF2563EB),
    selection: Color(0xFFD8E5FE),
    colorScheme: ColorScheme.light(),
    textTheme: TextTheme(base: 13),
    iconTheme: IconThemeData(size: 16),
    density: ThemeDensity.standard,
    cornerRadius: 6,
    controlHeight: 32,
    controlPadding: 12,
  );

  static const ThemeData neutralDark = ThemeData(
    name: 'neutral-dark',
    brightness: ThemeBrightness.dark,
    accent: Color(0xFF5C97FF),
    accentHovered: Color(0xFF7DAEFF),
    accentPressed: Color(0xFF9CC0FF),
    accentSubtle: Color(0xFF1F3559),
    surfaceBase: Color(0xFF15181C),
    surface: Color(0xFF1D2126),
    surfaceAlternate: Color(0xFF24282F),
    surfaceRaised: Color(0xFF2A2F37),
    borderSubtle: Color(0xFF2B3037),
    border: Color(0xFF383E47),
    borderStrong: Color(0xFF6B7280),
    foreground: Color(0xFFEDEFF2),
    foregroundSecondary: Color(0xFFA7AFBB),
    disabledForeground: Color(0xFF6B7380),
    disabledSurface: Color(0xFF262B32),
    hoverSurface: Color(0xFF2C313A),
    pressedSurface: Color(0xFF353B45),
    focusRing: Color(0xFF8AB8FF),
    selection: Color(0xFF2A4A78),
    colorScheme: ColorScheme.dark(
      primary: Color(0xFF5C97FF),
      onPrimary: Color(0xFF002E69),
      surface: Color(0xFF1D2126),
      onSurface: Color(0xFFEDEFF2),
      surfaceContainer: Color(0xFF2C313A),
      outline: Color(0xFF383E47),
    ),
    textTheme: TextTheme(base: 13),
    iconTheme: IconThemeData(color: Color(0xFFEDEFF2), size: 16),
    density: ThemeDensity.standard,
    cornerRadius: 6,
    controlHeight: 32,
    controlPadding: 12,
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: Color(0xB38C97A8),
      hoveredThumbColor: Color(0xE6C6CEDA),
      trackColor: Color(0x33323A45),
      buttonColor: Color(0x44323A45),
      buttonIconColor: Color(0xFFEDEFF2),
    ),
  );

  /// Modern defaults for new applications: rounder, roomier, 14 px text.
  static const ThemeData materialLight = ThemeData(
    name: 'dart-ui-light',
    cornerRadius: 8,
    controlHeight: 36,
    controlPadding: 16,
    iconTheme: IconThemeData(size: 20),
  );

  static const ThemeData materialDark = ThemeData(
    name: 'dart-ui-dark',
    brightness: Brightness.dark,
    accent: Color(0xFF8AB4FF),
    accentHovered: Color(0xFFA6C6FF),
    accentPressed: Color(0xFFC2D8FF),
    accentSubtle: Color(0xFF1E3A6B),
    surfaceBase: Color(0xFF0B1120),
    surface: Color(0xFF111827),
    surfaceAlternate: Color(0xFF1B2436),
    surfaceRaised: Color(0xFF222D42),
    borderSubtle: Color(0xFF1F2937),
    border: Color(0xFF334155),
    borderStrong: Color(0xFF6B7A8D),
    foreground: Color(0xFFF1F5F9),
    foregroundSecondary: Color(0xFFB4C0CE),
    disabledForeground: Color(0xFF6B7A8D),
    disabledSurface: Color(0xFF1E293B),
    hoverSurface: Color(0xFF243146),
    pressedSurface: Color(0xFF2C3B54),
    focusRing: Color(0xFF60A5FA),
    selection: Color(0xFF1E4976),
    // A *light* accent carrying dark text, which is the shape every dark
    // theme converges on: white on a saturated blue is 3.7:1 at the blue that
    // reads as "blue" on a dark ground, and darkening the blue to fix the text
    // takes the fill down into the background.
    colorScheme: ColorScheme.dark(
      primary: Color(0xFF8AB4FF),
      onPrimary: Color(0xFF0A2A5E),
      surface: Color(0xFF111827),
      surfaceContainer: Color(0xFF1B2436),
      outline: Color(0xFF334155),
    ),
    iconTheme: IconThemeData(color: Color(0xFFF1F5F9), size: 20),
    cornerRadius: 8,
    controlHeight: 36,
    controlPadding: 16,
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: Color(0xB38FA3B8),
      hoveredThumbColor: Color(0xE6CBD5E1),
      trackColor: Color(0x55334455),
      buttonColor: Color(0x66334455),
      buttonIconColor: Color(0xFFF1F5F9),
    ),
  );

  /// A Fluent-*like* light theme, and the one a professional desktop tool
  /// should pick: compact density, 4 px corners, 13 px text. Built from our own
  /// values; nothing is copied from a vendor resource file.
  static const ThemeData fluentLight = ThemeData(
    name: 'fluent-light',
    brightness: ThemeBrightness.light,
    accent: Color(0xFF0F6CBD),
    accentHovered: Color(0xFF115EA3),
    accentPressed: Color(0xFF0C4C86),
    accentSubtle: Color(0xFFDCEAF9),
    surfaceBase: Color(0xFFEFF1F4),
    surface: Color(0xFFF7F8FA),
    surfaceAlternate: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFFE9EBEF),
    border: Color(0xFFDCE0E6),
    borderStrong: Color(0xFF888E98),
    foreground: Color(0xFF191C20),
    foregroundSecondary: Color(0xFF586371),
    disabledForeground: Color(0xFFA3AAB4),
    disabledSurface: Color(0xFFF0F2F5),
    hoverSurface: Color(0xFFEDEFF3),
    pressedSurface: Color(0xFFE1E5EB),
    focusRing: Color(0xFF0F6CBD),
    selection: Color(0xFFCFE4FA),
    colorScheme: ColorScheme.light(
      primary: Color(0xFF0F6CBD),
      surfaceContainer: Color(0xFFEDEFF3),
      outline: Color(0xFFDCE0E6),
    ),
    textTheme: TextTheme(base: 13),
    iconTheme: IconThemeData(size: 16),
    density: ThemeDensity.compact,
    cornerRadius: 4.0,
    controlHeight: 32.0,
    controlPadding: 12.0,
  );

  /// High contrast, per section 28.3's `high-contrast` pseudo-class: pure
  /// extremes, always-visible borders, a thicker focus ring.
  static const ThemeData highContrastDark = ThemeData(
    name: 'high-contrast-dark',
    brightness: ThemeBrightness.dark,
    accent: Color(0xFFFFFF00),
    accentPressed: Color(0xFFFFD700),
    accentHovered: Color(0xFFFFFF66),
    accentSubtle: Color(0xFF3A3A00),
    surfaceBase: Color(0xFF000000),
    surface: Color(0xFF000000),
    surfaceAlternate: Color(0xFF000000),
    surfaceRaised: Color(0xFF000000),
    borderSubtle: Color(0xFFFFFFFF),
    border: Color(0xFFFFFFFF),
    borderStrong: Color(0xFFFFFFFF),
    foreground: Color(0xFFFFFFFF),
    foregroundSecondary: Color(0xFFFFFFFF),
    disabledForeground: Color(0xFF3FF23F),
    disabledSurface: Color(0xFF000000),
    hoverSurface: Color(0xFF2B2B00),
    pressedSurface: Color(0xFF3A3A00),
    focusRing: Color(0xFFFFFF00),
    selection: Color(0xFF1AEBFF),
    onSelection: Color(0xFF000000),
    colorScheme: ColorScheme.dark(
      primary: Color(0xFFFFFF00),
      onPrimary: Color(0xFF000000),
      surface: Color(0xFF000000),
      onSurface: Color(0xFFFFFFFF),
      surfaceContainer: Color(0xFF000000),
      outline: Color(0xFFFFFFFF),
    ),
    textTheme: TextTheme(base: 13),
    iconTheme: IconThemeData(color: Color(0xFFFFFFFF), size: 16),
    highContrast: true,
    cornerRadius: 4,
    controlHeight: 32,
    controlPadding: 12,
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
