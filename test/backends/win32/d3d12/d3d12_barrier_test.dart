/// The transition barriers, with the debug layer as the oracle.
///
/// Every resource in Direct3D 12 has a state, every read and write requires a
/// particular one, and moving between them is the caller's job. There are two
/// ways to get it wrong and neither of them throws:
///
///   * a barrier whose `StateBefore` disagrees with the resource's actual
///     state, which the runtime is entitled to act on however it likes;
///   * a missing barrier, which leaves a resource in a layout the next stage
///     cannot read - correct on the driver it was written against and corrupt
///     on the next one.
///
/// So the assertion here is not about pixels. It is that a **complete frame** -
/// a swap chain buffer moved from `PRESENT` to `RENDER_TARGET` and back, an
/// upload heap copied into two atlas textures, those textures moved into
/// `PIXEL_SHADER_RESOURCE`, an offscreen surface copied into a readback buffer
/// and moved back to `RENDER_TARGET` - produces **no message of severity ERROR
/// or CORRUPTION** from `ID3D12InfoQueue`.
///
/// ## What is tolerated, and why that is not a loophole
///
/// Warnings and below are collected and printed, not failed. The one this
/// backend produces is the runtime pointing out that
/// `ClearRenderTargetView` was called on a resource created without an
/// optimised clear value, which is a performance hint about a decision this
/// backend makes on purpose: the clear colour comes from the caller's
/// `FrameRequest` and is not known when the surface is created, so declaring
/// one would be declaring a value that is usually wrong. Treating warnings as
/// failures would mean either lying about that or turning the test off.
///
/// The line is drawn where the SDK draws it: `D3D12_MESSAGE_SEVERITY_ERROR`
/// and `_CORRUPTION` mean the runtime believes the call was invalid. Those are
/// failures, and their text goes into the failure message verbatim.
///
/// ## The debug layer is only enabled here
///
/// It costs several times the driver call itself and needs the optional
/// "Graphics Tools" Windows feature. This file opens its own session with it
/// on; every other file runs without it. When it is not installed,
/// `D3D12GetDebugInterface` answers `DXGI_ERROR_SDK_COMPONENT_MISSING`, there
/// is no info queue, and these tests skip with that reason rather than
/// pretending to have validated anything.
library;

import 'dart:ffi';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_interfaces.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_structs.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'd3d12_session.dart';

