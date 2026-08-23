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

/// Fixed header of the server setup reply.
///
/// Variable vendor/formats/screens data follows these 40 bytes and must be
/// reached through XCB accessors rather than pointer arithmetic.
final class XcbSetup extends Struct {
  @Uint8()
  external int status;
  @Uint8()
  external int pad0;
  @Uint16()
  external int protocolMajorVersion;
  @Uint16()
  external int protocolMinorVersion;
  @Uint16()
  external int length;
  @Uint32()
  external int releaseNumber;
  @Uint32()
  external int resourceIdBase;
  @Uint32()
  external int resourceIdMask;
  @Uint32()
  external int motionBufferSize;
  @Uint16()
  external int vendorLen;
  @Uint16()
  external int maximumRequestLength;
  @Uint8()
  external int rootsLen;
  @Uint8()
  external int pixmapFormatsLen;
  @Uint8()
  external int imageByteOrder;
  @Uint8()
  external int bitmapFormatBitOrder;
  @Uint8()
  external int bitmapFormatScanlineUnit;
  @Uint8()
  external int bitmapFormatScanlinePad;
  @Uint8()
  external int minKeycode;
  @Uint8()
  external int maxKeycode;
  @Array(4)
  external Array<Uint8> pad1;
}

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

/// One pixmap wire format advertised by the X server setup reply.
///
/// The root depth alone is not enough to select a CPU pixel layout: depth 24
/// is commonly transported as either 24 or 32 bits per pixel.  Reading the
/// server's format keeps the PutImage path honest instead of assuming the
/// layout of the developer machine.
final class XcbFormat extends Struct {
  @Uint8()
  external int depth;
  @Uint8()
  external int bitsPerPixel;
  @Uint8()
  external int scanlinePad;
  @Array(5)
  external Array<Uint8> pad0;
}

final class XcbFormatIterator extends Struct {
  external Pointer<XcbFormat> data;
  @Int32()
  external int rem;
  @Int32()
  external int index;
}

/// Header before the variable-length visual list for one allowed depth.
final class XcbDepth extends Struct {
  @Uint8()
  external int depth;
  @Uint8()
  external int pad0;
  @Uint16()
  external int visualsLen;
  @Array(4)
  external Array<Uint8> pad1;
}

final class XcbDepthIterator extends Struct {
  external Pointer<XcbDepth> data;
  @Int32()
  external int rem;
  @Int32()
  external int index;
}

/// Colour masks and class for one X visual.
final class XcbVisualType extends Struct {
  @Uint32()
  external int visualId;
  @Uint8()
  external int visualClass;
  @Uint8()
  external int bitsPerRgbValue;
  @Uint16()
  external int colormapEntries;
  @Uint32()
  external int redMask;
  @Uint32()
  external int greenMask;
  @Uint32()
  external int blueMask;
  @Array(4)
  external Array<Uint8> pad0;
}

