import 'dart:async';
import 'dart:io';

import 'package:image/image.dart' as codec;
import 'package:poc_11_async_image_download/poc_11_async_image_download.dart';
import 'package:test/test.dart';

void main() {
  test('streams progress while Dart timers remain responsive and decodes BGRA',
      () async {
    final sourceImage = codec.Image(width: 64, height: 64);
    for (var y = 0; y < sourceImage.height; y++) {
      for (var x = 0; x < sourceImage.width; x++) {
        sourceImage.setPixelRgba(
          x,
          y,
          (x * 73 + y * 19) & 0xff,
          (x * 31 + y * 97) & 0xff,
          (x * 151 + y * 43) & 0xff,
          255,
        );
      }
    }
    final bytes = codec.encodePng(sourceImage);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..bufferOutput = false
        ..contentLength = bytes.length;
      for (var offset = 0; offset < bytes.length; offset += 128) {
        request.response.add(bytes.sublist(
          offset,
          (offset + 128).clamp(0, bytes.length),
        ));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await request.response.close();
    });

    final controller = ImageDownloadController();
    final progress = <int>[];
    controller.onChanged = (snapshot) {
      if (snapshot.phase == DownloadPhase.downloading) {
        progress.add(snapshot.receivedBytes);
      }
    };
    var timerTicks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => timerTicks++,
    );
    addTearDown(timer.cancel);

    await controller.start(
      Uri.parse('http://${server.address.host}:${server.port}/image'),
    );

    expect(
      controller.snapshot.phase,
      DownloadPhase.complete,
      reason: '${controller.snapshot.error}',
    );
    expect(controller.snapshot.image?.width, 64);
    expect(controller.snapshot.image?.height, 64);
    expect(controller.snapshot.image?.pixels, hasLength(64 * 64 * 4));
    expect(progress.length, greaterThan(2));
    expect(progress, orderedEquals(progress.toList()..sort()));
    expect(timerTicks, greaterThan(3));
  });

  test('reports invalid image data without throwing across the UI boundary',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    final controller = ImageDownloadController();

    await controller.start(
      Uri.parse('http://${server.address.host}:${server.port}/invalid'),
    );

    expect(controller.snapshot.phase, DownloadPhase.failed);
    expect(controller.snapshot.error, isA<FormatException>());
  });

  test('cancels an active streamed response and preserves a cancelled state',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.bufferOutput = false;
      try {
        for (var chunk = 0; chunk < 100; chunk++) {
          request.response.add(List<int>.filled(256, chunk & 0xff));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } on HttpException {
        // Expected when the client cancels the response.
      } finally {
        await request.response.close();
      }
    });

    final controller = ImageDownloadController();
    controller.onChanged = (snapshot) {
      if (snapshot.phase == DownloadPhase.downloading &&
          snapshot.receivedBytes > 0) {
        controller.cancel();
      }
    };

    await controller.start(
      Uri.parse('http://${server.address.host}:${server.port}/slow'),
    );

    expect(controller.snapshot.phase, DownloadPhase.cancelled);
    expect(controller.isActive, isFalse);
  });
}