void main() {
  final D3d12Session session =
      D3d12Session.open(debugLayer: true, window: true);

  /// Null when the debug layer answered; otherwise the reason to skip.
  ///
  /// Two things can put a reason here, and they are different problems:
  ///
  ///   * the "Graphics Tools" optional Windows feature is not installed, so
  ///     `D3D12GetDebugInterface` answers `DXGI_ERROR_SDK_COMPONENT_MISSING`;
  ///   * another suite in this test *process* created a device first.
  ///     `EnableDebugLayer` only applies to devices created after it, and
  ///     `package:test` runs suites as isolates of one process, so whether
  ///     this file gets an info queue depends on the order the runner
  ///     scheduled them in. Running this file on its own always works, and
  ///     that is how the barriers were validated.
  ///
  /// Both come back as a skip with the device's own diagnostics attached,
  /// because a barrier test that silently asserted nothing would be worse than
  /// one that says it did not run.
  final String? skip = session.skipReason ??
      (session.device!.infoQueue == null
          ? 'no ID3D12InfoQueue: either the optional "Graphics Tools" Windows '
              'feature is absent, or another suite in this process created a '
              'device before EnableDebugLayer ran. Device diagnostics: '
              '${session.device!.diagnostics.join('; ')}'
          : null);

  group('a complete frame draws no complaint from the debug layer', () {
    tearDownAll(session.close);

    test('an offscreen frame: atlases, images, readback', () async {
      final D3d12RenderDevice device = session.device!;
      device.infoQueue!.clearStoredMessages();

      final D3d12OffscreenTarget target = session.target(32, 32);
      final PresentResult result =
          await target.renderDisplayList(_scene(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented);

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('a windowed frame: PRESENT to RENDER_TARGET and back', () async {
      final D3d12RenderDevice device = session.device!;
      final D3d12WindowTarget target = device.createTarget(
        session.window!.describe(width: 64, height: 64),
      ) as D3d12WindowTarget;
      target.syncInterval = 0;
      expect(target.creationFailure, isNull);

      device.infoQueue!.clearStoredMessages();
      // Several frames, so the *second* pass over each back buffer is
      // included: the first time a buffer is used it comes straight from
      // creation, and only the second exercises the PRESENT state a previous
      // frame left it in.
      for (var frame = 0; frame < 4; frame++) {
        final PresentResult result =
            await target.renderDisplayList(_scene(), clearColor: 0xFF102030);
        expect(result.status, PresentStatus.presented,
            reason: '${result.diagnostic}');
      }

      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('resizing a swap chain draws no complaint either', () async {
      final D3d12RenderDevice device = session.device!;
      final D3d12WindowTarget target = device.createTarget(
        session.window!.describe(width: 64, height: 64),
      ) as D3d12WindowTarget;
      target.syncInterval = 0;
      await target.renderDisplayList(_scene(), clearColor: 0xFF102030);

      device.infoQueue!.clearStoredMessages();
      target.resize(100, 76, 1.0);
      await target.renderDisplayList(_scene(), clearColor: 0xFF102030);

      // The state most likely to be reported here is a back buffer released
      // while a command list still referenced it, which is exactly what the
      // GPU-idle wait in `resize` is for.
      _expectNoErrors(device);
      target.dispose();
    }, skip: skip);

    test('the device survives the whole file without being removed', () {
      final D3d12RenderDevice device = session.device!;
      expect(device.isLost, isFalse);
    }, skip: skip);
  });
}

/// Fails if the info queue holds anything the runtime called an error.
void _expectNoErrors(D3d12RenderDevice device) {
  final List<_Message> messages = _drain(device);
  final List<_Message> failures = messages
      .where((_Message m) =>
          m.severity == d3d12MessageSeverityCorruption ||
          m.severity == d3d12MessageSeverityError)
      .toList();
  // The tolerated ones are still printed: a new warning is worth reading even
  // when it is not worth failing on.
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

/// Reads and clears everything the info queue has stored.
///
/// `GetMessage` is called twice per message, as the API requires: once with a
/// null message to learn the byte length - the description is a variable-length
/// string stored after the structure - and once with a buffer of that size.
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
  return buffer.toString();
}

/// A frame that touches every path the barriers cover: a solid fill, a
/// translucent fill, an antialiased path through the coverage-mask atlas, a
/// glyph-free image upload, and a clip.
DisplayList _scene() {
  final DisplayList list = DisplayList();
  final int base = list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
  final int half = list.addPaint(colorArgb: 0x80CC3311, antiAlias: false);
  final int white = list.addPaint(colorArgb: 0xFFFFFFFF);

  final Framebuffer image = Framebuffer.allocate(
    width: 2,
    height: 2,
    format: PixelFormat.rgba8888Premultiplied,
  );
  for (var i = 0; i < 4; i++) {
    image.pixels[i * 4 + 1] = 0xFF;
    image.pixels[i * 4 + 3] = 0xFF;
  }
  final int id = list.addImage(image);

  list
    ..drawRect(0, 0, 32, 32, base)
    ..drawRect(2, 2, 20, 20, half)
    ..drawRRect(6, 6, 26, 26, 5, 5, 5, 5, 5, 5, 5, 5, white)
    ..save()
    ..clipRect(4, 4, 28, 28)
    ..drawImage(id, 0, 0, 2, 2, 8, 8, 24, 24, base)
    ..restore();
  return list;
}

/// `comFailed`, re-declared locally so this file does not import the COM
/// helpers only for a sign test.
bool comFailed(int hr) => hr < 0;
