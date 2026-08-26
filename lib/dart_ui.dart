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
///   graphics    <- ffi, foundation, geometry
///   platform    <- foundation, geometry, scheduler
///   gestures    <- geometry, platform, scheduler
///   text        <- foundation, geometry, graphics
///   rendering   <- foundation, geometry, graphics, text
///   layout      <- foundation, geometry, graphics, rendering, text
///   animation   <- foundation, geometry, scheduler
///   widgets     <- layout, animation
///   app         <- everything above, no backend
///
/// No layer here may import a backend, and no backend may be referenced by
/// name from common code. `test/architecture/layering_test.dart` enforces
/// this by reading the imports, so a violation fails the suite rather than
/// waiting to be noticed in review.
///
/// Two things deliberately stay out of this file. The **generated Unicode
/// tables** under `src/text/tables/` are data with a regeneration command
/// (`tool/generate_unicode_tables.dart`), not API - the algorithms that read
/// them are exported instead. The **GPU backend internals** under
/// `src/rendering/gpu/` are reached through the `RendererBackend` contract in
/// `src/rendering/renderer.dart`; exporting the OpenGL types by name would
/// invite callers to write against one backend, which is the coupling section
/// 6.2 exists to prevent.
library;

import 'src/app/application.dart' as app;
import 'src/backends/default_platform_resolver_stub.dart'
    if (dart.library.io) 'src/backends/default_platform_resolver.dart';
import 'src/widgets/widget.dart';

export 'src/animation/animation.dart';
export 'src/animation/clock.dart';
export 'src/animation/curves.dart';
export 'src/animation/keyframes.dart';
export 'src/animation/simulation.dart';
export 'src/app/app.dart' hide runApp;
export 'src/audio/audio.dart';
export 'src/backends/default_platform_resolver_stub.dart'
    if (dart.library.io) 'src/backends/default_platform_resolver.dart';
