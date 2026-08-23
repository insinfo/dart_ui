/// The two experimental passes, with the Direct3D 12 debug layer as the oracle.
///
/// `test/backends/win32/d3d12/d3d12_barrier_test.dart` makes the argument for
/// the dense renderer and this file makes it for the sparse-strip and
/// compute-tile executors, which is where it matters more rather than less:
/// both of them record into a command list somebody else opened, both bind
/// descriptors out of a heap somebody else owns, and both leave state behind
/// that the next pass inherits. None of that shows up as a wrong pixel on the
/// adapter it was written against - it shows up as a wrong pixel on the next
/// one, or as a device removed several calls later.
///
/// The specific complaints this file exists to catch:
///
///   * a root descriptor table that names an uninitialised descriptor, which is
///     what a solid sparse draw would do without the placeholder bind;
///   * an alpha page still in `COPY_DEST` when the pixel shader samples it;
///   * a UAV read back without leaving `UNORDERED_ACCESS` first;
///   * a coverage texture sampled while it is still in `UNORDERED_ACCESS`, or
///     written while it is still in `PIXEL_SHADER_RESOURCE` - the composition
///     pass moves it between the two twice per draw, and the bulk transition
///     that moves every *other* texture into a read state has to leave it
///     alone;
///   * a compute root signature that carries the input-assembler flag, or a
///     root parameter with a per-stage visibility a compute pipeline has not
///     got.
///
/// Errors and corruption fail. Warnings are printed and tolerated, for the
/// reason the barrier test states.
///
/// ## Run this file on its own, and why
///
/// `ID3D12Debug::EnableDebugLayer` applies to every device created afterwards
/// **in the same process**, and `package:test` runs suites as isolates of one
/// process. So enabling it here also enables it for whichever other Direct3D 12
/// suite happens to be scheduled next, and the debug layer costs several times
/// the driver call on every call. Running this file alongside the rest of the
/// directory has been observed to push the integrated adapter on this machine
/// past its timeout-detection limit: the adapter resets, and every other suite
/// then reports `DXGI_ERROR_DEVICE_REMOVED` from `CreateCommandQueue` and
/// skips with that reason.
///
/// That is a *scheduling* hazard and not a bug in the passes below - the same
/// suites pass with `-j 1`, and this file passes on its own - but it is a real
/// one, so the scenes here are deliberately small: a 24x24 surface and shapes
/// with a handful of segments, which is enough to reach every barrier and every
/// descriptor binding without asking a validated compute dispatch to do work.
/// The counterpart is the same rule `d3d12_barrier_test.dart` records: this
/// file is only meaningful when it is the one that got the info queue, and it
/// says so rather than pretending to have validated something.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_interfaces.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_structs.dart';
import 'package:dart_ui/src/geometry/path.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_path_strategy.dart';
import 'package:dart_ui/src/rendering/gpu/vector/compute_tile_scene.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strip_draw_plan.dart';
import 'package:dart_ui/src/rendering/gpu/vector/sparse_strips.dart';
import 'package:dart_ui/src/rendering/path/fill_rule.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import '../../../backends/win32/d3d12/d3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open(
    debugLayer: true,
    sparseStrips: true,
    computeTiles: true,
  );

  /// Null when the debug layer answered; otherwise the reason to skip.
  ///
  /// The same two causes the barrier test documents: the optional "Graphics
  /// Tools" Windows feature is absent, or another suite in this *process*
  /// created a device before `EnableDebugLayer` ran. Running this file on its
  /// own always works, and that is how these passes were validated.
  final String? skip = session.skipReason ??
      (session.device!.infoQueue == null
          ? 'no ID3D12InfoQueue: either the optional "Graphics Tools" Windows '
              'feature is absent, or another suite in this process created a '
              'device before EnableDebugLayer ran. Device diagnostics: '
              '${session.device!.diagnostics.join('; ')}'
          : null);

  group('the experimental passes draw no complaint', () {
    tearDownAll(session.close);

    test('a sparse-strip pass: solid instances and an alpha page', () async {
      final D3d12RenderDevice device = session.device!;
      device.infoQueue!.clearStoredMessages();

      final D3d12OffscreenTarget target = session.target(24, 24);
      target.enqueueSparseStrips(
        _sparsePlan(),
        materials: <SparseD3d12Material>[
          SparseD3d12Material(
            red: 0.5,
            green: 0.25,
            blue: 0.125,
            alpha: 1,
            blendMode: blendModeSrcOver,
          ),
        ],
      );
      final PresentResult result =
          await target.present(target.beginFrame(const FrameRequest(
        clearColor: 0xFF000000,
      )));
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('a compute-tile pass: root descriptors, a UAV and a readback',
        () async {
      final D3d12RenderDevice device = session.device!;
      device.infoQueue!.clearStoredMessages();

      final ComputeTileScene scene = ComputeTileScene();
      scene.appendPath(
        _diamond(),
        clip: const Rect.fromLTRB(0, 0, 24, 24),
        materialIndex: 0,
        fillRule: FillRule.nonZero,
      );
      final ComputeTilePlan plan =
          scene.build(width: 24, height: 24, tileSize: 16);
      expect(device.submitComputeTiles(plan).groupCount, plan.commandCount);

      _expectNoErrors(device);
    }, skip: skip);

    test('a compute composition: dispatch, barrier, quad, dense after it',
        () async {
      final D3d12RenderDevice device = session.device!;
      // The composition path is the one the display list actually takes now, so
      // this drives it the way a frame does rather than by calling the device
      // directly: a promoted path, then a dense rectangle over it.
      device.experimentalPathStrategySelector =
          const GpuPathStrategySelector(computeSegmentThreshold: 0);
      final D3d12OffscreenTarget target = session.target(24, 24);

      final DisplayList list = DisplayList();
      final int ink = list.addPaint(colorArgb: 0xFFCC3311);
      final int cover = list.addPaint(colorArgb: 0xFF1133CC, antiAlias: false);
      list
        ..drawPath(list.addPath(_diamond()), ink)
        ..drawRect(2, 2, 9, 9, cover);

      device.infoQueue!.clearStoredMessages();
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(target.composedComputeDraws, greaterThan(0),
          reason: 'the scene did not reach approach D, so this validated the '
              'wrong pass');

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('two composed draws in one frame reuse the coverage texture',
        () async {
      // Twice through the same texture, which is where a missing barrier
      // between the second dispatch and the first composite would be reported:
      // the resource has to leave PIXEL_SHADER_RESOURCE before it is written
      // again, and nothing else in this backend does that per draw.
      final D3d12RenderDevice device = session.device!;
      device.experimentalPathStrategySelector =
          const GpuPathStrategySelector(computeSegmentThreshold: 0);
      final D3d12OffscreenTarget target = session.target(24, 24);

      final DisplayList list = DisplayList();
      final int first = list.addPaint(colorArgb: 0xFFCC3311);
      final int second = list.addPaint(colorArgb: 0xFF11CC33);
      list
        ..drawPath(list.addPath(_diamond()), first)
        ..drawPath(list.addPath(_wedge()), second);

      device.infoQueue!.clearStoredMessages();
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(target.composedComputeDraws, 2);

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('the sparse pass leaves the dense renderer usable', () async {
      // The sparse executor replaces the root signature, the pipeline state,
      // the primitive topology and the scissor. Nothing rebinds them for the
      // dense path except `D3d12RenderDevice.submit` itself, so a second frame
      // that draws densely after a sparse frame is the check that it does.
      final D3d12RenderDevice device = session.device!;
      device.experimentalPathStrategySelector =
          const GpuPathStrategySelector();
      final D3d12OffscreenTarget target = session.target(24, 24);
      target.enqueueSparseStrips(
        _sparsePlan(),
        materials: <SparseD3d12Material>[
          SparseD3d12Material(
              red: 1, green: 1, blue: 1, alpha: 1, blendMode: blendModeSrcOver),
        ],
      );
      await target.present(target.beginFrame(const FrameRequest(
        clearColor: 0xFF000000,
      )));

      device.infoQueue!.clearStoredMessages();
      final PresentResult second = await target.renderDisplayList(
        _denseScene(),
        clearColor: 0xFF102030,
      );
      expect(second.status, PresentStatus.presented,
          reason: '${second.diagnostic}');
      // Ink, not just an absence of complaints: a dense frame that silently
      // drew nothing would also produce no messages.
      expect(_hasInkOtherThan(target, 0x10, 0x20, 0x30), isTrue);

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('the device survives the whole file without being removed', () {
      expect(session.device!.isLost, isFalse);
    }, skip: skip);
  });
}

SparseStripDrawPlan _sparsePlan() {
  final PathBuilder builder = PathBuilder()
    // Fractional edges, so the plan carries both solid runs and an alpha page:
    // a pass with no page would never bind the atlas descriptor table and the
    // uninitialised-descriptor complaint would not be reachable.
    ..moveTo(3.5, 3.5)
    ..lineTo(20.5, 5)
    ..lineTo(19, 20.25)
    ..lineTo(5, 18)
    ..close();
  final SparseStripDrawPlan plan = SparseStripDrawPlan();
  plan.append(
    SparseStripGenerator().fill(
      builder.build(),
      const Rect.fromLTRB(0, 0, 24, 24),
    ),
    materialIndex: 0,
  );
  expect(plan.alphaPageCount, greaterThan(0));
  expect(plan.solidInstanceCount, greaterThan(0));
  return plan;
}

Path _diamond() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(12, 3)
    ..lineTo(21, 12)
    ..lineTo(12, 21)
    ..lineTo(3, 12)
    ..close();
  return builder.build();
}

Path _wedge() {
  final PathBuilder builder = PathBuilder()
    ..moveTo(4, 20)
    ..lineTo(20, 5)
    ..lineTo(21, 20)
    ..close();
  return builder.build();
}

/// A dense scene: a rectangle and an antialiased path, so both the solid and
/// the coverage-mask pipeline run after the sparse pass has disturbed them.
DisplayList _denseScene() {
  final DisplayList list = DisplayList();
  final int flat = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final int aa = list.addPaint(colorArgb: 0xFF33CC55);
  list
    ..drawRect(2, 2, 11, 11, flat)
    ..drawPath(list.addPath(_diamond()), aa);
  return list;
}

bool _hasInkOtherThan(D3d12OffscreenTarget target, int r, int g, int b) {
  final Uint8List pixels = target.framebuffer.pixels;
  for (var i = 0; i < pixels.length; i += 4) {
    if (pixels[i] != r || pixels[i + 1] != g || pixels[i + 2] != b) return true;
  }
  return false;
}

/// Fails if the info queue holds anything the runtime called an error.
void _expectNoErrors(D3d12RenderDevice device) {
  final List<_Message> messages = _drain(device);
  final List<_Message> failures = messages
      .where((_Message m) =>
          m.severity == d3d12MessageSeverityCorruption ||
          m.severity == d3d12MessageSeverityError)
      .toList();
  printOnFailure(messages.isEmpty
      ? 'the debug layer said nothing at all'
      : messages.join('\n'));
  expect(
    failures,
    isEmpty,
    reason: 'the Direct3D 12 debug layer reported ${failures.length} '
        'error-level messages:\n${failures.join('\n')}',
  );
}

final class _Message {
  const _Message(this.severity, this.text);

  final int severity;
  final String text;

  @override
  String toString() => '[${_severityName(severity)}] $text';

  static String _severityName(int severity) => switch (severity) {
        d3d12MessageSeverityCorruption => 'CORRUPTION',
        d3d12MessageSeverityError => 'ERROR',
        d3d12MessageSeverityWarning => 'WARNING',
        _ => 'severity $severity',
      };
}

List<_Message> _drain(D3d12RenderDevice device) {
  final D3d12InfoQueue queue = device.infoQueue!;
  final Allocator allocator = device.library.allocator;
  final Pointer<IntPtr> length = allocator.allocate<IntPtr>(sizeOf<IntPtr>());
  final List<_Message> messages = <_Message>[];
  try {
    final int count = queue.storedMessageCount;
    for (var i = 0; i < count; i++) {
      length.value = 0;
      queue.getMessage(i, nullptr, length);
      if (length.value <= 0) continue;
      final Pointer<D3d12Message> message =
          allocator.allocate<D3d12Message>(length.value);
      try {
        if (comFailed(queue.getMessage(i, message, length))) continue;
        messages.add(_Message(message.ref.severity, _text(message)));
      } finally {
        allocator.free(message);
      }
    }
  } finally {
    allocator.free(length);
    queue.clearStoredMessages();
  }
  return messages;
}

String _text(Pointer<D3d12Message> message) {
  final Pointer<Uint8> bytes = message.ref.description;
  final StringBuffer buffer = StringBuffer();
  for (var i = 0; i < message.ref.descriptionByteLength; i++) {
    final int byte = bytes[i];
    if (byte == 0) break;
    buffer.writeCharCode(byte);
  }
  return buffer.toString().trim();
}
