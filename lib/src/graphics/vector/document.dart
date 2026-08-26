import '../../graphics/color.dart';
import 'constants.dart';
import 'document_object.dart';
import 'structural_objects.dart';
import 'style.dart';

/// The root node of a vector document.
///
/// Structure
/// ```
/// VectorDocument
///   ├── DesktopLayers
///   ├── Pages
///   │     ├── Page 1
///   │     │     ├── Layer 1
///   │     │     │     ├── (objects...)
///   │     │     │     └── ...
///   │     │     └── GuideLayer
///   │     └── Page 2 ...
///   └── MasterLayers
/// ```
class VectorDocument extends DocumentObject {
  VectorDocument({
    DocUnit? docUnits,
    DocOrigin? docOrigin,
    Map<String, VectorStyle>? styles,
    DocumentMetaInfo? metaInfo,
  })  : docUnits = docUnits ?? DocUnit.mm,
        docOrigin = docOrigin ?? DocOrigin.lowerLeft,
        styles = styles ?? _defaultStyles(),
        metaInfo = metaInfo ?? DocumentMetaInfo() {
    // Initialise default structure.
    desktopLayers = DesktopLayers(parent: this);
    pages = VectorPages(parent: this);
    masterLayers = MasterLayers(parent: this);

    children.addAll([desktopLayers, pages, masterLayers]);

    // Add one default page with one layer.
    addPage();
  }

  /// Creates an empty document structure without default pages or layers.
  VectorDocument.empty({
    DocUnit? docUnits,
    DocOrigin? docOrigin,
    Map<String, VectorStyle>? styles,
    DocumentMetaInfo? metaInfo,
  })  : docUnits = docUnits ?? DocUnit.mm,
        docOrigin = docOrigin ?? DocOrigin.lowerLeft,
        styles = styles ?? _defaultStyles(),
        metaInfo = metaInfo ?? DocumentMetaInfo();

  /// The unit of measure for this document.
  DocUnit docUnits;

  /// Where (0,0) lives in the document coordinate system.
  DocOrigin docOrigin;

  /// Named styles (e.g. "Default Style", "Default Text Style").
  Map<String, VectorStyle> styles;

  /// Document metadata (author, license, etc.).
  DocumentMetaInfo metaInfo;

  // --- Structural children (typed aliases) ---

  late final DesktopLayers desktopLayers;
  late final VectorPages pages;
  late final MasterLayers masterLayers;

  // --- Page management ---

  /// All pages in order.
  List<VectorPage> get pageList =>
      pages.children.whereType<VectorPage>().toList();

  /// Number of pages.
  int get pageCount => pages.children.length;

  /// Returns the page at [index].
  VectorPage getPage([int index = 0]) {
    final pl = pageList;
    if (index < 0 || index >= pl.length) {
      throw RangeError.range(index, 0, pl.length - 1, 'index');
    }
    return pl[index];
  }

  /// Adds a new page with optional [name] and [format].
  VectorPage addPage({String? name, PageFormat? format}) {
    pages._pageCounter++;
    final pageName = name ?? 'Page ${pages._pageCounter}';
    final page = VectorPage(
      parent: pages,
      name: pageName,
      pageFormat: format ?? const PageFormat.a4Portrait(),
    );

    // Add default layer + guide layer.
    page.layerCounter++;
    final layer = VectorLayer(
      parent: page,
      name: 'Layer ${page.layerCounter}',
    );
    final guideLayer = GuideLayer(parent: page);
    page.children.addAll([layer, guideLayer]);

    pages.children.add(page);
    return page;
  }

  /// Removes the page at [index].
  void removePage(int index) {
    if (pageCount <= 1) {
      throw StateError('Cannot remove the last page');
    }
    pages.children.removeAt(index);
  }

  // --- Layer management ---

  /// Returns all drawing layers of the given [page] (excluding special guide/grid layers).
  List<VectorLayer> getPageLayers(VectorPage page) => page.children
      .whereType<VectorLayer>()
      .where((l) => !l.isGuideLayer && !l.isGridLayer)
      .toList();

  /// Returns the desktop layers.
  List<VectorLayer> getDesktopLayers() => desktopLayers.children
      .whereType<VectorLayer>()
      .where((l) => !l.isGuideLayer && !l.isGridLayer)
      .toList();

