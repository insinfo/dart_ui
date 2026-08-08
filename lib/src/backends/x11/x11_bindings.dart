/// The libxcb entry points this backend calls.
///
/// XCB rather than Xlib, per roadmap section 15.1: the protocol is explicit,
/// the request/reply split is visible in the signature (so a round trip cannot
/// be introduced by accident), and there is no hidden per-display state to
/// reason about. Xlib appears nowhere in this backend and is only *detected*
/// by the probe, because a future XIM implementation would need it - XIM has
/// no XCB equivalent.
///
/// Every symbol is verified with `providesSymbol` before any of them is bound.
/// A partially bound library is worse than an unbound one: it works until the
/// first call into the missing half, by which time a window is on screen and
/// the failure looks like a rendering bug rather than a packaging one.
///
/// The typedefs are named `...N` for the native signature and `...D` for the
/// Dart one. Terse on purpose: they appear twice in every binding, and longer
/// names buy nothing that the field name next to them does not already say.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';

/// `xcb_screen_t`, as far as the setup reply exposes it.
final class XcbScreen extends Struct {
  @Uint32()
  external int root;
  @Uint32()
  external int defaultColormap;
  @Uint32()
  external int whitePixel;
  @Uint32()
  external int blackPixel;
  @Uint32()
  external int currentInputMasks;
  @Uint16()
  external int widthInPixels;
  @Uint16()
  external int heightInPixels;
  @Uint16()
  external int widthInMillimeters;
  @Uint16()
  external int heightInMillimeters;
  @Uint16()
  external int minInstalledMaps;
  @Uint16()
  external int maxInstalledMaps;
  @Uint32()
  external int rootVisual;
  @Uint8()
  external int backingStores;
  @Uint8()
  external int saveUnders;
  @Uint8()
  external int rootDepth;
  @Uint8()
  external int allowedDepthsLen;
}

final class XcbScreenIterator extends Struct {
  external Pointer<XcbScreen> data;
  @Int32()
  external int rem;
  @Int32()
  external int index;
}

/// Every XCB cookie is one sequence number, and they are ABI-identical.
///
/// One Dart type for all of them rather than a dozen indistinguishable copies.
/// The C types differ only so that a C compiler can stop you handing an
/// InternAtom cookie to GetProperty's reply function, and Dart cannot express
/// that distinction once both are erased to a struct of one `uint32`.
final class XcbCookie extends Struct {
  @Uint32()
  external int sequence;
}

typedef XcbConnectN = Pointer<Void> Function(Pointer<Uint8>, Pointer<Int32>);
typedef XcbConnectD = Pointer<Void> Function(Pointer<Uint8>, Pointer<Int32>);
typedef XcbVoidCN = Void Function(Pointer<Void>);
typedef XcbVoidCD = void Function(Pointer<Void>);
typedef XcbIntCN = Int32 Function(Pointer<Void>);
typedef XcbIntCD = int Function(Pointer<Void>);
typedef XcbU32CN = Uint32 Function(Pointer<Void>);
typedef XcbU32CD = int Function(Pointer<Void>);
typedef XcbPtrCN = Pointer<Void> Function(Pointer<Void>);
typedef XcbPtrCD = Pointer<Void> Function(Pointer<Void>);
typedef XcbEvtCN = Pointer<Uint8> Function(Pointer<Void>);
typedef XcbEvtCD = Pointer<Uint8> Function(Pointer<Void>);
typedef XcbIterN = XcbScreenIterator Function(Pointer<Void>);
typedef XcbIterD = XcbScreenIterator Function(Pointer<Void>);
typedef XcbWinN = Void Function(Pointer<Void>, Uint32);
typedef XcbWinD = void Function(Pointer<Void>, int);
typedef XcbReplyN = Pointer<Uint8> Function(
    Pointer<Void>, XcbCookie, Pointer<Pointer<Uint8>>);
typedef XcbReplyD = Pointer<Uint8> Function(
    Pointer<Void>, XcbCookie, Pointer<Pointer<Uint8>>);
typedef XcbReqChkN = Pointer<Uint8> Function(Pointer<Void>, XcbCookie);
typedef XcbReqChkD = Pointer<Uint8> Function(Pointer<Void>, XcbCookie);
typedef XcbCrtWinN = Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Int16,
    Int16, Uint16, Uint16, Uint16, Uint16, Uint32, Uint32, Pointer<Uint32>);
typedef XcbCrtWinD = void Function(Pointer<Void>, int, int, int, int, int, int,
    int, int, int, int, int, Pointer<Uint32>);
typedef XcbCwaN = Void Function(Pointer<Void>, Uint32, Uint32, Pointer<Uint32>);
typedef XcbCwaD = void Function(Pointer<Void>, int, int, Pointer<Uint32>);
typedef XcbCfgWinN = Void Function(
    Pointer<Void>, Uint32, Uint16, Pointer<Uint32>);
