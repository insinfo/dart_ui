/// Wire constants of the Wayland core and xdg-shell protocols.
///
/// They live in one file so that no other file in this backend contains a bare
/// number, mirroring `x11_protocol.dart`: a request built from magic constants
/// is unreviewable, and `wlSurfaceRequestCommit` tells a reader exactly which
/// message is being marshalled.
///
/// Opcodes are positional: a request's opcode is its zero-based index in the
/// protocol XML, an event's opcode likewise. The values below were transcribed
/// from `wayland.xml` and `xdg-shell.xml` (stable), which are append-only by
/// protocol rule - existing opcodes never change.
library;

// ---------------------------------------------------------------------------
// Interface names, exactly as they appear in wl_registry.global events.
// ---------------------------------------------------------------------------

const String wlDisplayInterfaceName = 'wl_display';
const String wlRegistryInterfaceName = 'wl_registry';
const String wlCallbackInterfaceName = 'wl_callback';
const String wlCompositorInterfaceName = 'wl_compositor';
const String wlShmInterfaceName = 'wl_shm';
const String wlShmPoolInterfaceName = 'wl_shm_pool';
const String wlBufferInterfaceName = 'wl_buffer';
const String wlSurfaceInterfaceName = 'wl_surface';
const String wlSeatInterfaceName = 'wl_seat';
const String wlPointerInterfaceName = 'wl_pointer';
const String wlKeyboardInterfaceName = 'wl_keyboard';
const String wlOutputInterfaceName = 'wl_output';
const String xdgWmBaseInterfaceName = 'xdg_wm_base';
const String xdgSurfaceInterfaceName = 'xdg_surface';
const String xdgToplevelInterfaceName = 'xdg_toplevel';

/// Versions this backend binds when the compositor offers at least them.
/// Conservative on purpose: every request issued below exists at these
/// versions, and binding higher than what is used invites protocol errors.
const int wlCompositorBindVersion = 4;
const int wlShmBindVersion = 1;
const int wlSeatBindVersion = 5;
const int wlOutputBindVersion = 2;
const int xdgWmBaseBindVersion = 1;

// ---------------------------------------------------------------------------
// wl_display (object id 1, implicit).
// ---------------------------------------------------------------------------

/// The client half of the object id space. Ids above this belong to the
/// server; a client that allocates into the server range corrupts the
/// connection.
const int wlDisplayObjectId = 1;
const int wlClientIdMinimum = 2;
const int wlClientIdMaximum = 0xfeffffff;

const int wlDisplayRequestSync = 0;
const int wlDisplayRequestGetRegistry = 1;

const int wlDisplayEventError = 0;
const int wlDisplayEventDeleteId = 1;

/// `wl_display.error` codes.
const int wlDisplayErrorInvalidObject = 0;
const int wlDisplayErrorInvalidMethod = 1;
const int wlDisplayErrorNoMemory = 2;
const int wlDisplayErrorImplementation = 3;

// ---------------------------------------------------------------------------
// wl_registry.
// ---------------------------------------------------------------------------

const int wlRegistryRequestBind = 0;

const int wlRegistryEventGlobal = 0;
const int wlRegistryEventGlobalRemove = 1;

// ---------------------------------------------------------------------------
// wl_callback.
// ---------------------------------------------------------------------------

const int wlCallbackEventDone = 0;

// ---------------------------------------------------------------------------
// wl_compositor.
// ---------------------------------------------------------------------------

const int wlCompositorRequestCreateSurface = 0;
const int wlCompositorRequestCreateRegion = 1;

// ---------------------------------------------------------------------------
// wl_shm and wl_shm_pool.
// ---------------------------------------------------------------------------

const int wlShmRequestCreatePool = 0;

const int wlShmEventFormat = 0;

/// `wl_shm.format` values. ARGB8888 is "32-bit ARGB, little-endian", which in
/// memory is exactly the framework's premultiplied BGRA byte order - the same
/// happy coincidence the Win32 DIB and X11 PutImage paths rely on.
const int wlShmFormatArgb8888 = 0;
const int wlShmFormatXrgb8888 = 1;

