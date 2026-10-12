/// Per-monitor geometry from RandR 1.5's `RRGetMonitors`.
///
/// One request, one reply: the monitors the server considers logical
/// monitors, each with its rectangle in root-window pixels, its physical size
/// and whether it is primary. The older route - `RRGetScreenResources`, then
/// `RRGetCrtcInfo` per CRTC, then `RRGetOutputInfo` per output - is three
/// chained round trips and a reconciliation of CRTCs against outputs, and it
/// is what `x11_scale.dart` gave as the reason this was deferred.
///
/// `RRGetMonitors` also knows about monitors no CRTC describes: `xrandr
/// --setmonitor` splits one wide output into two logical monitors, which is
/// exactly how the CI proves a two-monitor layout on a single Xvfb screen.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../foundation/diagnostics.dart';
import 'x11_bindings.dart';

typedef XcbRandrGetMonitorsN = XcbCookie Function(Pointer<Void>, Uint32, Uint8);
typedef XcbRandrGetMonitorsD = XcbCookie Function(Pointer<Void>, int, int);

/// libxcb-randr, loaded only when the server advertises RANDR.
final class XcbRandrBindings {
  XcbRandrBindings._(this.library, this.libraryName);

  static const List<String> requiredSymbols = <String>[
    'xcb_randr_get_monitors',
    'xcb_randr_get_monitors_reply',
  ];

  static XcbRandrBindings? load(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    var name = '';
    for (final candidate in const <String>[
      'libxcb-randr.so.0',
      'libxcb-randr.so',
    ]) {
      try {
        library = DynamicLibrary.open(candidate);
        name = candidate;
        break;
      } on Object catch (_) {
        continue;
      }
    }
    if (library == null) {
      diagnostics.add(
        const BackendDiagnostic.missingLibrary(
          'libxcb-randr.so.0',
          detail: 'per-monitor geometry unavailable; the root screen is used',
        ),
      );
      return null;
    }
    for (final symbol in requiredSymbols) {
      if (!library.providesSymbol(symbol)) {
        diagnostics.add(BackendDiagnostic.missingSymbol(symbol, detail: name));
        return null;
      }
    }
    return XcbRandrBindings._(library, name);
  }

  final DynamicLibrary library;
  final String libraryName;

  late final XcbRandrGetMonitorsD getMonitors =
      library.lookupFunction<XcbRandrGetMonitorsN, XcbRandrGetMonitorsD>(
          'xcb_randr_get_monitors');
  late final XcbReplyD getMonitorsReply = library
      .lookupFunction<XcbReplyN, XcbReplyD>('xcb_randr_get_monitors_reply');
}

/// One RandR logical monitor, in root-window pixels.
final class X11Monitor {
  const X11Monitor({
    required this.nameAtom,
    required this.primary,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.widthInMillimetres,
    required this.heightInMillimetres,
  });

  final int nameAtom;
  final bool primary;
  final int x;
  final int y;
  final int width;
  final int height;
  final int widthInMillimetres;
  final int heightInMillimetres;

  @override
  String toString() => 'X11Monitor(${width}x$height+$x+$y'
      '${primary ? ', primary' : ''})';
}

/// Decodes an `xcb_randr_get_monitors_reply_t` held in [reply].
///
/// The layout: a 32-byte header whose `nMonitors` is at byte 12, then each
/// `xcb_randr_monitor_info_t` - name atom (4), primary (1), automatic (1),
/// output count (2), x and y (int16 each), width and height (uint16 each),
/// physical width and height in millimetres (uint32 each) - followed by its
/// output ids, four bytes apiece. A reply shorter than it claims stops the
/// walk at the last whole monitor instead of reading past the end.
List<X11Monitor> decodeRandrMonitors(Uint8List reply) {
  if (reply.length < 32) return const <X11Monitor>[];
  final ByteData data = ByteData.sublistView(reply);
  final int count = data.getUint32(12, Endian.host);
  final List<X11Monitor> monitors = <X11Monitor>[];
  var offset = 32;
  for (var index = 0; index < count; index++) {
    if (offset + 24 > reply.length) break;
    final int outputs = data.getUint16(offset + 6, Endian.host);
    monitors.add(X11Monitor(
      nameAtom: data.getUint32(offset, Endian.host),
      primary: data.getUint8(offset + 4) != 0,
      x: data.getInt16(offset + 8, Endian.host),
      y: data.getInt16(offset + 10, Endian.host),
      width: data.getUint16(offset + 12, Endian.host),
      height: data.getUint16(offset + 14, Endian.host),
      widthInMillimetres: data.getUint32(offset + 16, Endian.host),
      heightInMillimetres: data.getUint32(offset + 20, Endian.host),
    ));
    offset += 24 + outputs * 4;
  }
  return monitors;
}
