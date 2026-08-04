import 'dart:async';
import 'dart:io';

import 'package:image/image.dart' as codec;
import 'package:poc_01_win32_window/poc_01_win32_window.dart';
import 'package:poc_10_event_loop/poc_10_event_loop.dart';
import 'package:poc_11_async_image_download/poc_11_async_image_download.dart';

const _interactiveImage = 'https://picsum.photos/640/360';
const _buttonX = 32;
const _buttonY = 40;
const _buttonWidth = 200;
const _buttonHeight = 56;

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    print('POC-11 UI is currently implemented for Windows.');
    return;
  }

  final smokeTest = args.contains('--smoke-test');
  HttpServer? smokeServer;
  if (smokeTest) smokeServer = await _startSmokeServer();

  Win32Window.initializeWin32();
  final window = Win32Window();
  final eventLoop = Win32EventLoop();
  final download = ImageDownloadController();
  var snapshot = download.snapshot;
  var uiTicks = 0;
  var maxTickGap = Duration.zero;
  var previousTick = DateTime.now();

  void refreshTitle() {
    if (!window.isCreated) return;
    final progress = snapshot.progress;
    final percent = progress == null ? '' : ' ${(progress * 100).round()}%';
    window.setTitle(
      'DartUI POC-11 | ${snapshot.phase.name}$percent | UI ticks $uiTicks',
    );
  }

  download.onChanged = (value) {
    snapshot = value;
    refreshTitle();
    window.invalidate();
    if (smokeTest &&
        (value.phase == DownloadPhase.complete ||
            value.phase == DownloadPhase.failed)) {
      Timer(const Duration(milliseconds: 250), window.close);
    }
  };

  window.onPaint = (current) => _render(current, snapshot, uiTicks);
  window.onResize = (current, _, __) => current.invalidate();
  window.onMouseDown = (current, x, y, button) {
    if (button != 0 || !_insideButton(x, y)) return;
    if (download.isActive) {
      download.cancel();
    } else {
      unawaited(download.start(Uri.parse(_interactiveImage)));
    }
    current.invalidate();
  };
  window.onClose = (_) => download.cancel(notify: false);

  window.create(
    title: 'DartUI POC-11 — Async image download',
    width: 900,
    height: 700,
  );
  window.show();

  previousTick = DateTime.now();
  final ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
    final now = DateTime.now();
    final gap = now.difference(previousTick);
    if (gap > maxTickGap) maxTickGap = gap;
    previousTick = now;
    uiTicks++;
    refreshTitle();
    window.invalidate();
  });

  if (smokeServer != null) {
    unawaited(download.start(
      Uri.parse('http://${smokeServer.address.host}:${smokeServer.port}/image'),
    ));
  }

  await eventLoop.runUntil(
    () => window.isDestroyed,
    idleTimeout: const Duration(milliseconds: 16),
  );

  ticker.cancel();
  download.cancel(notify: false);
  eventLoop.dispose();
  await smokeServer?.close(force: true);
  Win32Window.shutdownWin32();

  print('[POC-11] phase=${snapshot.phase.name}, uiTicks=$uiTicks, '
      'maxTickGap=${maxTickGap.inMilliseconds}ms');
  if (smokeTest && snapshot.phase != DownloadPhase.complete) exitCode = 1;
}

bool _insideButton(int x, int y) =>
    x >= _buttonX &&
    x < _buttonX + _buttonWidth &&
    y >= _buttonY &&
    y < _buttonY + _buttonHeight;

