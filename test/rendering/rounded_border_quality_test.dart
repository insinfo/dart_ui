import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  for (final scale in <double>[1, 1.25, 2]) {
    for (final phase in <double>[0, .37]) {
      test(
          'one-pixel pill stroke follows its circle at scale $scale, phase $phase',
          () async {
        final device = await const CpuRendererBackend().createDevice();
        final target = device.createTarget(MemorySurfaceDescriptor(
          pixelWidth: (220 * scale).ceil(),
          pixelHeight: (58 * scale).ceil(),
        )) as MemoryRenderTarget;
        final list = DisplayList();
        final paint = list.addPaint(
            colorArgb: 0xFFFFFFFF, style: paintStyleStroke, strokeWidth: scale);
        list.drawRRectUniform(
            10.5 * scale + phase,
            10.5 * scale + phase,
            209.5 * scale + phase,
            47.5 * scale + phase,
            18.5 * scale,
            18.5 * scale,
            paint);
        final center = 29 * scale + phase;
        await target.renderDisplayList(list, clearColor: 0);
        var worst = 0.0;
        for (var y = (10 * scale + phase).floor() - 1;
            y < center.floor();
            y++) {
          for (var x = (10 * scale + phase).floor() - 1;
              x < center.floor();
              x++) {
            var hits = 0;
            const samples = 100;
            for (var sy = 0; sy < samples; sy++) {
              for (var sx = 0; sx < samples; sx++) {
                final dx = x + (sx + .5) / samples - center;
                final dy = y + (sy + .5) / samples - center;
                final distance = math.sqrt(dx * dx + dy * dy);
                if (distance <= 19 * scale && distance >= 18 * scale) hits++;
              }
            }
            final fb = target.framebuffer;
            final alpha = fb.pixels[fb.offsetOf(x, y) + 3] / 255;
            worst = math.max(worst, (alpha - hits / (samples * samples)).abs());
          }
        }
        printOnFailure('maximum error: $worst');
        expect(worst, lessThan(.04),
            reason: 'maximum circular border coverage error');
      });
    }
  }
}
