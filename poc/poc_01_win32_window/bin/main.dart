/// POC-01: Win32 Window in Pure Dart
///
/// Demonstrates creating a Win32 window, handling messages,
/// and rendering a CPU framebuffer — all in 100% pure Dart
/// using dart:ffi with NativeCallable for WndProc.
///
/// Usage:
///   dart run bin/main.dart              # Interactive window
///   dart run bin/main.dart --smoke-test # Auto-close after rendering
///
/// AOT:
///   dart compile exe bin/main.dart -o build/poc_01.exe
///   build\poc_01.exe
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lib/src/win32_constants.dart';
import '../lib/src/win32_functions.dart' show Win32;
import '../lib/src/win32_structs.dart';
import '../lib/src/win32_window.dart';

void main(List<String> args) {
  final smokeTest = args.contains('--smoke-test');
  final stressTest = args.contains('--stress-test');

  print('╔══════════════════════════════════════════════════╗');
  print('║  POC-01: Win32 Window in 100% Pure Dart         ║');
  print('║  No C/C++ wrapper, no Flutter, just dart:ffi    ║');
  print('╚══════════════════════════════════════════════════╝');
  print('');

  if (stressTest) {
    _runStressTest();
    return;
  }

  // Initialize Win32 subsystem
  Win32Window.initializeWin32();

  // Create and configure the window
  final window = Win32Window();

  var counter = 0;
  var mouseX = 0;
  var mouseY = 0;
  var mouseDown = false;
  var frameCount = 0;
  final stopwatch = Stopwatch()..start();

  window.onPaint = (w) {
    _renderScene(w, counter, mouseX, mouseY, mouseDown, frameCount);
    frameCount++;
  };

  window.onResize = (w, width, height) {
    print('[App] Resized to ${width}x$height');
  };

  window.onMouseMove = (w, x, y) {
    mouseX = x;
    mouseY = y;
    w.invalidate();
  };

  window.onMouseDown = (w, x, y, button) {
    mouseDown = true;
    if (button == 0) {
      // Left click — check if inside button
      if (_isInsideButton(w, x, y)) {
        counter++;
        print('[App] Counter: $counter');
      }
    }
    w.invalidate();
  };

  window.onMouseUp = (w, x, y, button) {
    mouseDown = false;
    w.invalidate();
  };

  window.onKey = (w, keyCode, isDown) {
    if (isDown) {
      if (keyCode == VK_ESCAPE) {
        w.close();
      } else if (keyCode == VK_SPACE || keyCode == VK_RETURN) {
        counter++;
        print('[App] Counter: $counter (keyboard)');
        w.invalidate();
      }
    }
  };

  window.onClose = (w) {
    final elapsed = stopwatch.elapsed;
    final fps = frameCount / elapsed.inMilliseconds * 1000;
    print('[App] Closing. Rendered $frameCount frames in '
        '${elapsed.inMilliseconds}ms (${fps.toStringAsFixed(1)} avg FPS)');
  };

  // Create the window
  window.create(
    title: 'DartUI POC-01 — Pure Dart Win32 Window 🎯',
    width: 900,
    height: 650,
  );
  window.show();

  if (smokeTest) {
    // For CI: render one frame then close
    print('[Smoke] Rendering one frame...');
    window.invalidate();
    // Process a few messages then close
    _pumpMessages(50);
    print('[Smoke] Closing window...');
    window.close();
    _pumpMessages(10);
    Win32Window.shutdownWin32();
    print('[Smoke] ✅ POC-01 smoke test passed!');
    exit(0);
  }

  // Run the message loop
  print('[App] Entering message loop (press Esc to exit)...');
  final exitCode = runMessageLoop();

  // Cleanup
  Win32Window.shutdownWin32();
  print('[App] Exited with code: $exitCode');
}

