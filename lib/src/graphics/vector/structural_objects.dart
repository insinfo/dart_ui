import '../../geometry/rect.dart';
import 'constants.dart';
import 'document_object.dart';

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/// A single page in the document.
///
/// A page owns a stack of [VectorLayer] children. It has a [pageFormat] that
/// defines its physical size and orientation.
class VectorPage extends DocumentObject {
  VectorPage({
    super.parent,
    String? name,
    PageFormat? pageFormat,
    super.children,
  })  : name = name ?? 'Page',
        pageFormat = pageFormat ?? const PageFormat.a4Portrait();

  /// Display name (e.g. "Page 1").
  String name;

  /// Physical format (size + orientation).
  PageFormat pageFormat;

  /// Layer counter for auto-naming.
  int layerCounter = 0;

  @override
  (bool, String, String) resolve([String name = '']) =>
      (false, this.name, '${children.length} layers');

  @override
  DocumentObject createEmpty() => VectorPage();

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is VectorPage) {
      target.name = name;
      target.pageFormat = pageFormat.copyWith();
      target.layerCounter = layerCounter;
    }
  }

  /// Convenience: page width in points.
  double get width => pageFormat.width;

  /// Convenience: page height in points.
  double get height => pageFormat.height;

  /// Page rect at origin.
  Rect get rect => pageFormat.rect;

  @override
  String toString() => 'VectorPage("$name", $pageFormat)';
}

// ---------------------------------------------------------------------------
// Layer
// ---------------------------------------------------------------------------

/// A drawing layer that holds vector objects.
///
/// Layers have visibility, editability, and printability flags in [properties].
class VectorLayer extends DocumentObject {
  VectorLayer({
    super.parent,
    String? name,
    this.color = kDefaultLayerColor,
    super.children,
    List<bool>? properties,
  })  : name = name ?? 'Layer',
        properties = properties ?? [true, true, true, true];

  /// Display name (e.g. "Layer 1").
  String name;

  /// Colour used for contour/wireframe view (packed ARGB).
  int color;

  /// `[visible, editable, printable, selectable]` flags.
  List<bool> properties;

  @override
  bool get isLayer => true;

  bool get isVisible => properties.isNotEmpty && properties[0];
  bool get isEditable => properties.length > 1 && properties[1];
  bool get isPrintable => properties.length > 2 && properties[2];

  @override
  (bool, String, String) resolve([String name = '']) =>
      (false, this.name, '${children.length} objects');

  @override
  DocumentObject createEmpty() => VectorLayer();

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is VectorLayer) {
      target.name = name;
      target.color = color;
      target.properties = List.of(properties);
    }
  }

  @override
  String toString() => 'VectorLayer("$name", visible=$isVisible)';
}

// ---------------------------------------------------------------------------
// Guide layer
// ---------------------------------------------------------------------------

/// Special layer that holds guide lines.
class GuideLayer extends VectorLayer {
  GuideLayer({super.parent, String? name, super.children})
      : super(
          name: name ?? 'GuideLayer',
          color: kDefaultGuideColor,
          properties: [true, true, false, false],
        );

  @override
  bool get isGuideLayer => true;

  @override
  DocumentObject createEmpty() => GuideLayer();
}

// ---------------------------------------------------------------------------
// Grid layer
// ---------------------------------------------------------------------------

/// Special layer that manages the document grid.
class GridLayer extends VectorLayer {
  GridLayer({
    super.parent,
    String? name,
    super.children,
    this.gridSpacingX = 10.0,
    this.gridSpacingY = 10.0,
  }) : super(
          name: name ?? 'GridLayer',
          color: kDefaultGridColor,
          properties: [false, false, false, true],
        );

  /// Grid spacing in X (in points).
  double gridSpacingX;

  /// Grid spacing in Y (in points).
  double gridSpacingY;

  @override
  bool get isGridLayer => true;

  @override
  DocumentObject createEmpty() =>
      GridLayer(gridSpacingX: gridSpacingX, gridSpacingY: gridSpacingY);

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is GridLayer) {
      target.gridSpacingX = gridSpacingX;
      target.gridSpacingY = gridSpacingY;
    }
  }

  @override
  String toString() => 'GridLayer(${gridSpacingX}x$gridSpacingY pt)';
}

// ---------------------------------------------------------------------------
// Layer groups
// ---------------------------------------------------------------------------

/// Container for layers applied to all pages.
class MasterLayers extends DocumentObject {
  MasterLayers({super.parent, super.children});

  int layerCounter = 0;

  @override
  DocumentObject createEmpty() => MasterLayers();

  @override
  String toString() => 'MasterLayers(${children.length} layers)';
}

/// Container for desktop (background) layers applied to all pages.
class DesktopLayers extends DocumentObject {
  DesktopLayers({super.parent, super.children});

  int layerCounter = 0;

  @override
  DocumentObject createEmpty() => DesktopLayers();

  @override
  String toString() => 'DesktopLayers(${children.length} layers)';
}

// ---------------------------------------------------------------------------
// Guide line
// ---------------------------------------------------------------------------

/// A guide line, either horizontal or vertical, at a fixed [position].
class VectorGuide extends DocumentObject {
  VectorGuide({
    super.parent,
    this.position = 0.0,
    this.isHorizontal = true,
  });

  /// Position along the relevant axis (in points).
  double position;

  /// True for a horizontal guide (extends across the page horizontally).
  bool isHorizontal;

  @override
  bool get isGuide => true;

  @override
  DocumentObject createEmpty() =>
      VectorGuide(position: position, isHorizontal: isHorizontal);

  @override
  void copyFields(DocumentObject target) {
    super.copyFields(target);
    if (target is VectorGuide) {
      target.position = position;
      target.isHorizontal = isHorizontal;
    }
  }

  @override
  String toString() =>
      'VectorGuide(${isHorizontal ? "H" : "V"} at $position pt)';
}
