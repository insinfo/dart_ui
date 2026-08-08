import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poc_20_macos_three_backends/poc_20_macos_three_backends.dart';
import 'package:poc_20_macos_three_backends/src/mach_port_transfer.dart';

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

/// Frame size is a parameter, not a constant, because the whole question is
/// how each transport scales with it: the pipe copies every byte twice, shared
/// memory copies none but still rebuilds a CGImage over all of them, and an
/// IOSurface should barely notice.
int frameWidth = 480;
int frameHeight = 320;
int get frameBytes => frameWidth * frameHeight * 4;

class TransportResult {
  TransportResult(this.name, this.samples, this.pipeBytesPerFrame, this.note);

  final String name;
  final List<int> samples; // microseconds
  final int pipeBytesPerFrame;
  final String note;

  /// The GitHub runner is shared hardware: medians moved by 2x between runs
  /// while the ratios between transports held. The minimum is the closest
  /// thing to "what this costs when the machine is not busy".
  int get best => samples.isEmpty ? 0 : samples.reduce((a, b) => a < b ? a : b);
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
    stderr.writeln('usage: transport_benchmark <host-binary> [frames] '
        '[WxH,WxH,...]');
    exitCode = 64;
    return;
  }
  final hostBinary = arguments.first;
  final frames = arguments.length > 1 ? int.parse(arguments[1]) : 120;
  final sizes = arguments.length > 2
      ? arguments[2].split(',').map(_parseSize).toList()
      : const [(480, 320)];

  var failed = false;
  for (final size in sizes) {
    frameWidth = size.$1;
    frameHeight = size.$2;
    // Fewer frames at 4K: the point is the per-frame cost, and a slow
    // transport at 8 MB per frame would otherwise dominate the job's runtime.
    final count =
        frameBytes > 4 * 1024 * 1024 ? (frames ~/ 4).clamp(15, 120) : frames;
    if (!await _runSuite(hostBinary, count)) failed = true;
  }
  if (failed) exitCode = 1;
}

(int, int) _parseSize(String value) {
  final parts = value.toLowerCase().split('x');
  if (parts.length != 2) throw FormatException('bad size: $value');
  return (int.parse(parts[0]), int.parse(parts[1]));
}

/// Returns false when a transport produced no samples at all.
Future<bool> _runSuite(String hostBinary, int frames) async {
  final results = <TransportResult>[
    await _benchmarkControlRoundTrip(hostBinary, frames),
    await _benchmarkPipe(hostBinary, frames),
    await _benchmarkSharedMemory(hostBinary, frames),
    await _benchmarkIOSurface(hostBinary, frames),
    await _benchmarkIOSurfacePort(hostBinary, frames),
  ];

  final label = '${frameWidth}x$frameHeight';
  print('');
  print('TRANSPORT_FRAMES=$frames  SIZE=$label  '
      'BYTES_PER_FRAME=$frameBytes');
  for (final result in results) {
    print('TRANSPORT=${result.name} '
        'size=$label '
        'min_us=${result.best} '
        'median_us=${result.median} '
        'p95_us=${result.p95} '
        'fps=${result.framesPerSecond.toStringAsFixed(1)} '
        'pipe_bytes_per_frame=${result.pipeBytesPerFrame} '
        'note=${result.note}');
  }

  // The baseline is not a transport: it is the floor every transport pays and
  // the only part an in-process embedder could remove.
  final baseline = results.firstWhere((r) => r.name == 'ipc-baseline').median;
  final best = results
      .where((r) => r.name != 'ipc-baseline' && r.samples.isNotEmpty)
      .fold<int>(1 << 30, (value, r) => r.median < value ? r.median : value);
  if (best < (1 << 30) && best > 0) {
    print('IPC_BASELINE_US=$baseline size=$label');
    print('EMBEDDER_HEADROOM_US=$baseline '
        '(${(baseline * 100 / best).toStringAsFixed(0)}% of the best '
        'transport round trip)');
  }

  final ranked = results
      .where((r) => r.name != 'ipc-baseline' && r.samples.isNotEmpty)
      .toList()
    ..sort((a, b) => a.median.compareTo(b.median));
  if (ranked.isEmpty) {
    print('TRANSPORT_WINNER=none size=$label');
    return false;
  }
  print('TRANSPORT_WINNER=${ranked.first.name} size=$label');
  final slowest = ranked.last;
  final fastest = ranked.first;
  if (fastest.median > 0) {
    print('TRANSPORT_SPEEDUP='
        '${(slowest.best / fastest.best).toStringAsFixed(2)}x '
        '(${slowest.name} -> ${fastest.name}) size=$label');
  }
  if (results.any((r) => r.samples.isEmpty)) {
    print('TRANSPORT_INCOMPLETE=$label '
        '${results.where((r) => r.samples.isEmpty).map((r) => r.name).toList()}');
    return false;
  }
  return true;
}