/// Render a scene demonstrating CPU framebuffer rendering.
void _renderScene(
  Win32Window w,
  int counter,
  int mouseX,
  int mouseY,
  bool mouseDown,
  int frameCount,
) {
  final fb = w.framebuffer;
  if (fb == null) return;
  final width = w.clientWidth;
  final height = w.clientHeight;

  // Background — dark blue gradient
  for (var y = 0; y < height; y++) {
    final t = y / height;
    final r = (20 + t * 15).toInt();
    final g = (25 + t * 20).toInt();
    final b = (40 + t * 30).toInt();
    final rowOffset = y * width * 4;
    for (var x = 0; x < width; x++) {
      final i = rowOffset + x * 4;
      fb[i + 0] = b; // B
      fb[i + 1] = g; // G
      fb[i + 2] = r; // R
      fb[i + 3] = 255; // A
    }
  }

  // Title text area (simulated with colored rect)
  _drawFilledRect(fb, width, height, 0, 0, width, 50, 30, 35, 55, 255);

  // Counter display area
  final counterStr = 'Contagem: $counter';
  _drawText(fb, width, height, width ~/ 2 - 60, 100, counterStr, 220, 220, 240);

  // Button
  final btnX = width ~/ 2 - 80;
  final btnY = height ~/ 2 - 25;
  const btnW = 160;
  const btnH = 50;

  // Check hover
  final hovered = mouseX >= btnX &&
      mouseX < btnX + btnW &&
      mouseY >= btnY &&
      mouseY < btnY + btnH;

  // Button colors
  int btnR, btnG, btnB;
  if (mouseDown && hovered) {
    btnR = 40;
    btnG = 100;
    btnB = 200; // pressed
  } else if (hovered) {
    btnR = 60;
    btnG = 130;
    btnB = 230; // hover
  } else {
    btnR = 50;
    btnG = 115;
    btnB = 220; // normal
  }

  // Button shadow
  _drawFilledRect(
      fb, width, height, btnX + 3, btnY + 3, btnW, btnH, 10, 15, 25, 180);
  // Button body
  _drawFilledRect(
      fb, width, height, btnX, btnY, btnW, btnH, btnB, btnG, btnR, 255);
  // Button border (top/left lighter, bottom/right darker)
  _drawHLine(fb, width, height, btnX, btnY, btnW, (btnB + 30).clamp(0, 255),
      (btnG + 30).clamp(0, 255), (btnR + 30).clamp(0, 255));
  _drawHLine(
      fb,
      width,
      height,
      btnX,
      btnY + btnH - 1,
      btnW,
      (btnB - 20).clamp(0, 255),
      (btnG - 20).clamp(0, 255),
      (btnR - 20).clamp(0, 255));
  _drawVLine(fb, width, height, btnX, btnY, btnH, (btnB + 20).clamp(0, 255),
      (btnG + 20).clamp(0, 255), (btnR + 20).clamp(0, 255));
  _drawVLine(
      fb,
      width,
      height,
      btnX + btnW - 1,
      btnY,
      btnH,
      (btnB - 30).clamp(0, 255),
      (btnG - 30).clamp(0, 255),
      (btnR - 30).clamp(0, 255));

  // Button label
  _drawText(
      fb, width, height, btnX + 20, btnY + 18, 'Incrementar', 240, 240, 255);

  // Mouse cursor indicator (small crosshair)
  _drawFilledRect(
      fb, width, height, mouseX - 2, mouseY - 2, 5, 5, 255, 100, 100, 200);

  // Status bar at bottom
  _drawFilledRect(
      fb, width, height, 0, height - 30, width, 30, 35, 30, 25, 255);
  _drawText(
      fb,
      width,
      height,
      10,
      height - 22,
      'DPI: ${w.dpi} | Scale: ${w.scale.toStringAsFixed(2)}x | '
      'Size: ${width}x$height | Frame: $frameCount | '
      'Mouse: $mouseX,$mouseY',
      160,
      160,
      170);

  // Animated element: spinning dots
  final angle = frameCount * 0.05;
  for (var i = 0; i < 8; i++) {
    final a = angle + i * (3.14159 * 2 / 8);
    final cx = width - 60 + (cos(a) * 25).toInt();
    final cy = 80 + (sin(a) * 25).toInt();
    final brightness = ((sin(angle + i * 0.8) + 1) * 127).toInt();
    _drawFilledRect(fb, width, height, cx - 3, cy - 3, 7, 7, brightness,
        100 + brightness ~/ 2, 255, 255);
  }
}