typedef XcbCfgWinD = void Function(Pointer<Void>, int, int, Pointer<Uint32>);
typedef XcbInternN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint16, Pointer<Uint8>);
typedef XcbInternD = XcbCookie Function(
    Pointer<Void>, int, int, Pointer<Uint8>);
typedef XcbChgPropN = Void Function(Pointer<Void>, Uint8, Uint32, Uint32,
    Uint32, Uint8, Uint32, Pointer<Uint8>);
typedef XcbChgPropD = void Function(
    Pointer<Void>, int, int, int, int, int, int, Pointer<Uint8>);
typedef XcbGetPropN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint32, Uint32, Uint32, Uint32, Uint32);
typedef XcbGetPropD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int, int);
typedef XcbPValN = Pointer<Uint8> Function(Pointer<Uint8>);
typedef XcbPValD = Pointer<Uint8> Function(Pointer<Uint8>);
typedef XcbPLnN = Int32 Function(Pointer<Uint8>);
typedef XcbPLnD = int Function(Pointer<Uint8>);
typedef XcbSendEvtN = Void Function(
    Pointer<Void>, Uint8, Uint32, Uint32, Pointer<Uint8>);
typedef XcbSendEvtD = void Function(
    Pointer<Void>, int, int, int, Pointer<Uint8>);
typedef XcbCrtGcN = Void Function(
    Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Uint32>);
typedef XcbCrtGcD = void Function(
    Pointer<Void>, int, int, int, Pointer<Uint32>);
typedef XcbPutImgN = Void Function(Pointer<Void>, Uint8, Uint32, Uint32, Uint16,
    Uint16, Int16, Int16, Uint8, Uint8, Uint32, Pointer<Uint8>);
typedef XcbPutImgD = void Function(Pointer<Void>, int, int, int, int, int, int,
    int, int, int, int, Pointer<Uint8>);
typedef XcbClearN = Void Function(
    Pointer<Void>, Uint8, Uint32, Int16, Int16, Uint16, Uint16);
typedef XcbClearD = void Function(Pointer<Void>, int, int, int, int, int, int);
typedef XcbQryExtN = XcbCookie Function(Pointer<Void>, Uint16, Pointer<Uint8>);
typedef XcbQryExtD = XcbCookie Function(Pointer<Void>, int, Pointer<Uint8>);
typedef XcbXlateN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Int16, Int16);
typedef XcbXlateD = XcbCookie Function(Pointer<Void>, int, int, int, int);
typedef XcbGeomN = XcbCookie Function(Pointer<Void>, Uint32);
typedef XcbGeomD = XcbCookie Function(Pointer<Void>, int);
typedef XcbOpenFontN = Void Function(
    Pointer<Void>, Uint32, Uint16, Pointer<Uint8>);
typedef XcbOpenFontD = void Function(Pointer<Void>, int, int, Pointer<Uint8>);
typedef XcbGlyphN = Void Function(Pointer<Void>, Uint32, Uint32, Uint32, Uint16,
    Uint16, Uint16, Uint16, Uint16, Uint16, Uint16, Uint16);
typedef XcbGlyphD = void Function(
    Pointer<Void>, int, int, int, int, int, int, int, int, int, int, int);
typedef XcbFocusN = Void Function(Pointer<Void>, Uint8, Uint32, Uint32);
typedef XcbFocusD = void Function(Pointer<Void>, int, int, int);

/// Bound libxcb. Constructed only after every symbol has been verified.
final class XcbBindings {
  XcbBindings._(this.library, this.libraryName);

  /// Loads libxcb, or returns null after appending a named diagnostic.
  ///
  /// The soname is tried before the development symlink: `libxcb.so` exists
  /// only when the `-dev` package is installed, and requiring it would make
  /// the framework refuse to start on every machine that merely runs X rather
  /// than builds against it.
  static XcbBindings? load(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    var name = '';
    for (final candidate in const <String>['libxcb.so.1', 'libxcb.so']) {
      try {
        library = DynamicLibrary.open(candidate);
        name = candidate;
        break;
      } on Object catch (error) {
        diagnostics.add(
          BackendDiagnostic.missingLibrary(candidate, detail: '$error'),
        );
      }
    }
    if (library == null) return null;

    var complete = true;
    for (final symbol in requiredSymbols) {
      if (!library.providesSymbol(symbol)) {
        complete = false;
        diagnostics.add(BackendDiagnostic.missingSymbol(symbol, detail: name));
      }
    }
    if (!complete) return null;
    diagnostics.add(BackendDiagnostic.note('loaded $name'));
    return XcbBindings._(library, name);
  }