export 'src/backends/headless/headless_backend.dart';
export 'src/backends/headless/headless_test_support.dart';
export 'src/cdr/document/cdr_document.dart';
export 'src/cdr/document/cdr_translator.dart';
export 'src/crypto/asn1/der.dart';
export 'src/crypto/certificate_provider.dart';
export 'src/crypto/crypto.dart';
export 'src/crypto/crypto_backend.dart';
export 'src/crypto/crypto_identity.dart';
export 'src/crypto/external_key_signer.dart';
export 'src/crypto/linux/linux.dart';
export 'src/crypto/macos/macos.dart';
export 'src/crypto/pkcs11/pkcs11.dart';
export 'src/crypto/windows/windows_certificate_store.dart';
export 'src/crypto/x509/x509_certificate.dart';
export 'src/diagnostics/dev_overlay.dart';
export 'src/foundation/compute.dart';
export 'src/foundation/diagnostics.dart';
export 'src/foundation/lifecycle.dart';
export 'src/foundation/locale.dart';
export 'src/foundation/lru_cache.dart';
export 'src/gallery/gallery.dart';
export 'src/geometry/offset.dart';
export 'src/geometry/path.dart';
export 'src/geometry/rect.dart';
export 'src/geometry/size.dart';
export 'src/geometry/transform2d.dart';
export 'src/gestures/gestures.dart';
export 'src/graphics/color.dart';
export 'src/graphics/content_hint.dart';
export 'src/graphics/display_list.dart';
export 'src/graphics/display_list_debug.dart';
export 'src/graphics/display_list_geometry.dart';
export 'src/graphics/display_list_opcodes.dart';
export 'src/graphics/display_list_pool.dart';
export 'src/graphics/display_list_reader.dart';
export 'src/graphics/gradient.dart';
export 'src/graphics/gradient_lut.dart';
export 'src/graphics/image/decoded_image.dart';
export 'src/graphics/image/image_errors.dart';
export 'src/graphics/image/inflate.dart';
export 'src/graphics/image/png.dart';
export 'src/graphics/image/raster_codec.dart';
export 'src/graphics/image/raster_formats.dart';
export 'src/graphics/svg/svg_path.dart';
export 'src/graphics/svg/svg_picture.dart';
export 'src/graphics/vector/bezier.dart';
export 'src/graphics/vector/constants.dart' hide FillRule, TextAlign;
export 'src/graphics/vector/contour.dart';
export 'src/graphics/vector/doc_methods.dart';
export 'src/graphics/vector/document.dart';
export 'src/graphics/vector/document_object.dart';
export 'src/graphics/vector/pixmap.dart';
export 'src/graphics/vector/primitives.dart';
export 'src/graphics/vector/selectable_objects.dart';
export 'src/graphics/vector/serialization/vector_svg_codec.dart';
export 'src/graphics/vector/shaping.dart';
export 'src/graphics/vector/structural_objects.dart';
export 'src/graphics/vector/style.dart';
export 'src/graphics/video/av_sync.dart';
export 'src/graphics/video/video_color_conversion.dart';
export 'src/graphics/video/video_decoder.dart';
export 'src/graphics/video/video_frame.dart';
export 'src/layout/alignment.dart';
export 'src/layout/box_constraints.dart';
export 'src/layout/edge_insets.dart';
export 'src/layout/layout_errors.dart';
export 'src/layout/pipeline.dart';
export 'src/layout/pixel_snap.dart';
export 'src/layout/render_align.dart';
export 'src/layout/render_aspect_ratio.dart';
export 'src/layout/render_box.dart';
export 'src/layout/render_colored_box.dart';
export 'src/layout/render_constrained_box.dart';
export 'src/layout/render_flex.dart';
export 'src/layout/render_grid.dart';
export 'src/layout/render_padding.dart';
export 'src/layout/render_proxy_box.dart';
export 'src/layout/render_stack.dart';
export 'src/layout/render_viewport.dart';
export 'src/layout/render_wrap.dart';
export 'src/pdf/export/vector_pdf_exporter.dart';
export 'src/platform/backend_selection.dart';
export 'src/platform/drag_drop.dart';
export 'src/platform/file_picker.dart';
export 'src/platform/file_watcher.dart';
export 'src/platform/input_events.dart';
export 'src/platform/message_box.dart';
export 'src/platform/native_window.dart';
export 'src/platform/shell.dart';
export 'src/platform/standard_paths.dart';
export 'src/platform/system_fonts.dart';
export 'src/platform/system_info.dart';
export 'src/platform/text_input.dart';
export 'src/platform/trash.dart';
export 'src/platform/window_events.dart';
export 'src/rendering/cpu_canvas.dart';
export 'src/rendering/cpu_renderer.dart';
export 'src/rendering/framebuffer.dart';
export 'src/rendering/gpu/gpu_path_strategy.dart';
export 'src/rendering/path/coverage_span_sink.dart';
export 'src/rendering/path/fill_rule.dart';
export 'src/rendering/path/scanline_filler.dart';
export 'src/rendering/path/stroker.dart';
export 'src/rendering/raster/blend.dart';
export 'src/rendering/raster/clip_stack.dart';
export 'src/rendering/raster/rasterizer.dart';
export 'src/rendering/render_diagnostics.dart';
export 'src/rendering/render_object.dart';
export 'src/rendering/render_policy.dart';
export 'src/rendering/renderer.dart';
export 'src/rendering/replay/display_list_player.dart';
export 'src/rendering/replay/recording_sink.dart';
export 'src/rendering/replay/replay_state.dart';
export 'src/rendering/text/font_registry.dart';
export 'src/rendering/text/framework_fonts.dart';
export 'src/rendering/text/text_painter.dart';
export 'src/scheduler/dispatcher_priority.dart';
export 'src/scheduler/frame_scheduler.dart';
export 'src/scheduler/manual_dispatcher.dart';
export 'src/scheduler/timer_handle.dart';
export 'src/scheduler/ui_dispatcher.dart';
export 'src/semantics/semantics.dart';
export 'src/text/bidi.dart';
export 'src/text/case_mapping.dart';
export 'src/text/cff.dart';
export 'src/text/font_tables.dart';
export 'src/text/grapheme.dart';
export 'src/text/line_break.dart';
export 'src/text/normalize.dart';
export 'src/text/paragraph.dart' hide TextStyle;
export 'src/text/script.dart';
export 'src/text/shaper.dart';
export 'src/text/shapers/arabic.dart';
export 'src/text/shapers/script_models.dart';
export 'src/text/typeface.dart';
export 'src/text/word_break.dart';
export 'src/widgets/actions.dart';
export 'src/widgets/animation_scope.dart';
export 'src/widgets/badge.dart';
export 'src/widgets/basic.dart' hide RenderColoredBox;
export 'src/widgets/bounded_draggable.dart';
export 'src/widgets/calendar.dart';
export 'src/widgets/combo_box.dart';
export 'src/widgets/control.dart';
export 'src/widgets/controls.dart';
export 'src/widgets/dart_ui_app.dart';
export 'src/widgets/data_grid.dart';
export 'src/widgets/directionality.dart';
export 'src/widgets/docking.dart';
export 'src/widgets/drag_drop.dart';
export 'src/widgets/element.dart';
export 'src/widgets/errors.dart';
export 'src/widgets/expander.dart';
export 'src/widgets/focus.dart';
export 'src/widgets/focus_scope.dart';
export 'src/widgets/gesture_detector.dart';
export 'src/widgets/icon.dart';
export 'src/widgets/icon_button.dart';
export 'src/widgets/image.dart';
export 'src/widgets/info_bar.dart';
export 'src/widgets/keyboard_router.dart';
export 'src/widgets/list_box.dart';
export 'src/widgets/localizations.dart';
export 'src/widgets/media_query.dart';
export 'src/widgets/navigator.dart';
export 'src/widgets/number_box.dart';
export 'src/widgets/overlay.dart';
export 'src/widgets/phosphor_icons.dart';
export 'src/widgets/pointer_router.dart';
export 'src/widgets/popup.dart';
export 'src/widgets/progress_indicator.dart';
export 'src/widgets/properties.dart';
export 'src/widgets/proxy.dart';
export 'src/widgets/routes.dart';
export 'src/widgets/safe_area.dart';
export 'src/widgets/scroll_view.dart';
export 'src/widgets/scrollbar.dart';
export 'src/widgets/signal_visualization.dart';
export 'src/widgets/split_view.dart';
export 'src/widgets/style.dart';
export 'src/widgets/svg.dart';
export 'src/widgets/tabs.dart';
export 'src/widgets/theme.dart';
export 'src/widgets/toolbar.dart';
export 'src/widgets/tree_view.dart';
export 'src/widgets/vector_editor/color_controls.dart';
export 'src/widgets/vector_editor/fill_controls.dart';
export 'src/widgets/vector_editor/ruler.dart';
export 'src/widgets/vector_editor/selection.dart';
export 'src/widgets/vector_editor/snap_manager.dart';
export 'src/widgets/vector_editor/stroke_controls.dart';
export 'src/widgets/vector_editor/text_edit_controller.dart';
export 'src/widgets/vector_editor/text_metrics.dart';
export 'src/widgets/vector_editor/tool_controller.dart';
export 'src/widgets/vector_editor/vector_canvas.dart';
export 'src/widgets/vector_editor/vector_renderer.dart';
export 'src/widgets/video.dart';
export 'src/widgets/widget.dart';

/// Mounts [rootWidget] using production platform defaults.
///
/// Supplying [backends] or [presentations] keeps the low-level injection seam
/// available for tests, custom platforms and experimental renderers. Omitting
/// them selects the native window backend, ranks registered direct GPU paths
/// first (D3D11/OpenGL today), and retains CPU/headless paths as diagnosed
/// fallbacks.
Future<app.Application> runApp(
  Widget rootWidget, {
  List<app.WindowingBackendEntry>? backends,
  List<app.PresentationPathEntry>? presentations,
  app.ApplicationOptions options = const app.ApplicationOptions(),
}) =>
    app.runApp(
      rootWidget,
      backends:
          backends ?? PlatformBackendResolver.defaultBackends(options: options),
      presentations:
          presentations ?? PlatformBackendResolver.defaultPresentations(),
      options: options,
    );