/// Check if coordinates are inside the button area.
bool _isInsideButton(Win32Window w, int x, int y) {
  final btnX = w.clientWidth ~/ 2 - 80;
  final btnY = w.clientHeight ~/ 2 - 25;
  return x >= btnX && x < btnX + 160 && y >= btnY && y < btnY + 50;
}

// ============================================================
// Primitive drawing functions (pixel-level, for POC only)
// ============================================================

void _drawFilledRect(
  Uint8List fb,
  int fbW,
  int fbH,
  int x,
  int y,
  int w,
  int h,
  int b,
  int g,
  int r,
  int a,
) {
  final x0 = x.clamp(0, fbW);
  final y0 = y.clamp(0, fbH);
  final x1 = (x + w).clamp(0, fbW);
  final y1 = (y + h).clamp(0, fbH);
  for (var py = y0; py < y1; py++) {
    final row = py * fbW * 4;
    for (var px = x0; px < x1; px++) {
      final i = row + px * 4;
      if (a == 255) {
        fb[i] = b;
        fb[i + 1] = g;
        fb[i + 2] = r;
        fb[i + 3] = 255;
      } else {
        // Simple alpha blend
        final sa = a / 255.0;
        final da = 1.0 - sa;
        fb[i] = (b * sa + fb[i] * da).toInt();
        fb[i + 1] = (g * sa + fb[i + 1] * da).toInt();
        fb[i + 2] = (r * sa + fb[i + 2] * da).toInt();
        fb[i + 3] = 255;
      }
    }
  }
}

void _drawHLine(
  Uint8List fb,
  int fbW,
  int fbH,
  int x,
  int y,
  int w,
  int b,
  int g,
  int r,
) {
  if (y < 0 || y >= fbH) return;
  final x0 = x.clamp(0, fbW);
  final x1 = (x + w).clamp(0, fbW);
  final row = y * fbW * 4;
  for (var px = x0; px < x1; px++) {
    final i = row + px * 4;
    fb[i] = b;
    fb[i + 1] = g;
    fb[i + 2] = r;
    fb[i + 3] = 255;
  }
}

void _drawVLine(
  Uint8List fb,
  int fbW,
  int fbH,
  int x,
  int y,
  int h,
  int b,
  int g,
  int r,
) {
  if (x < 0 || x >= fbW) return;
  final y0 = y.clamp(0, fbH);
  final y1 = (y + h).clamp(0, fbH);
  for (var py = y0; py < y1; py++) {
    final i = py * fbW * 4 + x * 4;
    fb[i] = b;
    fb[i + 1] = g;
    fb[i + 2] = r;
    fb[i + 3] = 255;
  }
}

/// Simple pixel-font text rendering for POC.
/// Uses a minimal 5x7 bitmap font — just enough to show text.
void _drawText(
  Uint8List fb,
  int fbW,
  int fbH,
  int x,
  int y,
  String text,
  int r,
  int g,
  int b,
) {
  var cx = x;
  for (var i = 0; i < text.length; i++) {
    final ch = text.codeUnitAt(i);
    final glyph = _getGlyph(ch);
    if (glyph != null) {
      for (var gy = 0; gy < 7; gy++) {
        for (var gx = 0; gx < 5; gx++) {
          if (glyph[gy] & (1 << (4 - gx)) != 0) {
            final px = cx + gx;
            final py = y + gy;
            if (px >= 0 && px < fbW && py >= 0 && py < fbH) {
              final idx = py * fbW * 4 + px * 4;
              fb[idx] = b;
              fb[idx + 1] = g;
              fb[idx + 2] = r;
              fb[idx + 3] = 255;
            }
          }
        }
      }
    }
    cx += 6; // 5px wide + 1px spacing
  }
}

/// Minimal 5x7 bitmap font — covers ASCII printable range.
List<int>? _getGlyph(int ch) {
  return _font5x7[ch];
}

