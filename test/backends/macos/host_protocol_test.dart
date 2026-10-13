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
  void onTitleBar(double x, double y, double width, double height,
          double titleBarHeight) =>
      events.add('titlebar:$x:$y:$width:$height:$titleBarHeight');

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
  void onVsync(int sequence) => events.add('vsync:$sequence');

  @override
  void onInputDetail(HostInputDetail detail) => events.add(
      'detail:${detail.kind.name}:${detail.button}:${detail.modifierFlags}:'
      '${detail.clickCount}:${detail.deltaX}:${detail.deltaY}:'
      '${detail.hasPreciseScrollingDeltas}:${detail.isRepeat}:${detail.keyChar}');

  @override
  void onTextInput(String base64) => events.add('text:$base64');

  @override
  void onClipboardData(int request, String base64) =>
      events.add('clipboard-data:$request:$base64');

  @override
  void onClipboardResult(int request, HostClipboardResult result) =>
      events.add('clipboard:$request:${result.name}');

  @override
  void onMenuAction(int generation, int id) =>
      events.add('menu:$generation:$id');

  @override
  void onSystemSettings(bool dark, bool highContrast, bool reduceMotion) =>
      events.add('settings:$dark:$highContrast:$reduceMotion');

  @override
  void onError(String code) => events.add('error:$code');

  @override
  void onUnrecognised(String line) => events.add('unknown:$line');
}