const int wlShmPoolRequestCreateBuffer = 0;
const int wlShmPoolRequestDestroy = 1;
const int wlShmPoolRequestResize = 2;

// ---------------------------------------------------------------------------
// wl_buffer.
// ---------------------------------------------------------------------------

const int wlBufferRequestDestroy = 0;

const int wlBufferEventRelease = 0;

// ---------------------------------------------------------------------------
// wl_surface.
// ---------------------------------------------------------------------------

const int wlSurfaceRequestDestroy = 0;
const int wlSurfaceRequestAttach = 1;
const int wlSurfaceRequestDamage = 2;
const int wlSurfaceRequestFrame = 3;
const int wlSurfaceRequestSetOpaqueRegion = 4;
const int wlSurfaceRequestSetInputRegion = 5;
const int wlSurfaceRequestCommit = 6;
const int wlSurfaceRequestSetBufferTransform = 7;
const int wlSurfaceRequestSetBufferScale = 8;
const int wlSurfaceRequestDamageBuffer = 9;

const int wlSurfaceEventEnter = 0;
const int wlSurfaceEventLeave = 1;

// ---------------------------------------------------------------------------
// wl_seat.
// ---------------------------------------------------------------------------

const int wlSeatRequestGetPointer = 0;
const int wlSeatRequestGetKeyboard = 1;
const int wlSeatRequestGetTouch = 2;
const int wlSeatRequestRelease = 3;

const int wlSeatEventCapabilities = 0;
const int wlSeatEventName = 1;

const int wlSeatCapabilityPointer = 1;
const int wlSeatCapabilityKeyboard = 2;
const int wlSeatCapabilityTouch = 4;

// ---------------------------------------------------------------------------
// wl_pointer.
// ---------------------------------------------------------------------------

const int wlPointerRequestSetCursor = 0;
const int wlPointerRequestRelease = 1;

const int wlPointerEventEnter = 0;
const int wlPointerEventLeave = 1;
const int wlPointerEventMotion = 2;
const int wlPointerEventButton = 3;
const int wlPointerEventAxis = 4;
const int wlPointerEventFrame = 5;
const int wlPointerEventAxisSource = 6;
const int wlPointerEventAxisStop = 7;
const int wlPointerEventAxisDiscrete = 8;

const int wlPointerButtonStateReleased = 0;
const int wlPointerButtonStatePressed = 1;

const int wlPointerAxisVerticalScroll = 0;
const int wlPointerAxisHorizontalScroll = 1;

/// Linux evdev button codes carried by `wl_pointer.button`.
const int btnLeft = 0x110;
const int btnRight = 0x111;
const int btnMiddle = 0x112;
const int btnSide = 0x113;
const int btnExtra = 0x114;

// ---------------------------------------------------------------------------
// wl_keyboard.
// ---------------------------------------------------------------------------

const int wlKeyboardRequestRelease = 0;

const int wlKeyboardEventKeymap = 0;
const int wlKeyboardEventEnter = 1;
const int wlKeyboardEventLeave = 2;
const int wlKeyboardEventKey = 3;
const int wlKeyboardEventModifiers = 4;
const int wlKeyboardEventRepeatInfo = 5;

const int wlKeyboardKeymapFormatNoKeymap = 0;
const int wlKeyboardKeymapFormatXkbV1 = 1;

const int wlKeyboardKeyStateReleased = 0;
const int wlKeyboardKeyStatePressed = 1;

/// `wl_keyboard.key` carries the evdev keycode; the xkb keymap indexes keys by
/// the historical X keycode, which is evdev + 8.
const int evdevToXkbKeycodeOffset = 8;

// ---------------------------------------------------------------------------
// wl_data_device_manager, wl_data_device, wl_data_source, wl_data_offer.
// ---------------------------------------------------------------------------

const String wlDataDeviceManagerInterfaceName = 'wl_data_device_manager';
const int wlDataDeviceManagerBindVersion = 1;

const int wlDataDeviceManagerRequestCreateDataSource = 0;
const int wlDataDeviceManagerRequestGetDataDevice = 1;

const int wlDataDeviceRequestStartDrag = 0;
const int wlDataDeviceRequestSetSelection = 1;

