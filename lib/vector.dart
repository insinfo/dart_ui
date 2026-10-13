/// Vector documents and the editing of them, with no user interface: the
/// model (pages, layers, shapes, curves, text, styles), its history, SVG,
/// PDF and CorelDRAW import and export, selection, snapping, the drawing
/// tools' state machines and text measuring.
///
/// What an editor's engine is built on. It imports nothing from widgets, so
/// an engine on top of it runs from a command line, a server or a test, and
/// the user interface over it can be this framework's or any other.
library;

export 'src/cdr/document/cdr_document.dart';
export 'src/cdr/document/cdr_translator.dart';
export 'src/foundation/value_notifier.dart';
export 'src/geometry/fill_rule.dart';
export 'src/geometry/offset.dart';
export 'src/geometry/path.dart';
export 'src/geometry/rect.dart';
export 'src/geometry/size.dart';
export 'src/geometry/transform2d.dart';
export 'src/graphics/color.dart';
export 'src/graphics/vector/arrowheads.dart';
export 'src/graphics/vector/bezier.dart';
export 'src/graphics/vector/constants.dart' hide TextAlign;
export 'src/graphics/vector/contour.dart';
export 'src/graphics/vector/doc_methods.dart';
export 'src/graphics/vector/document.dart';
export 'src/graphics/vector/document_history.dart';
export 'src/graphics/vector/document_object.dart';
export 'src/graphics/vector/pixmap.dart';
export 'src/graphics/vector/primitives.dart';
export 'src/graphics/vector/selectable_objects.dart';
export 'src/graphics/vector/serialization/vector_svg_codec.dart';
export 'src/graphics/vector/shaping.dart';
export 'src/graphics/vector/structural_objects.dart';
export 'src/graphics/vector/style.dart';
export 'src/pdf/export/vector_pdf_exporter.dart';
export 'src/rendering/text/font_registry.dart' show FontRegistry;
export 'src/rendering/text/framework_fonts.dart';
export 'src/vector_editing/curve_fitting.dart';
export 'src/vector_editing/freehand_tool.dart';
export 'src/vector_editing/node_editing.dart';
export 'src/vector_editing/parametric_handles.dart';
export 'src/vector_editing/path_boolean.dart';
export 'src/vector_editing/selection.dart';
export 'src/vector_editing/shape_tool.dart';
export 'src/vector_editing/snap_manager.dart';
export 'src/vector_editing/text_metrics.dart';
export 'src/vector_editing/tool_controller.dart';
export 'src/vector_editing/tool_mode.dart';
