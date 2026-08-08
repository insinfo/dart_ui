import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';

// ---------------------------------------------------------------------------
// Which side of the process boundary should the frames cross?
//
// The two candidates for backend 3's future were an in-process embedder and a
// worker process with a better transport. The embedder's advantage is entirely
// about cost - no boundary to cross - so measuring what the boundary actually
// costs decides it, and this measures it three ways against the same host,
// the same window and the same frame:
//
//   pipe       FRAME + raw octets. Two copies, through a 64 KB kernel buffer.
//   shm        POSIX shared mapping. Dart writes the pixels where the host
//              reads them; only a control line goes through the pipe.
//   iosurface  The buffer type the WindowServer itself composites from. Same
//              zero copies, and the host does not rebuild a CGImage per frame.
//
// Reported per transport: median and p95 round-trip (Dart writes the frame ->
// host acknowledges it presented), plus the bytes that crossed the pipe.
// ---------------------------------------------------------------------------

const int frameWidth = 480;
const int frameHeight = 320;
const int frameBytes = frameWidth * frameHeight * 4;

class TransportResult {
  TransportResult(this.name, this.samples, this.pipeBytesPerFrame, this.note);

  final String name;
  final List<int> samples; // microseconds
  final int pipeBytesPerFrame;
  final String note;

  int get median => _percentile(50);
  int get p95 => _percentile(95);
  double get framesPerSecond => median == 0 ? 0 : 1000000 / median;

  int _percentile(int percent) {
    if (samples.isEmpty) return 0;
    final sorted = List<int>.from(samples)..sort();
    final index = ((sorted.length - 1) * percent / 100).round();
    return sorted[index];
  }
}

class _Host {
  _Host(this.process);

  final Process process;
  final List<String> lines = <String>[];
  late final Future<void> drained;

  static Future<_Host> start(String binary) async {
    final process = await Process.start(binary, const ['--command-stdin']);
    final host = _Host(process);
    host.drained = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(host.lines.add)
        .asFuture<void>();
    unawaited(process.stderr.transform(utf8.decoder).forEach(stderr.write));
    return host;
  }

  Future<String?> waitFor(bool Function(String line) predicate,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (final line in lines) {
        if (predicate(line)) return line;
      }
      await Future<void>.delayed(const Duration(microseconds: 200));
    }
    return null;
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: transport_benchmark <host-binary> [frames]');
    exitCode = 64;
    return;
  }
  final hostBinary = arguments.first;
  final frames = arguments.length > 1 ? int.parse(arguments[1]) : 120;

  final results = <TransportResult>[
    await _benchmarkPipe(hostBinary, frames),
    await _benchmarkSharedMemory(hostBinary, frames),
    await _benchmarkIOSurface(hostBinary, frames),
  ];

  print('');
  print('TRANSPORT_FRAMES=$frames  SIZE=${frameWidth}x$frameHeight  '
      'BYTES_PER_FRAME=$frameBytes');
  for (final result in results) {
    print('TRANSPORT=${result.name} '
        'median_us=${result.median} '
        'p95_us=${result.p95} '
        'fps=${result.framesPerSecond.toStringAsFixed(1)} '
        'pipe_bytes_per_frame=${result.pipeBytesPerFrame} '
        'note=${result.note}');
  }

  final ranked = results.where((r) => r.samples.isNotEmpty).toList()
    ..sort((a, b) => a.median.compareTo(b.median));
  if (ranked.isEmpty) {
    print('TRANSPORT_WINNER=none');
    exitCode = 1;
    return;
  }
  print('TRANSPORT_WINNER=${ranked.first.name}');
  final slowest = ranked.last;
  final fastest = ranked.first;
  if (fastest.median > 0) {
    print('TRANSPORT_SPEEDUP='
        '${(slowest.median / fastest.median).toStringAsFixed(2)}x '
        '(${slowest.name} -> ${fastest.name})');
  }
  if (results.any((r) => r.samples.isEmpty)) {
    print('TRANSPORT_INCOMPLETE='
        '${results.where((r) => r.samples.isEmpty).map((r) => r.name).toList()}');
    exitCode = 1;
  }
}

Future<int> _awaitWindow(_Host host) async {
  await host.waitFor((l) => l == 'PROTOCOL=3');
  final line = await host.waitFor((l) => l.startsWith('WINDOW_ID='));
  return int.parse((line ?? 'WINDOW_ID=0').split('=').last);
}

Future<void> _shutdown(_Host host) async {
  host.process.stdin.writeln('CLOSE');
  await host.process.stdin.flush();
  await host.waitFor((l) => l == 'CLOSE_OK');
  await host.process.stdin.close();
  await host.process.exitCode.timeout(const Duration(seconds: 10),
      onTimeout: () {
    host.process.kill(ProcessSignal.sigkill);
    return -1;
  });
  await host.drained;
}