final class XcbVisualTypeIterator extends Struct {
  external Pointer<XcbVisualType> data;
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
typedef XcbFormatIterN = XcbFormatIterator Function(Pointer<Void>);
typedef XcbFormatIterD = XcbFormatIterator Function(Pointer<Void>);
typedef XcbDepthIterN = XcbDepthIterator Function(Pointer<XcbScreen>);
typedef XcbDepthIterD = XcbDepthIterator Function(Pointer<XcbScreen>);
typedef XcbVisualIterN = XcbVisualTypeIterator Function(Pointer<XcbDepth>);
typedef XcbVisualIterD = XcbVisualTypeIterator Function(Pointer<XcbDepth>);
typedef XcbFormatNextN = Void Function(Pointer<XcbFormatIterator>);
typedef XcbFormatNextD = void Function(Pointer<XcbFormatIterator>);
typedef XcbDepthNextN = Void Function(Pointer<XcbDepthIterator>);
typedef XcbDepthNextD = void Function(Pointer<XcbDepthIterator>);
typedef XcbVisualNextN = Void Function(Pointer<XcbVisualTypeIterator>);
typedef XcbVisualNextD = void Function(Pointer<XcbVisualTypeIterator>);
typedef XcbWinN = XcbCookie Function(Pointer<Void>, Uint32);
typedef XcbWinD = XcbCookie Function(Pointer<Void>, int);
typedef XcbReplyN = Pointer<Uint8> Function(
    Pointer<Void>, XcbCookie, Pointer<Pointer<Uint8>>);
typedef XcbReplyD = Pointer<Uint8> Function(
    Pointer<Void>, XcbCookie, Pointer<Pointer<Uint8>>);
typedef XcbReqChkN = Pointer<Uint8> Function(Pointer<Void>, XcbCookie);
typedef XcbReqChkD = Pointer<Uint8> Function(Pointer<Void>, XcbCookie);
typedef XcbCrtWinN = XcbCookie Function(
    Pointer<Void>,
    Uint8,
    Uint32,
    Uint32,
    Int16,
    Int16,
    Uint16,
    Uint16,
    Uint16,
    Uint16,
    Uint32,
    Uint32,
    Pointer<Uint32>);
typedef XcbCrtWinD = XcbCookie Function(Pointer<Void>, int, int, int, int, int,
    int, int, int, int, int, int, Pointer<Uint32>);
typedef XcbCwaN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Pointer<Uint32>);
typedef XcbCwaD = XcbCookie Function(Pointer<Void>, int, int, Pointer<Uint32>);
typedef XcbCfgWinN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint16, Pointer<Uint32>);
typedef XcbCfgWinD = XcbCookie Function(
    Pointer<Void>, int, int, Pointer<Uint32>);
typedef XcbInternN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint16, Pointer<Uint8>);
typedef XcbInternD = XcbCookie Function(
    Pointer<Void>, int, int, Pointer<Uint8>);
typedef XcbChgPropN = XcbCookie Function(Pointer<Void>, Uint8, Uint32, Uint32,
    Uint32, Uint8, Uint32, Pointer<Uint8>);
typedef XcbChgPropD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int, int, Pointer<Uint8>);
typedef XcbGetPropN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint32, Uint32, Uint32, Uint32, Uint32);
typedef XcbGetPropD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int, int);
typedef XcbPValN = Pointer<Uint8> Function(Pointer<Uint8>);
typedef XcbPValD = Pointer<Uint8> Function(Pointer<Uint8>);
typedef XcbPLnN = Int32 Function(Pointer<Uint8>);
typedef XcbPLnD = int Function(Pointer<Uint8>);
typedef XcbSendEvtN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint32, Uint32, Pointer<Uint8>);
typedef XcbSendEvtD = XcbCookie Function(
    Pointer<Void>, int, int, int, Pointer<Uint8>);
typedef XcbCrtGcN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Uint32, Pointer<Uint32>);
typedef XcbCrtGcD = XcbCookie Function(
    Pointer<Void>, int, int, int, Pointer<Uint32>);
typedef XcbPutImgN = XcbCookie Function(Pointer<Void>, Uint8, Uint32, Uint32,
    Uint16, Uint16, Int16, Int16, Uint8, Uint8, Uint32, Pointer<Uint8>);
typedef XcbPutImgD = XcbCookie Function(Pointer<Void>, int, int, int, int, int,
    int, int, int, int, int, Pointer<Uint8>);
typedef XcbClearN = XcbCookie Function(
    Pointer<Void>, Uint8, Uint32, Int16, Int16, Uint16, Uint16);
typedef XcbClearD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int, int);
typedef XcbQryExtN = XcbCookie Function(Pointer<Void>, Uint16, Pointer<Uint8>);
typedef XcbQryExtD = XcbCookie Function(Pointer<Void>, int, Pointer<Uint8>);
typedef XcbXlateN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Int16, Int16);
typedef XcbXlateD = XcbCookie Function(Pointer<Void>, int, int, int, int);
typedef XcbGeomN = XcbCookie Function(Pointer<Void>, Uint32);
typedef XcbGeomD = XcbCookie Function(Pointer<Void>, int);
typedef XcbOpenFontN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint16, Pointer<Uint8>);
typedef XcbOpenFontD = XcbCookie Function(
    Pointer<Void>, int, int, Pointer<Uint8>);