void _render(Win32Window window, DownloadSnapshot snapshot, int tick) {
  window.clearFramebuffer(30, 24, 20, 255);

  final active = snapshot.phase == DownloadPhase.downloading ||
      snapshot.phase == DownloadPhase.decoding;
  window.fillRect(
    _buttonX + 4,
    _buttonY + 5,
    _buttonWidth,
    _buttonHeight,
    12,
    12,
    12,
    255,
  );
  window.fillRect(
    _buttonX,
    _buttonY,
    _buttonWidth,
    _buttonHeight,
    active ? 70 : 220,
    active ? 70 : 115,
    active ? 210 : 45,
    255,
  );

  // Download arrow or cancel cross inside the clickable button.
  if (active) {
    window.fillRect(119, 54, 6, 28, 245, 245, 245, 255);
    window.fillRect(108, 65, 28, 6, 245, 245, 245, 255);
  } else {
    window.fillRect(119, 51, 6, 25, 245, 245, 245, 255);
    for (var row = 0; row < 10; row++) {
      window.fillRect(109 + row, 70 + row, 26 - row * 2, 1, 245, 245, 245, 255);
    }
  }

  const barX = 264;
  const barY = 54;
  final barWidth = (window.clientWidth - barX - 32).clamp(1, 1000);
  window.fillRect(barX, barY, barWidth, 28, 55, 48, 43, 255);
  final progress = snapshot.progress;
  if (progress != null) {
    window.fillRect(
      barX,
      barY,
      (barWidth * progress).round(),
      28,
      235,
      165,
      65,
      255,
    );
  } else if (active) {
    final runnerWidth = barWidth.clamp(1, 90);
    final travel = (barWidth - runnerWidth).clamp(1, 1000);
    final x = barX + (tick * 7) % travel;
    window.fillRect(x, barY, runnerWidth, 28, 235, 165, 65, 255);
  }

  // Continuously moving pulse proves that rendering remains responsive.
  final pulseWidth = (window.clientWidth - 64).clamp(1, 1000);
  window.fillRect(32, 118, pulseWidth, 8, 45, 40, 36, 255);
  window.fillRect(32 + (tick * 5) % pulseWidth, 114, 12, 16, 255, 110, 80, 255);

  final downloaded = snapshot.image;
  if (downloaded != null) {
    _drawImage(window, downloaded, 32, 154);
  } else {
    final placeholderWidth = (window.clientWidth - 64).clamp(3, 2000);
    final placeholderHeight = (window.clientHeight - 186).clamp(3, 1200);
    // Only paint a thin frame. Filling this entire region pixel-by-pixel made
    // maximized-window downloads a misleading CPU-bound UI benchmark.
    window.fillRect(32, 154, placeholderWidth, 3, 42, 34, 30, 255);
    window.fillRect(
      32,
      154 + placeholderHeight - 3,
      placeholderWidth,
      3,
      42,
      34,
      30,
      255,
    );
    window.fillRect(32, 154, 3, placeholderHeight, 42, 34, 30, 255);
    window.fillRect(
      32 + placeholderWidth - 3,
      154,
      3,
      placeholderHeight,
      42,
      34,
      30,
      255,
    );
  }
}

void _drawImage(
  Win32Window window,
  DecodedBgraImage image,
  int targetX,
  int targetY,
) {
  final availableWidth = window.clientWidth - targetX - 32;
  final availableHeight = window.clientHeight - targetY - 32;
  if (availableWidth <= 0 || availableHeight <= 0) return;
  final scaleX = availableWidth / image.width;
  final scaleY = availableHeight / image.height;
  final fittingScale = scaleX < scaleY ? scaleX : scaleY;
  final scale = fittingScale < 1 ? fittingScale : 1.0;
  final targetWidth = (image.width * scale).round().clamp(1, availableWidth);
  final targetHeight = (image.height * scale).round().clamp(1, availableHeight);
  final framebuffer = window.framebuffer;
  if (framebuffer == null) return;

  if (targetWidth == image.width && targetHeight == image.height) {
    final rowBytes = image.width * 4;
    for (var y = 0; y < image.height; y++) {
      final source = y * rowBytes;
      final destination = ((targetY + y) * window.clientWidth + targetX) * 4;
      framebuffer.setRange(
        destination,
        destination + rowBytes,
        image.pixels,
        source,
      );
    }
    return;
  }

  for (var y = 0; y < targetHeight; y++) {
    final sourceY = y * image.height ~/ targetHeight;
    for (var x = 0; x < targetWidth; x++) {
      final sourceX = x * image.width ~/ targetWidth;
      final source = (sourceY * image.width + sourceX) * 4;
      final destination =
          ((targetY + y) * window.clientWidth + targetX + x) * 4;
      framebuffer[destination] = image.pixels[source];
      framebuffer[destination + 1] = image.pixels[source + 1];
      framebuffer[destination + 2] = image.pixels[source + 2];
      framebuffer[destination + 3] = image.pixels[source + 3];
    }
  }
}

Future<HttpServer> _startSmokeServer() async {
  final testImage = codec.Image(width: 64, height: 36);
  for (var y = 0; y < testImage.height; y++) {
    for (var x = 0; x < testImage.width; x++) {
      testImage.setPixelRgba(x, y, x * 4, y * 7, 220, 255);
    }
  }
  final bytes = codec.encodePng(testImage);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..bufferOutput = false
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('image', 'png')
      ..contentLength = bytes.length;
    try {
      for (var offset = 0; offset < bytes.length; offset += 8) {
        final end = (offset + 8).clamp(0, bytes.length);
        request.response.add(bytes.sublist(offset, end));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await request.response.close();
    } on HttpException {
      // The client can close early when exercising cancellation.
    }
  });
  return server;
}