const int wlDataDeviceEventDataOffer = 0;
const int wlDataDeviceEventEnter = 1;
const int wlDataDeviceEventLeave = 2;
const int wlDataDeviceEventMotion = 3;
const int wlDataDeviceEventDrop = 4;
const int wlDataDeviceEventSelection = 5;

const int wlDataSourceRequestOffer = 0;
const int wlDataSourceRequestDestroy = 1;

const int wlDataSourceEventTarget = 0;
const int wlDataSourceEventSend = 1;
const int wlDataSourceEventCancelled = 2;

const int wlDataOfferRequestAccept = 0;
const int wlDataOfferRequestReceive = 1;
const int wlDataOfferRequestDestroy = 2;

const int wlDataOfferEventOffer = 0;

/// The MIME types this backend offers and accepts for clipboard text. The
/// first is the canonical modern spelling; the others are what GTK/Qt clients
/// have historically published, accepted here so pasting from them works.
const String wlClipboardTextMime = 'text/plain;charset=utf-8';
const List<String> wlClipboardAcceptedTextMimes = <String>[
  wlClipboardTextMime,
  'text/plain;charset=UTF-8',
  'UTF8_STRING',
  'text/plain',
];

// ---------------------------------------------------------------------------
// wl_output.
// ---------------------------------------------------------------------------

const int wlOutputEventGeometry = 0;
const int wlOutputEventMode = 1;
const int wlOutputEventDone = 2;
const int wlOutputEventScale = 3;

// ---------------------------------------------------------------------------
// xdg_wm_base.
// ---------------------------------------------------------------------------

const int xdgWmBaseRequestDestroy = 0;
const int xdgWmBaseRequestCreatePositioner = 1;
const int xdgWmBaseRequestGetXdgSurface = 2;
const int xdgWmBaseRequestPong = 3;

const int xdgWmBaseEventPing = 0;

// ---------------------------------------------------------------------------
// xdg_surface.
// ---------------------------------------------------------------------------

const int xdgSurfaceRequestDestroy = 0;
const int xdgSurfaceRequestGetToplevel = 1;
const int xdgSurfaceRequestGetPopup = 2;
const int xdgSurfaceRequestSetWindowGeometry = 3;
const int xdgSurfaceRequestAckConfigure = 4;

const int xdgSurfaceEventConfigure = 0;

// ---------------------------------------------------------------------------
// xdg_toplevel.
// ---------------------------------------------------------------------------

const int xdgToplevelRequestDestroy = 0;
const int xdgToplevelRequestSetParent = 1;
const int xdgToplevelRequestSetTitle = 2;
const int xdgToplevelRequestSetAppId = 3;
const int xdgToplevelRequestShowWindowMenu = 4;
const int xdgToplevelRequestMove = 5;
const int xdgToplevelRequestResize = 6;
const int xdgToplevelRequestSetMaxSize = 7;
const int xdgToplevelRequestSetMinSize = 8;
const int xdgToplevelRequestSetMaximized = 9;
const int xdgToplevelRequestUnsetMaximized = 10;
const int xdgToplevelRequestSetFullscreen = 11;
const int xdgToplevelRequestUnsetFullscreen = 12;
const int xdgToplevelRequestSetMinimized = 13;

const int xdgToplevelEventConfigure = 0;
const int xdgToplevelEventClose = 1;
const int xdgToplevelEventConfigureBounds = 2;
const int xdgToplevelEventWmCapabilities = 3;

/// `xdg_toplevel.state` values inside the configure `states` array.
const int xdgToplevelStateMaximized = 1;
const int xdgToplevelStateFullscreen = 2;
const int xdgToplevelStateResizing = 3;
const int xdgToplevelStateActivated = 4;

/// `wl_display.error` code names, per section 6.6: a failure that reports
/// "error 1" is useless; "invalid_method" names the bug.
String wlDisplayErrorName(int code) {
  switch (code) {
    case wlDisplayErrorInvalidObject:
      return 'invalid_object';
    case wlDisplayErrorInvalidMethod:
      return 'invalid_method';
    case wlDisplayErrorNoMemory:
      return 'no_memory';
    case wlDisplayErrorImplementation:
      return 'implementation';
    default:
      return 'display error $code';
  }
}