typedef XcbGlyphN = XcbCookie Function(Pointer<Void>, Uint32, Uint32, Uint32,
    Uint16, Uint16, Uint16, Uint16, Uint16, Uint16, Uint16, Uint16);
typedef XcbGlyphD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int, int, int, int, int, int, int);
typedef XcbFocusN = XcbCookie Function(Pointer<Void>, Uint8, Uint32, Uint32);
typedef XcbFocusD = XcbCookie Function(Pointer<Void>, int, int, int);
typedef XcbDelPropN = XcbCookie Function(Pointer<Void>, Uint32, Uint32);
typedef XcbDelPropD = XcbCookie Function(Pointer<Void>, int, int);
typedef XcbSetOwnerN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Uint32);
typedef XcbSetOwnerD = XcbCookie Function(Pointer<Void>, int, int, int);
typedef XcbCnvSelN = XcbCookie Function(
    Pointer<Void>, Uint32, Uint32, Uint32, Uint32, Uint32);
typedef XcbCnvSelD = XcbCookie Function(
    Pointer<Void>, int, int, int, int, int);

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
    'xcb_setup_pixmap_formats_iterator',
    'xcb_format_next',
    'xcb_screen_allowed_depths_iterator',
    'xcb_depth_next',
    'xcb_depth_visuals_iterator',
    'xcb_visualtype_next',
    'xcb_generate_id',
    'xcb_get_file_descriptor',
    'xcb_get_maximum_request_length',
    'xcb_flush',
    'xcb_poll_for_event',
    'xcb_poll_for_queued_event',
    'xcb_request_check',
    'xcb_create_window',
    'xcb_create_window_checked',
    'xcb_destroy_window',
    'xcb_map_window',
    'xcb_unmap_window',
    'xcb_change_window_attributes',
    'xcb_configure_window',
    'xcb_intern_atom',
    'xcb_intern_atom_reply',
    'xcb_get_atom_name',
    'xcb_get_atom_name_reply',
    'xcb_get_atom_name_name',
    'xcb_get_atom_name_name_length',
    'xcb_change_property',
    'xcb_delete_property',
    'xcb_get_property',
    'xcb_get_property_reply',
    'xcb_get_property_value',
    'xcb_get_property_value_length',
    'xcb_set_selection_owner',
    'xcb_get_selection_owner',
    'xcb_get_selection_owner_reply',
    'xcb_convert_selection',
    'xcb_send_event',
    'xcb_create_gc',
    'xcb_create_gc_checked',
    'xcb_free_gc',
    'xcb_put_image',
    'xcb_clear_area',
    'xcb_query_extension',
    'xcb_query_extension_reply',
    'xcb_translate_coordinates',
    'xcb_translate_coordinates_reply',
    'xcb_query_pointer',
    'xcb_query_pointer_reply',
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
  late final XcbFormatIterD setupPixmapFormatsIterator =
      library.lookupFunction<XcbFormatIterN, XcbFormatIterD>(
          'xcb_setup_pixmap_formats_iterator');
  late final XcbFormatNextD formatNext =
      library.lookupFunction<XcbFormatNextN, XcbFormatNextD>('xcb_format_next');
  late final XcbDepthIterD screenAllowedDepthsIterator =
      library.lookupFunction<XcbDepthIterN, XcbDepthIterD>(
          'xcb_screen_allowed_depths_iterator');
  late final XcbDepthNextD depthNext =
      library.lookupFunction<XcbDepthNextN, XcbDepthNextD>('xcb_depth_next');
  late final XcbVisualIterD depthVisualsIterator =
      library.lookupFunction<XcbVisualIterN, XcbVisualIterD>(
          'xcb_depth_visuals_iterator');
  late final XcbVisualNextD visualTypeNext = library
      .lookupFunction<XcbVisualNextN, XcbVisualNextD>('xcb_visualtype_next');
  late final XcbReqChkD requestCheck =
      library.lookupFunction<XcbReqChkN, XcbReqChkD>('xcb_request_check');
  late final XcbCrtWinD createWindow =
      library.lookupFunction<XcbCrtWinN, XcbCrtWinD>('xcb_create_window');
  late final XcbCrtWinD createWindowChecked = library
      .lookupFunction<XcbCrtWinN, XcbCrtWinD>('xcb_create_window_checked');
  late final XcbCwaD changeWindowAttributes =
      library.lookupFunction<XcbCwaN, XcbCwaD>('xcb_change_window_attributes');
  late final XcbCfgWinD configureWindow =
      library.lookupFunction<XcbCfgWinN, XcbCfgWinD>('xcb_configure_window');
  late final XcbInternD internAtom =
      library.lookupFunction<XcbInternN, XcbInternD>('xcb_intern_atom');
  late final XcbChgPropD changeProperty =
      library.lookupFunction<XcbChgPropN, XcbChgPropD>('xcb_change_property');
  late final XcbDelPropD deleteProperty =
      library.lookupFunction<XcbDelPropN, XcbDelPropD>('xcb_delete_property');
  late final XcbSetOwnerD setSelectionOwner =
      library.lookupFunction<XcbSetOwnerN, XcbSetOwnerD>(
          'xcb_set_selection_owner');
  late final XcbCnvSelD convertSelection =
      library.lookupFunction<XcbCnvSelN, XcbCnvSelD>('xcb_convert_selection');
  late final XcbGetPropD getProperty =
      library.lookupFunction<XcbGetPropN, XcbGetPropD>('xcb_get_property');
  late final XcbPValD getPropertyValue =
      library.lookupFunction<XcbPValN, XcbPValD>('xcb_get_property_value');
  late final XcbPLnD getPropertyValueLength =
      library.lookupFunction<XcbPLnN, XcbPLnD>('xcb_get_property_value_length');
  late final XcbPValD getAtomNameName =
      library.lookupFunction<XcbPValN, XcbPValD>('xcb_get_atom_name_name');
  late final XcbPLnD getAtomNameLength =
      library.lookupFunction<XcbPLnN, XcbPLnD>('xcb_get_atom_name_name_length');
  late final XcbSendEvtD sendEvent =
      library.lookupFunction<XcbSendEvtN, XcbSendEvtD>('xcb_send_event');
  late final XcbCrtGcD createGc =
      library.lookupFunction<XcbCrtGcN, XcbCrtGcD>('xcb_create_gc');
  late final XcbCrtGcD createGcChecked =
      library.lookupFunction<XcbCrtGcN, XcbCrtGcD>('xcb_create_gc_checked');
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
  // Both take a single 32-bit resource after the connection, so they share the
  // window cookie shape: an atom and a selection are both `uint32` on the wire.
  late final XcbWinD getAtomName = _win('xcb_get_atom_name');
  late final XcbWinD getSelectionOwner = _win('xcb_get_selection_owner');
  // `xcb_query_pointer` takes one window after the connection, so it shares the
  // window cookie shape too. It is the request an XDND *source* walks the
  // window tree with, once per pointer motion of a drag it started.
  late final XcbWinD queryPointer = _win('xcb_query_pointer');
  late final XcbReplyD internAtomReply = _reply('xcb_intern_atom_reply');
  late final XcbReplyD getAtomNameReply = _reply('xcb_get_atom_name_reply');
  late final XcbReplyD getSelectionOwnerReply =
      _reply('xcb_get_selection_owner_reply');
  late final XcbReplyD getPropertyReply = _reply('xcb_get_property_reply');
  late final XcbReplyD queryPointerReply = _reply('xcb_query_pointer_reply');
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