/// Not a transport: the cost of a round trip that carries no pixels at all.
///
/// Every transport pays this, and it is the ONLY part an in-process embedder
/// could remove. Whatever is left after subtracting it is work the embedder
/// would still have to do.
Future<TransportResult> _benchmarkControlRoundTrip(
    String hostBinary, int frames) async {
  final host = await _Host.start(hostBinary);
  await _awaitWindow(host);
  final samples = <int>[];
  final watch = Stopwatch();
  var seen = 0;
  for (var i = 0; i < frames; i++) {
    watch
      ..reset()
      ..start();
    host.process.stdin.writeln('PING');
    await host.process.stdin.flush();
    final target = seen + 1;
    final ok = await host.waitFor(
        (l) =>
            l == 'PONG' &&
            host.lines.where((x) => x == 'PONG').length >= target,
        timeout: const Duration(seconds: 10));
    watch.stop();
    if (ok == null) break;
    seen = host.lines.where((x) => x == 'PONG').length;
    samples.add(watch.elapsedMicroseconds);
  }
  await _shutdown(host);
  return TransportResult('ipc-baseline', samples, 5,
      'PING/PONG: the process boundary with no pixels attached');
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

/// Transport 4: the same IOSurface, acquired the supported way.
///
/// IOSurfaceLookup is deprecated, and run 31249520943 showed the rendezvous
/// handoff replacing it. What that run did not answer is whether the surface
/// costs more per frame once acquired this way. It should not - the mechanism
/// changes only how the host GETS the surface, and PRESENT is the same code -
/// but "should not" is not a measurement, and a regression here would put the
/// deprecated call back on the table.
Future<TransportResult> _benchmarkIOSurfacePort(
    String hostBinary, int frames) async {
  final host = await _Host.start(hostBinary);
  await _awaitWindow(host);

  IOSurfaceFrame? surface;
  final samples = <int>[];
  var note = 'zero copies; acquired by mach port, no deprecated call';
  try {
    // Not global: a success here cannot be the deprecated path in disguise.
    surface = IOSurfaceFrame.create(
        width: frameWidth, height: frameHeight, global: false);
    final port = surface.createMachPort();

    final pidLine = await host.waitFor((l) => l.startsWith('HOST_PID='));
    if (pidLine == null) {
      note = 'host never announced its pid';
    } else {
      final serviceName = 'dart-ui.bench.${pidLine.substring(9)}';
      host.process.stdin.writeln('PORT_SERVER $serviceName');
      await host.process.stdin.flush();
      final checkedIn =
          await host.waitFor((l) => l.startsWith('PORT_SERVER_OK'));
      if (checkedIn == null) {
        note = 'host could not check in as $serviceName';
      } else if (MachPortTransfer.rendezvousSend(serviceName, port, 0x51) !=
          kernSuccess) {
        note = 'the port never reached the host';
      } else {
        host.process.stdin.writeln('SURFACE_PORT RENDEZVOUS');
        await host.process.stdin.flush();
        final attached =
            await host.waitFor((l) => l.startsWith('SURFACE_PORT_OK'));
        if (attached == null) {
          note = 'host did not attach the surface';
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
                (l) => l == 'PRESENT_OK ${frame + 1} surface-port',
                timeout: const Duration(seconds: 10));
            watch.stop();
            if (ok == null) break;
            samples.add(watch.elapsedMicroseconds);
          }
        }
      }
    }
  } on Object catch (error) {
    note = 'mach port handoff unavailable: $error';
  } finally {
    await _shutdown(host);
    surface?.dispose();
  }
  return TransportResult('iosurface-port', samples, 12, note);
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