void main() {
  test('a hidden title bar reports where the window buttons are', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(
        utf8.encode('WINDOW=TITLEBAR:7.0000:6.0000:54.0000:16.0000:28.0000\n'
            'WINDOW=TITLEBAR:0:0:0:0:0\n'
            'WINDOW=TITLEBAR:7:6\n'));
    expect(sink.events, <String>[
      'titlebar:7.0:6.0:54.0:16.0:28.0',
      'titlebar:0.0:0.0:0.0:0.0:0.0',
      'error:BAD_WINDOW_TITLEBAR',
    ]);
  });

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

  test('a refresh after a paced present is its own message', () {
    // Dispatched on 'V', next to VIEW_INPUT=: the first version of this
    // parser looked for it under 'P' and never saw one, so every paced frame
    // sat out the full timeout.
    final sink = _RecordingSink();
    final parser = HostProtocolParser(sink);
    parser.addBytes(utf8.encode('PRESENT_OK 9 slot1\nVSYNC 9\nVSYNC x\n'));
    expect(sink.events, <String>[
      'present:9:1:surfaceSlot',
      'vsync:9',
      'error:BAD_VSYNC',
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
    expect(HostCommands.presentSlot(7, 1, vsync: true),
        'PRESENT_SLOT 7 1 vsync\n');
    expect(HostCommands.setBounds(-1.5, 2, 640, 480),
        'SET_BOUNDS -1.5000 2.0000 640.0000 480.0000\n');
    expect(HostCommands.close(), 'CLOSE\n');
  });

  test('clipboard pieces arrive in order, then the result that ends them', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'CLIPBOARD_DATA=8:b2zDoQpt\n'
      'CLIPBOARD_DATA=8:dW5kbw==\n'
      'CLIPBOARD=8:TEXT\n'
      'CLIPBOARD=9:NONE\n'
      'CLIPBOARD=10:WRITTEN\n'
      'CLIPBOARD=11:FAILED\n',
    ));

    expect(sink.events, <String>[
      'clipboard-data:8:b2zDoQpt',
      'clipboard-data:8:dW5kbw==',
      'clipboard:8:text',
      'clipboard:9:none',
      'clipboard:10:written',
      'clipboard:11:failed',
    ]);
  });

  test('a typed clipboard read ends with DATA, and the commands name the type',
      () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'CLIPBOARD_DATA=12:text,image\n'
      'CLIPBOARD=12:DATA\n',
    ));

    expect(sink.events, <String>[
      'clipboard-data:12:text,image',
      'clipboard:12:data',
    ]);
    expect(HostCommands.clipboardReadType(12, 'formats'),
        'CLIPBOARD_READ_TYPE 12 formats\n');
    expect(HostCommands.clipboardWriteType(13, 'png'),
        'CLIPBOARD_WRITE_TYPE 13 png\n');
  });

  test('a menu choice carries the generation it was installed under', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'MENU=ACTION:3:17\n'
      'MENU=ACTION:3\n'
      'MENU=ACTION:x:1\n',
    ));

    expect(sink.events, <String>[
      'menu:3:17',
      'error:BAD_MENU_ACTION',
      'error:BAD_MENU_ACTION',
    ]);
    expect(HostCommands.menuSet(4), 'MENU_SET 4\n');
    expect(HostCommands.menuAppend('e30='), 'MENU_APPEND e30=\n');
  });

  test('an empty piece is a piece, not a malformed line', () {
    // The empty string is text too; the host never sends an empty piece for
    // it, but a parser that refused one would turn a legal line into an error.
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode('CLIPBOARD_DATA=3:\n'));
    expect(sink.events, <String>['clipboard-data:3:']);
  });

  test('a clipboard line without a request or a known result is an error', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'CLIPBOARD=:TEXT\n'
      'CLIPBOARD=4\n'
      'CLIPBOARD=4:MAYBE\n'
      'CLIPBOARD_DATA=x:abc\n'
      'CLIPBOARD_DATA=5abc\n',
    ));
    expect(sink.events, <String>[
      'error:BAD_CLIPBOARD_RESULT',
      'error:BAD_CLIPBOARD_RESULT',
      'error:BAD_CLIPBOARD_RESULT',
      'error:BAD_CLIPBOARD_DATA',
      'error:BAD_CLIPBOARD_DATA',
    ]);
  });

  test('clipboard commands, and a full piece fits under the line cap', () {
    expect(HostCommands.clipboardRead(8), 'CLIPBOARD_READ 8\n');
    expect(
        HostCommands.clipboardAppend(8, 'b2zD'), 'CLIPBOARD_APPEND 8 b2zD\n');
    expect(HostCommands.clipboardWrite(8), 'CLIPBOARD_WRITE 8\n');
    expect(kMacosHostClipboardChunk % 4, 0,
        reason: 'every piece has to decode on its own boundary');
    // The longest request number a session can produce, beside a full piece.
    final String longest = HostCommands.clipboardAppend(
        0x7fffffffffffffff, 'A' * kMacosHostClipboardChunk);
    expect(utf8.encode(longest).length, lessThan(kMacosHostMaxLineBytes));
  });

  test('an input line from a current host carries its detail after the five',
      () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'INPUT=pointerDown:20.0000:30.0000:0:99:1:131072:2:0.0000:0.0000:0:0\n'
      'INPUT=scroll:1.0000:2.0000:0:100:-1:0:0:-1.5000:25.0000:1:0\n'
      'INPUT=keyDown:0.0000:0.0000:8:101:-1:1048576:0:0.0000:0.0000:2:99\n'
      'TEXT_INPUT=w6c=\n',
    ));
    expect(sink.events, <String>[
      'input:pointerDown:20.0:30.0:0:99',
      'detail:pointerDown:1:131072:2:0.0:0.0:false:false:0',
      'input:scroll:1.0:2.0:0:100',
      'detail:scroll:-1:0:0:-1.5:25.0:true:false:0',
      'input:keyDown:0.0:0.0:8:101',
      'detail:keyDown:-1:1048576:0:0.0:0.0:false:true:99',
      'text:w6c=',
    ]);
  });

  test('a protocol 2 input line is still input, with no detail', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink)
        .addBytes(utf8.encode('INPUT=pointerUp:1.0000:2.0000:0:7\n'));
    expect(sink.events, <String>['input:pointerUp:1.0:2.0:0:7']);
  });

  test('a line that stops partway through the detail is an error', () {
    // Inventing the missing fields would put a guessed button or modifier
    // into input.
    final sink = _RecordingSink();
    HostProtocolParser(sink)
        .addBytes(utf8.encode('INPUT=pointerUp:1.0000:2.0000:0:7:0:0\n'));
    expect(sink.events, <String>[
      'input:pointerUp:1.0:2.0:0:7',
      'error:BAD_INPUT_DETAIL',
    ]);
  });

  test('the pointer crossing the view edge is a window event', () {
    final sink = _RecordingSink();
    HostProtocolParser(sink).addBytes(utf8.encode(
      'WINDOW=POINTER_ENTER\nWINDOW=POINTER_LEAVE\n',
    ));
    expect(sink.events, <String>[
      'window:pointerEntered:0.0:0.0:0.0:0.0',
      'window:pointerLeft:0.0:0.0:0.0:0.0',
    ]);
  });

  group('SYSTEM_SETTINGS', () {
    test('carries dark, increase contrast and reduce motion as 0 or 1', () {
      final sink = _RecordingSink();
      HostProtocolParser(sink).addBytes(utf8.encode(
        'SYSTEM_SETTINGS=0:0:0\n'
        'SYSTEM_SETTINGS=1:0:0\n'
        'SYSTEM_SETTINGS=0:1:0\n'
        'SYSTEM_SETTINGS=0:0:1\n'
        'SYSTEM_SETTINGS=1:1:1\r\n',
      ));
      expect(sink.events, <String>[
        'settings:false:false:false',
        'settings:true:false:false',
        'settings:false:true:false',
        'settings:false:false:true',
        'settings:true:true:true',
      ]);
    });

    test('arrives in the banner, before the line that completes it', () {
      // The order the host writes: the startup values ride the handshake so
      // that the first answer and every later one share one parser.
      final sink = _RecordingSink();
      HostProtocolParser(sink).addBytes(utf8.encode(
        'MAIN_THREAD=1\nWINDOW_ID=42\nPROTOCOL=4\nWINDOW_SCALE=2000\n'
        'PROTOCOL_FEATURES=surface-port,window-events,clipboard,vsync,'
        'system-settings\n'
        'SYSTEM_SETTINGS=1:0:1\n'
        'HOST_PID=123\n',
      ));
      expect(
        sink.events.sublist(sink.events.length - 2),
        <String>['settings:true:false:true', 'handshake:hostPid:123'],
      );
    });

    test('ignores fields a newer host appends', () {
      final sink = _RecordingSink();
      HostProtocolParser(sink)
          .addBytes(utf8.encode('SYSTEM_SETTINGS=1:0:1:1:0\n'));
      expect(sink.events, <String>['settings:true:false:true']);
    });

    test('a value that is not 0 or 1, or a missing field, is an error', () {
      final sink = _RecordingSink();
      HostProtocolParser(sink).addBytes(utf8.encode(
        'SYSTEM_SETTINGS=2:0:0\n'
        'SYSTEM_SETTINGS=1:0\n'
        'SYSTEM_SETTINGS=\n'
        'SYSTEM_SETTINGS=1 0 1\n'
        'SYSTEM_SETTINGS=1:0:1x\n'
        'SYSTEM_SETTINGS=-1:0:0\n'
        'SYSTEM_SETTINGS=0:1:0\n',
      ));
      expect(sink.events, <String>[
        for (var i = 0; i < 6; i++) 'error:BAD_SYSTEM_SETTINGS',
        // And the parser recovers for the next line.
        'settings:false:true:false',
      ]);
    });
  });
}
