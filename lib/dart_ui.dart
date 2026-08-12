/// dart_ui — framework de interface grafica multiplataforma em 100% Dart.
///
/// This is the public surface. Everything under `lib/src` is private by
/// convention: if a type is not exported here, it is not part of the contract
/// and may change without notice.
///
/// The layering follows section 8 of
/// `doc/ROTEIRO_FRAMEWORK_MULTIPLATAFORMA_100_PURO_DART.md`, and the
/// dependency rule from section 8.2 is enforced by which directory a file
/// lives in:
///
///   foundation  <- depends on nothing
///   geometry    <- depends on nothing
///   scheduler   <- foundation
///   graphics    <- foundation, geometry
///   platform    <- foundation, geometry, scheduler
///   text        <- foundation, geometry, graphics
///   rendering   <- foundation, geometry, graphics, text
///   layout      <- foundation, geometry, graphics
///   widgets     <- layout
///
/// No layer here may import a backend, and no backend may be referenced by
/// name from common code.
library;

export 'src/backends/headless/headless_backend.dart';
export 'src/backends/headless/headless_test_support.dart';
export 'src/diagnostics/dev_overlay.dart';
export 'src/foundation/diagnostics.dart';
export 'src/foundation/lifecycle.dart';
export 'src/gallery/gallery.dart';
export 'src/geometry/offset.dart';
export 'src/geometry/path.dart';
export 'src/geometry/rect.dart';
export 'src/geometry/size.dart';
export 'src/geometry/transform2d.dart';
export 'src/graphics/display_list.dart';
export 'src/graphics/display_list_debug.dart';
export 'src/graphics/display_list_geometry.dart';
export 'src/graphics/display_list_opcodes.dart';
export 'src/graphics/display_list_reader.dart';
export 'src/layout/alignment.dart';
export 'src/layout/box_constraints.dart';
export 'src/layout/edge_insets.dart';
export 'src/layout/pipeline.dart';
export 'src/layout/render_align.dart';
export 'src/layout/render_box.dart';
export 'src/layout/render_colored_box.dart';
export 'src/layout/render_constrained_box.dart';
export 'src/layout/render_flex.dart';
export 'src/layout/render_padding.dart';
export 'src/layout/render_stack.dart';
export 'src/layout/render_viewport.dart';
export 'src/platform/backend_selection.dart';
export 'src/platform/input_events.dart';
export 'src/platform/native_window.dart';
export 'src/platform/system_fonts.dart';
export 'src/platform/window_events.dart';
export 'src/rendering/cpu_canvas.dart';
export 'src/rendering/cpu_renderer.dart';
export 'src/rendering/framebuffer.dart';
export 'src/rendering/path/coverage_span_sink.dart';
export 'src/rendering/path/fill_rule.dart';
export 'src/rendering/path/scanline_filler.dart';
export 'src/rendering/path/stroker.dart';
export 'src/rendering/raster/blend.dart';
export 'src/rendering/raster/clip_stack.dart';
export 'src/rendering/raster/rasterizer.dart';
export 'src/rendering/render_object.dart';
export 'src/rendering/renderer.dart';
export 'src/rendering/replay/display_list_player.dart';
export 'src/rendering/replay/recording_sink.dart';
export 'src/rendering/replay/replay_state.dart';
export 'src/rendering/text/font_registry.dart';
export 'src/rendering/text/text_painter.dart';
export 'src/scheduler/dispatcher_priority.dart';
export 'src/scheduler/frame_scheduler.dart';
export 'src/scheduler/manual_dispatcher.dart';
export 'src/scheduler/timer_handle.dart';
export 'src/scheduler/ui_dispatcher.dart';
export 'src/text/bidi.dart';
export 'src/text/grapheme.dart';
export 'src/text/line_break.dart';
export 'src/text/shaper.dart';
export 'src/text/typeface.dart';
export 'src/widgets/actions.dart';
export 'src/widgets/basic.dart' hide RenderColoredBox;
export 'src/widgets/control.dart';
export 'src/widgets/controls.dart';
export 'src/widgets/element.dart';
export 'src/widgets/errors.dart';
export 'src/widgets/focus.dart';
export 'src/widgets/focus_scope.dart';
export 'src/widgets/keyboard_router.dart';
export 'src/widgets/list_box.dart';
export 'src/widgets/pointer_router.dart';
export 'src/widgets/popup.dart';
export 'src/widgets/properties.dart';
export 'src/widgets/semantics.dart';
export 'src/widgets/style.dart';
export 'src/widgets/theme.dart';
export 'src/widgets/widget.dart';