  /// The full list, checked up front, ordered as the protocol document orders
  /// the requests so that adding one has an obvious place to go.
  static const List<String> requiredSymbols = <String>[
    'xcb_connect',
    'xcb_disconnect',
    'xcb_connection_has_error',
    'xcb_get_setup',
    'xcb_setup_roots_iterator',
    'xcb_generate_id',
    'xcb_get_file_descriptor',
    'xcb_get_maximum_request_length',
    'xcb_flush',
    'xcb_poll_for_event',
    'xcb_poll_for_queued_event',
    'xcb_request_check',
    'xcb_create_window',
    'xcb_destroy_window',
    'xcb_map_window',
    'xcb_unmap_window',
    'xcb_change_window_attributes',
    'xcb_configure_window',
    'xcb_intern_atom',
    'xcb_intern_atom_reply',
    'xcb_change_property',
    'xcb_get_property',
    'xcb_get_property_reply',
    'xcb_get_property_value',
    'xcb_get_property_value_length',
    'xcb_send_event',
    'xcb_create_gc',
    'xcb_free_gc',
    'xcb_put_image',
    'xcb_clear_area',
    'xcb_query_extension',
    'xcb_query_extension_reply',
    'xcb_translate_coordinates',
    'xcb_translate_coordinates_reply',
    'xcb_get_geometry',
    'xcb_get_geometry_reply',
    'xcb_open_font',
    'xcb_close_font',
    'xcb_create_glyph_cursor',
    'xcb_free_cursor',
    'xcb_set_input_focus',
  ];

  final DynamicLibrary library;

  /// Which soname actually loaded, so the probe report can name it.
  final String libraryName;

  XcbIntCD _int(String symbol) =>
      library.lookupFunction<XcbIntCN, XcbIntCD>(symbol);

  XcbU32CD _u32(String symbol) =>
      library.lookupFunction<XcbU32CN, XcbU32CD>(symbol);

  XcbEvtCD _evt(String symbol) =>
      library.lookupFunction<XcbEvtCN, XcbEvtCD>(symbol);

  XcbWinD _win(String symbol) =>
      library.lookupFunction<XcbWinN, XcbWinD>(symbol);

  XcbReplyD _reply(String symbol) =>
      library.lookupFunction<XcbReplyN, XcbReplyD>(symbol);

  late final XcbConnectD connect =
      library.lookupFunction<XcbConnectN, XcbConnectD>('xcb_connect');
  late final XcbVoidCD disconnect =
      library.lookupFunction<XcbVoidCN, XcbVoidCD>('xcb_disconnect');
  late final XcbPtrCD getSetup =
      library.lookupFunction<XcbPtrCN, XcbPtrCD>('xcb_get_setup');
  late final XcbIterD setupRootsIterator =
      library.lookupFunction<XcbIterN, XcbIterD>('xcb_setup_roots_iterator');
  late final XcbReqChkD requestCheck =
      library.lookupFunction<XcbReqChkN, XcbReqChkD>('xcb_request_check');
  late final XcbCrtWinD createWindow =
      library.lookupFunction<XcbCrtWinN, XcbCrtWinD>('xcb_create_window');
  late final XcbCwaD changeWindowAttributes =
      library.lookupFunction<XcbCwaN, XcbCwaD>('xcb_change_window_attributes');
  late final XcbCfgWinD configureWindow =
      library.lookupFunction<XcbCfgWinN, XcbCfgWinD>('xcb_configure_window');
  late final XcbInternD internAtom =
      library.lookupFunction<XcbInternN, XcbInternD>('xcb_intern_atom');
  late final XcbChgPropD changeProperty =
      library.lookupFunction<XcbChgPropN, XcbChgPropD>('xcb_change_property');
  late final XcbGetPropD getProperty =
      library.lookupFunction<XcbGetPropN, XcbGetPropD>('xcb_get_property');
  late final XcbPValD getPropertyValue =
      library.lookupFunction<XcbPValN, XcbPValD>('xcb_get_property_value');
  late final XcbPLnD getPropertyValueLength =
      library.lookupFunction<XcbPLnN, XcbPLnD>('xcb_get_property_value_length');
  late final XcbSendEvtD sendEvent =
      library.lookupFunction<XcbSendEvtN, XcbSendEvtD>('xcb_send_event');
  late final XcbCrtGcD createGc =
      library.lookupFunction<XcbCrtGcN, XcbCrtGcD>('xcb_create_gc');
  late final XcbPutImgD putImage =
      library.lookupFunction<XcbPutImgN, XcbPutImgD>('xcb_put_image');
  late final XcbClearD clearArea =
      library.lookupFunction<XcbClearN, XcbClearD>('xcb_clear_area');
  late final XcbQryExtD queryExtension =
      library.lookupFunction<XcbQryExtN, XcbQryExtD>('xcb_query_extension');
  late final XcbXlateD translateCoordinates =
      library.lookupFunction<XcbXlateN, XcbXlateD>('xcb_translate_coordinates');
  late final XcbGeomD getGeometry =
      library.lookupFunction<XcbGeomN, XcbGeomD>('xcb_get_geometry');
  late final XcbOpenFontD openFont =
      library.lookupFunction<XcbOpenFontN, XcbOpenFontD>('xcb_open_font');
  late final XcbGlyphD createGlyphCursor =
      library.lookupFunction<XcbGlyphN, XcbGlyphD>('xcb_create_glyph_cursor');
  late final XcbFocusD setInputFocus =
      library.lookupFunction<XcbFocusN, XcbFocusD>('xcb_set_input_focus');