/// 5x7 font data. Each entry is 7 rows, each row is a 5-bit bitmap.
/// Bit 4 = leftmost pixel, bit 0 = rightmost pixel.
final Map<int, List<int>> _font5x7 = {
  // Space
  0x20: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  // 0-9
  0x30: [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], // 0
  0x31: [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E], // 1
  0x32: [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F], // 2
  0x33: [0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E], // 3
  0x34: [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], // 4
  0x35: [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E], // 5
  0x36: [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], // 6
  0x37: [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08], // 7
  0x38: [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], // 8
  0x39: [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C], // 9
  // A-Z uppercase
  0x41: [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11], // A
  0x42: [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E], // B
  0x43: [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E], // C
  0x44: [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E], // D
  0x45: [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F], // E
  0x46: [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10], // F
  0x47: [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F], // G
  0x48: [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11], // H
  0x49: [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], // I
  0x4A: [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C], // J
  0x4B: [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], // K
  0x4C: [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F], // L
  0x4D: [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11], // M
  0x4E: [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11], // N
  0x4F: [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], // O
  0x50: [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10], // P
  0x51: [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D], // Q
  0x52: [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11], // R
  0x53: [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E], // S
  0x54: [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], // T
  0x55: [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], // U
  0x56: [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04], // V
  0x57: [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11], // W
  0x58: [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11], // X
  0x59: [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04], // Y
  0x5A: [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F], // Z
  // a-z lowercase
  0x61: [0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F], // a
  0x62: [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E], // b
  0x63: [0x00, 0x00, 0x0E, 0x11, 0x10, 0x11, 0x0E], // c
  0x64: [0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F], // d
  0x65: [0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E], // e
  0x66: [0x06, 0x08, 0x1E, 0x08, 0x08, 0x08, 0x08], // f
  0x67: [0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x0E], // g
  0x68: [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11], // h
  0x69: [0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E], // i
  0x6A: [0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C], // j
  0x6B: [0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12], // k
  0x6C: [0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], // l
  0x6D: [0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11], // m
  0x6E: [0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11], // n
  0x6F: [0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E], // o
  0x70: [0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10], // p
  0x71: [0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01], // q
  0x72: [0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10], // r
  0x73: [0x00, 0x00, 0x0F, 0x10, 0x0E, 0x01, 0x1E], // s
  0x74: [0x08, 0x08, 0x1E, 0x08, 0x08, 0x09, 0x06], // t
  0x75: [0x00, 0x00, 0x11, 0x11, 0x11, 0x11, 0x0F], // u
  0x76: [0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04], // v
  0x77: [0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A], // w
  0x78: [0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11], // x
  0x79: [0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E], // y
  0x7A: [0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F], // z
  // Punctuation
  0x21: [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04], // !
  0x2C: [0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x08], // ,
  0x2D: [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00], // -
  0x2E: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04], // .
  0x3A: [0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00], // :
  0x3F: [0x0E, 0x11, 0x01, 0x06, 0x04, 0x00, 0x04], // ?
  0x7C: [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], // |
  0x28: [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02], // (
  0x29: [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08], // )
};

/// Pump N messages from the Win32 message queue (for smoke test).
void _pumpMessages(int count) {
  final msg = calloc<MSG>();
  for (var i = 0; i < count; i++) {
    final result = Win32.PeekMessageW(msg, 0, 0, 0, 1); // PM_REMOVE
    if (result == 0) break;
    Win32.TranslateMessage(msg);
    Win32.DispatchMessageW(msg);
  }
  calloc.free(msg);
}

/// Stress test: open/close windows in a loop.
void _runStressTest() {
  const iterations = 100;
  print('[Stress] Running $iterations create/destroy cycles...');

  Win32Window.initializeWin32();
  final stopwatch = Stopwatch()..start();

  for (var i = 0; i < iterations; i++) {
    final window = Win32Window();
    window.create(title: 'Stress #$i', width: 400, height: 300);
    window.show();

    // Pump a few messages
    _pumpMessages(5);

    window.close();
    _pumpMessages(10);

    if ((i + 1) % 10 == 0) {
      print('[Stress] ${i + 1}/$iterations completed');
    }
  }

  stopwatch.stop();
  Win32Window.shutdownWin32();
  print('[Stress] ✅ $iterations cycles in ${stopwatch.elapsedMilliseconds}ms');
  print(
      '[Stress] Avg: ${(stopwatch.elapsedMilliseconds / iterations).toStringAsFixed(1)}ms/cycle');
}