  /// Returns the master layers.
  List<VectorLayer> getMasterLayers() => masterLayers.children
      .whereType<VectorLayer>()
      .where((l) => !l.isGuideLayer && !l.isGridLayer)
      .toList();

  /// Returns all visible layers for a page (desktop + page + master).
  List<VectorLayer> getVisibleLayers(VectorPage page) {
    final result = <VectorLayer>[];
    for (final l in getDesktopLayers()) {
      if (l.isVisible) result.add(l);
    }
    for (final l in getPageLayers(page)) {
      if (l.isVisible) result.add(l);
    }
    for (final l in getMasterLayers()) {
      if (l.isVisible) result.add(l);
    }
    return result;
  }

  /// Returns all editable layers for a page.
  List<VectorLayer> getEditableLayers(VectorPage page) {
    return getVisibleLayers(page).where((l) => l.isEditable).toList();
  }

  /// Adds a new layer to [page].
  VectorLayer addLayer(VectorPage page, {String? name}) {
    page.layerCounter++;
    final layerName = name ?? 'Layer ${page.layerCounter}';
    final layer = VectorLayer(parent: page, name: layerName);
    // Insert before the guide layer (last child).
    final insertIndex = page.children.isNotEmpty ? page.children.length - 1 : 0;
    page.children.insert(insertIndex, layer);
    return layer;
  }

  // --- Styles ---

  /// The default drawing style.
  VectorStyle get defaultStyle =>
      styles['Default Style'] ?? VectorStyle.defaultFill;

  /// Sets the default drawing style.
  set defaultStyle(VectorStyle value) => styles['Default Style'] = value;

  /// The default text style.
  VectorStyle get defaultTextStyle =>
      styles['Default Text Style'] ??
      const VectorStyle(
        fill: FillDescriptor.solid(Color(0xFF000000)),
        textStyle: TextStyleDescriptor(),
      );

  @override
  DocumentObject createEmpty() => VectorDocument.empty();

  @override
  DocumentObject copy() {
    final clone = VectorDocument.empty(
      docUnits: docUnits,
      docOrigin: docOrigin,
      styles: Map.of(styles),
      metaInfo: metaInfo.copyWith(),
    );
    for (final child in children) {
      final childClone = child.copy();
      childClone.parent = clone;
      clone.children.add(childClone);
      if (childClone is DesktopLayers) clone.desktopLayers = childClone;
      if (childClone is VectorPages) clone.pages = childClone;
      if (childClone is MasterLayers) clone.masterLayers = childClone;
    }
    return clone;
  }

  @override
  String toString() =>
      'VectorDocument($pageCount pages, units=$docUnits, origin=$docOrigin)';
}

// ---------------------------------------------------------------------------
// Pages container (internal)
// ---------------------------------------------------------------------------

class VectorPages extends DocumentObject {
  VectorPages({super.parent});

  int _pageCounter = 0;

  @override
  DocumentObject createEmpty() => VectorPages();

  @override
  String toString() => 'VectorPages(${children.length})';
}

// ---------------------------------------------------------------------------
// Document metadata
// ---------------------------------------------------------------------------

/// Metadata about the document (author, license, keywords, notes).
class DocumentMetaInfo {
  DocumentMetaInfo({
    this.author = '',
    this.license = '',
    this.keywords = '',
    this.notes = '',
  });

  String author;
  String license;
  String keywords;
  String notes;

  DocumentMetaInfo copyWith({
    String? author,
    String? license,
    String? keywords,
    String? notes,
  }) =>
      DocumentMetaInfo(
        author: author ?? this.author,
        license: license ?? this.license,
        keywords: keywords ?? this.keywords,
        notes: notes ?? this.notes,
      );

  @override
  String toString() => 'DocumentMetaInfo(author=$author)';
}

// ---------------------------------------------------------------------------
// Default styles
// ---------------------------------------------------------------------------

Map<String, VectorStyle> _defaultStyles() => {
      'Default Style': const VectorStyle(
        fill: FillDescriptor.solid(Color(0xFF000000)),
        stroke: StrokeDescriptor(
          color: Color(0xFF000000),
          width: 1.0,
        ),
      ),
      'Default Text Style': const VectorStyle(
        fill: FillDescriptor.solid(Color(0xFF000000)),
        textStyle: TextStyleDescriptor(
          fontFamily: 'Sans',
          fontSize: 12.0,
        ),
      ),
    };