  late final XcbIntCD connectionHasError = _int('xcb_connection_has_error');
  late final XcbIntCD getFileDescriptor = _int('xcb_get_file_descriptor');
  late final XcbIntCD flush = _int('xcb_flush');
  late final XcbU32CD generateId = _u32('xcb_generate_id');
  late final XcbU32CD maximumRequestLength =
      _u32('xcb_get_maximum_request_length');
  late final XcbEvtCD pollForEvent = _evt('xcb_poll_for_event');
  late final XcbEvtCD pollForQueuedEvent = _evt('xcb_poll_for_queued_event');
  late final XcbWinD destroyWindow = _win('xcb_destroy_window');
  late final XcbWinD mapWindow = _win('xcb_map_window');
  late final XcbWinD unmapWindow = _win('xcb_unmap_window');
  late final XcbWinD freeGc = _win('xcb_free_gc');
  late final XcbWinD closeFont = _win('xcb_close_font');
  late final XcbWinD freeCursor = _win('xcb_free_cursor');
  late final XcbReplyD internAtomReply = _reply('xcb_intern_atom_reply');
  late final XcbReplyD getPropertyReply = _reply('xcb_get_property_reply');
  late final XcbReplyD queryExtensionReply =
      _reply('xcb_query_extension_reply');
  late final XcbReplyD translateCoordinatesReply =
      _reply('xcb_translate_coordinates_reply');
  late final XcbReplyD getGeometryReply = _reply('xcb_get_geometry_reply');
}

typedef XcbShmAtN = XcbCookie Function(Pointer<Void>, Uint32, Uint32, Uint8);
typedef XcbShmAtD = XcbCookie Function(Pointer<Void>, int, int, int);
typedef XcbShmDetN = XcbCookie Function(Pointer<Void>, Uint32);
typedef XcbShmDetD = XcbCookie Function(Pointer<Void>, int);
typedef XcbShmImgN = XcbCookie Function(
    Pointer<Void>,
    Uint32,
    Uint32,
    Uint16,
    Uint16,
    Uint16,
    Uint16,
    Uint16,
    Uint16,
    Int16,
    Int16,
    Uint8,
    Uint8,
    Uint8,
    Uint32,
    Uint32);
typedef XcbShmImgD = XcbCookie Function(Pointer<Void>, int, int, int, int, int,
    int, int, int, int, int, int, int, int, int, int);

/// libxcb-shm, loaded only when the MIT-SHM extension is actually present.
///
/// Separate from [XcbBindings] because it is genuinely optional. A remote
/// display has no shared memory to attach, and refusing to start there would
/// be a worse answer than presenting a little more slowly.
final class XcbShmBindings {
  XcbShmBindings._(this.library, this.libraryName);

  static const List<String> requiredSymbols = <String>[
    'xcb_shm_attach_checked',
    'xcb_shm_detach',
    'xcb_shm_put_image',
  ];

  static XcbShmBindings? load(List<BackendDiagnostic> diagnostics) {
    DynamicLibrary? library;
    var name = '';
    const candidates = <String>['libxcb-shm.so.0', 'libxcb-shm.so'];
    for (final candidate in candidates) {
      try {
        library = DynamicLibrary.open(candidate);
        name = candidate;
        break;
      } on Object catch (_) {
        // Not reported per candidate. A machine without the shm binding is
        // the ordinary remote-display case, and one diagnostic naming the
        // fallback is more useful than two naming sonames.
        continue;
      }
    }
    if (library == null) {
      diagnostics.add(
        const BackendDiagnostic.missingLibrary(
          'libxcb-shm.so.0',
          detail: 'MIT-SHM present path unavailable; PutImage will be used',
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
    return XcbShmBindings._(library, name);
  }

  final DynamicLibrary library;
  final String libraryName;

  late final XcbShmAtD attachChecked =
      library.lookupFunction<XcbShmAtN, XcbShmAtD>('xcb_shm_attach_checked');
  late final XcbShmDetD detach =
      library.lookupFunction<XcbShmDetN, XcbShmDetD>('xcb_shm_detach');
  late final XcbShmImgD putImage =
      library.lookupFunction<XcbShmImgN, XcbShmImgD>('xcb_shm_put_image');
}
