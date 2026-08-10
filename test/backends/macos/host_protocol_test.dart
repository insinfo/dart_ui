import 'dart:convert';

import 'package:dart_ui/src/backends/macos/host_protocol.dart';
import 'package:test/test.dart';

final class _RecordingSink with HostMessageSinkAdapter {
  final List<String> events = <String>[];

  @override
  void onHandshake(HostHandshakeField field, int value) {
    events.add('handshake:${field.name}:$value');
  }

  @override
  void onProtocolFeatures(String features) => events.add('features:$features');

  @override
  void onWindowEvent(
    HostWindowEventKind kind,
    double a,
    double b,
    double c,
    double d,
  ) {
    events.add('window:${kind.name}:$a:$b:$c:$d');
  }

  @override
  void onInput(
    HostInputKind kind,
    double x,
    double y,
    int keyCode,
    int machTime,
  ) {
    events.add('input:${kind.name}:$x:$y:$keyCode:$machTime');
  }

  @override
  void onAck(HostAckKind kind, int value) =>
      events.add('ack:${kind.name}:$value');

  @override
  void onSurfacePortAttached(HostSurfaceMechanism mechanism, int slot) {
    events.add('port:${mechanism.name}:$slot');
  }

  @override
  void onPresented(int sequence, int slot, HostPresentTransport transport) {
    events.add('present:$sequence:$slot:${transport.name}');
  }

  @override
  void onError(String code) => events.add('error:$code');

  @override
  void onUnrecognised(String line) => events.add('unknown:$line');
}

void main() {
  test('handshake survives arbitrary chunk boundaries and CRLF', () {
    final sink = _RecordingSink();
    final parser = HostProtocolParser(sink, initialCapacity: 2);
    final bytes = utf8.encode(
      'MAIN_THREAD=1\r\nWINDOW_ID=42\nPROTOCOL=4\n'
      'HOST_PID=123\nWINDOW_SCALE=2000\n'
      'PROTOCOL_FEATURES=surface-port,window-events\n',
    );

    for (final byte in bytes) {
      parser.addBytes(<int>[byte]);
    }

    expect(sink.events, <String>[
      'handshake:mainThread:1',
      'handshake:windowNumber:42',
      'handshake:protocolVersion:4',
      'handshake:hostPid:123',
      'handshake:renderScaleMilli:2000',
      'features:surface-port,window-events',
    ]);
  });

  test('window and input messages preserve signed and fractional fields', () {
    final sink = _RecordingSink();
    final parser = HostProtocolParser(sink);

    parser.addBytes(utf8.encode(
      'WINDOW=RESIZED:640.5:480.25:2.0\n'
      'WINDOW=MOVED:-17.5:22.25\n'
      'WINDOW=CLOSE_REQUESTED\n'
      'INPUT=pointerMove:-3.5:8.25:0:987654\n',
    ));

    expect(sink.events, <String>[
      'window:resized:640.5:480.25:2.0:0.0',
      'window:moved:-17.5:22.25:0.0:0.0',
      'window:closeRequested:0.0:0.0:0.0:0.0',
      'input:pointerMove:-3.5:8.25:0:987654',
    ]);
  });

  test('surface rendezvous and slot presentation remain paired', () {
    final sink = _RecordingSink();
    final parser = HostProtocolParser(sink);

    parser.addBytes(utf8.encode(
      'SURFACE_POOL_OK 2\n'
      'PORT_SERVER_OK dart-ui.macos.r.123.0\n'
      'SURFACE_PORT_OK rendezvous 640x480 slot1\n'
      'PRESENT_OK 9 slot1\n'
      'TEARDOWN=PASS\n',
    ));

    expect(sink.events, <String>[
      'ack:surfacePoolAllocated:2',
      'ack:portServer:21',
      'port:rendezvous:1',
      'present:9:1:surfaceSlot',
      'ack:teardown:0',
    ]);
  });

  test('oversized and malformed lines report errors then recover', () {
    final sink = _RecordingSink();
    final parser = HostProtocolParser(sink, initialCapacity: 2);

    parser.addBytes(<int>[
      ...List<int>.filled(kMacosHostMaxLineBytes + 1, 0x58),
      0x0A,
      ...utf8.encode('INPUT=not-a-kind:0:0:0:0\nPONG\n'),
    ]);

    expect(sink.events, <String>[
      'error:LINE_OVERFLOW',
      'error:BAD_INPUT_KIND',
      'ack:pong:0',
    ]);
  });

  test('commands encode the production protocol exactly', () {
    expect(HostCommands.ping(), 'PING\n');
    expect(HostCommands.surfacePool(2), 'SURFACE_POOL 2\n');
    expect(
      HostCommands.portServer('dart-ui.macos.r.123.4'),
      'PORT_SERVER dart-ui.macos.r.123.4\n',
    );
    expect(
      HostCommands.surfacePortRendezvous(1),
      'SURFACE_PORT RENDEZVOUS 1\n',
    );
    expect(HostCommands.presentSlot(7, 1), 'PRESENT_SLOT 7 1\n');
    expect(HostCommands.setBounds(-1.5, 2, 640, 480),
        'SET_BOUNDS -1.5000 2.0000 640.0000 480.0000\n');
    expect(HostCommands.close(), 'CLOSE\n');
  });
}