/// Transport 1: the whole framebuffer goes through the pipe, every frame.
Future<TransportResult> _benchmarkPipe(String hostBinary, int frames) async {
  final host = await _Host.start(hostBinary);
  await _awaitWindow(host);
  final pixels = Uint8List(frameBytes);
  final samples = <int>[];
  final watch = Stopwatch();

  for (var frame = 0; frame < frames; frame++) {
    // Vary a byte per frame so nothing downstream can dedupe the work away.
    _paint(pixels, frame, frameWidth * 4);
    watch
      ..reset()
      ..start();
    host.process.stdin.write('FRAME $frameWidth $frameHeight $frameBytes\n');
    host.process.stdin.add(pixels);
    await host.process.stdin.flush();
    final ok = await host.waitFor((l) => l == 'FRAME_OK ${frame + 1}',
        timeout: const Duration(seconds: 10));
    watch.stop();
    if (ok == null) break;
    samples.add(watch.elapsedMicroseconds);
  }

  await _shutdown(host);
  return TransportResult('pipe', samples, frameBytes,
      'copied into the pipe and out of it, then wrapped per frame');
}

/// Transport 2: pixels live in a shared mapping; the pipe carries 30 bytes.
Future<TransportResult> _benchmarkSharedMemory(
    String hostBinary, int frames) async {
  final host = await _Host.start(hostBinary);
  await _awaitWindow(host);

  // macOS caps shared-memory names at 31 characters including the slash.
  final buffer =
      SharedFrameBuffer.create('/dartui-${pid % 100000}', frameBytes);
  var samples = <int>[];
  var note = 'zero copies; CGImage rebuilt per frame';
  try {
    host.process.stdin.writeln('SHM ${buffer.name} $frameBytes');
    await host.process.stdin.flush();
    if (await host.waitFor((l) => l.startsWith('SHM_OK')) == null) {
      note = 'host refused the mapping: '
          '${host.lines.where((l) => l.startsWith('ERROR=')).join(",")}';
    } else {
      final watch = Stopwatch();
      for (var frame = 0; frame < frames; frame++) {
        _paint(buffer.pixels, frame, frameWidth * 4);
        watch
          ..reset()
          ..start();
        host.process.stdin
            .writeln('PRESENT ${frame + 1} $frameWidth $frameHeight');
        await host.process.stdin.flush();
        final ok = await host.waitFor((l) => l == 'PRESENT_OK ${frame + 1} shm',
            timeout: const Duration(seconds: 10));
        watch.stop();
        if (ok == null) break;
        samples.add(watch.elapsedMicroseconds);
      }
    }
  } finally {
    await _shutdown(host);
    buffer.dispose();
  }
  final controlBytes = 'PRESENT 000 $frameWidth $frameHeight\n'.length;
  return TransportResult('shm', samples, controlBytes, note);
}

/// Transport 3: the compositor's own buffer type.
Future<TransportResult> _benchmarkIOSurface(
    String hostBinary, int frames) async {
  final host = await _Host.start(hostBinary);
  await _awaitWindow(host);

  IOSurfaceFrame? surface;
  var samples = <int>[];
  var note = 'zero copies; layer contents set once';
  try {
    surface = IOSurfaceFrame.create(width: frameWidth, height: frameHeight);
    host.process.stdin.writeln('SURFACE ${surface.id}');
    await host.process.stdin.flush();
    if (await host.waitFor((l) => l.startsWith('SURFACE_OK')) == null) {
      note = 'host could not look the surface up: '
          '${host.lines.where((l) => l.startsWith('ERROR=')).join(",")}';
    } else {
      final watch = Stopwatch();
      final stride = surface.bytesPerRow;
      for (var frame = 0; frame < frames; frame++) {
        watch
          ..reset()
          ..start();
        surface.withPixels((pixels) => _paint(pixels, frame, stride));
        host.process.stdin.writeln('PRESENT ${frame + 1}');
        await host.process.stdin.flush();
        final ok = await host.waitFor(
            (l) => l == 'PRESENT_OK ${frame + 1} surface',
            timeout: const Duration(seconds: 10));
        watch.stop();
        if (ok == null) break;
        samples.add(watch.elapsedMicroseconds);
      }
    }
  } on Object catch (error) {
    note = 'IOSurface unavailable: $error';
  } finally {
    await _shutdown(host);
    surface?.dispose();
  }
  final controlBytes = 'PRESENT 000\n'.length;
  return TransportResult('iosurface', samples, controlBytes, note);
}

/// A cheap per-frame pattern. Only the first rows change, so the measurement
/// stays about the transport rather than about how fast Dart can fill memory.
void _paint(Uint8List pixels, int frame, int bytesPerRow) {
  final blue = 40 + (frame % 200);
  for (var row = 0; row < 8; row++) {
    final start = row * bytesPerRow;
    for (var x = 0; x < frameWidth; x++) {
      final i = start + x * 4;
      if (i + 3 >= pixels.length) return;
      pixels[i] = blue;
      pixels[i + 1] = 120;
      pixels[i + 2] = 220;
      pixels[i + 3] = 255;
    }
  }
}
