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

/// Drag-and-drop additions in `wl_data_device_manager` version 3. Binding at
/// version 3 is what makes actions - copy versus move - expressible at all;
/// below it a drop has no negotiated action and the source cannot tell
/// whether the data was taken.
const int wlDataDeviceManagerDragBindVersion = 3;

const int wlDataSourceRequestSetActions = 2;
const int wlDataOfferRequestFinish = 3;
const int wlDataOfferRequestSetActions = 4;

const int wlDataSourceEventDndDropPerformed = 3;
const int wlDataSourceEventDndFinished = 4;
const int wlDataSourceEventAction = 5;

const int wlDataOfferEventSourceActions = 1;
const int wlDataOfferEventAction = 2;

const int wlDataDeviceRequestRelease = 2;

/// `wl_data_device_manager.dnd_action` bitmask.
const int wlDataDeviceManagerDndActionNone = 0;
const int wlDataDeviceManagerDndActionCopy = 1 << 0;
const int wlDataDeviceManagerDndActionMove = 1 << 1;
const int wlDataDeviceManagerDndActionAsk = 1 << 2;

/// Names for the action bitmask, so a diagnostic reads as words.
String wlDndActionName(int action) {
  switch (action) {
    case wlDataDeviceManagerDndActionNone:
      return 'none';
    case wlDataDeviceManagerDndActionCopy:
      return 'copy';
    case wlDataDeviceManagerDndActionMove:
      return 'move';
    case wlDataDeviceManagerDndActionAsk:
      return 'ask';
    default:
      return 'actions 0x${action.toRadixString(16)}';
  }
}

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

// ---------------------------------------------------------------------------
// xdg_positioner and xdg_popup.
// ---------------------------------------------------------------------------

const String xdgPositionerInterfaceName = 'xdg_positioner';
const String xdgPopupInterfaceName = 'xdg_popup';

const int xdgPositionerRequestDestroy = 0;
const int xdgPositionerRequestSetSize = 1;
const int xdgPositionerRequestSetAnchorRect = 2;
const int xdgPositionerRequestSetAnchor = 3;
const int xdgPositionerRequestSetGravity = 4;
const int xdgPositionerRequestSetConstraintAdjustment = 5;
const int xdgPositionerRequestSetOffset = 6;
const int xdgPositionerRequestSetReactive = 7;
const int xdgPositionerRequestSetParentSize = 8;
const int xdgPositionerRequestSetParentConfigure = 9;

/// `xdg_positioner.anchor` and `.gravity` share this enumeration.
const int xdgPositionerAnchorNone = 0;
const int xdgPositionerAnchorTop = 1;
const int xdgPositionerAnchorBottom = 2;
const int xdgPositionerAnchorLeft = 3;
const int xdgPositionerAnchorRight = 4;
const int xdgPositionerAnchorTopLeft = 5;
const int xdgPositionerAnchorBottomLeft = 6;
const int xdgPositionerAnchorTopRight = 7;
const int xdgPositionerAnchorBottomRight = 8;

/// `xdg_positioner.constraint_adjustment` bits.
const int xdgPositionerConstraintAdjustmentNone = 0;
const int xdgPositionerConstraintAdjustmentSlideX = 1 << 0;
const int xdgPositionerConstraintAdjustmentSlideY = 1 << 1;
const int xdgPositionerConstraintAdjustmentFlipX = 1 << 2;
const int xdgPositionerConstraintAdjustmentFlipY = 1 << 3;
const int xdgPositionerConstraintAdjustmentResizeX = 1 << 4;
const int xdgPositionerConstraintAdjustmentResizeY = 1 << 5;

const int xdgPopupRequestDestroy = 0;
const int xdgPopupRequestGrab = 1;
const int xdgPopupRequestReposition = 2;

const int xdgPopupEventConfigure = 0;
const int xdgPopupEventPopupDone = 1;
const int xdgPopupEventRepositioned = 2;

// ---------------------------------------------------------------------------
// zxdg_decoration_manager_v1 (xdg-decoration, unstable v1).
// ---------------------------------------------------------------------------

const String xdgDecorationManagerInterfaceName =
    'zxdg_decoration_manager_v1';
const int xdgDecorationManagerBindVersion = 1;

const int xdgDecorationManagerRequestDestroy = 0;
const int xdgDecorationManagerRequestGetToplevelDecoration = 1;

const int xdgToplevelDecorationRequestDestroy = 0;
const int xdgToplevelDecorationRequestSetMode = 1;
const int xdgToplevelDecorationRequestUnsetMode = 2;

const int xdgToplevelDecorationEventConfigure = 0;

/// `zxdg_toplevel_decoration_v1.mode`.
const int xdgToplevelDecorationModeClientSide = 1;
const int xdgToplevelDecorationModeServerSide = 2;

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

// ---------------------------------------------------------------------------
// zwp_text_input_manager_v3 / zwp_text_input_v3 (text-input, unstable v3).
// ---------------------------------------------------------------------------

/// The input-method protocol every current compositor implements.
///
/// Version 1 is the only version there has ever been, which is why the bind
/// version below is not clamped against anything: `text-input-unstable-v3` has
/// had one revision since 2017 and an unstable protocol is replaced rather than
/// extended.
///
/// A compositor that advertises neither this nor its `v1`/`v2` predecessors has
/// no input method at all; there is deliberately no fallback to `v2` here,
/// because `v2` is a *different* protocol (it carries preedit styling and a
/// `zwp_input_method_v2` counterpart) rather than an older spelling of this
/// one, and supporting both would mean two state machines for one feature.
const String zwpTextInputManagerV3InterfaceName = 'zwp_text_input_manager_v3';
const String zwpTextInputV3InterfaceName = 'zwp_text_input_v3';
const int zwpTextInputManagerV3BindVersion = 1;

const int zwpTextInputManagerV3RequestDestroy = 0;
const int zwpTextInputManagerV3RequestGetTextInput = 1;

const int zwpTextInputV3RequestDestroy = 0;
const int zwpTextInputV3RequestEnable = 1;
const int zwpTextInputV3RequestDisable = 2;
const int zwpTextInputV3RequestSetSurroundingText = 3;
const int zwpTextInputV3RequestSetTextChangeCause = 4;
const int zwpTextInputV3RequestSetContentType = 5;
const int zwpTextInputV3RequestSetCursorRectangle = 6;
const int zwpTextInputV3RequestCommit = 7;

const int zwpTextInputV3EventEnter = 0;
const int zwpTextInputV3EventLeave = 1;
const int zwpTextInputV3EventPreeditString = 2;
const int zwpTextInputV3EventCommitString = 3;
const int zwpTextInputV3EventDeleteSurroundingText = 4;
const int zwpTextInputV3EventDone = 5;

/// `zwp_text_input_v3.change_cause`: who moved the text.
///
/// Sent with `set_surrounding_text` so the input method can tell its own edit
/// from the user's. A method that believes the user moved the caret abandons
/// its conversion; one that knows it moved the caret itself keeps going.
const int zwpTextInputV3ChangeCauseInputMethod = 0;
const int zwpTextInputV3ChangeCauseOther = 1;

/// `zwp_text_input_v3.content_hint` bits.
const int zwpTextInputV3ContentHintNone = 0x0;
const int zwpTextInputV3ContentHintCompletion = 0x1;
const int zwpTextInputV3ContentHintSpellcheck = 0x2;
const int zwpTextInputV3ContentHintAutoCapitalization = 0x4;
const int zwpTextInputV3ContentHintLowercase = 0x8;
const int zwpTextInputV3ContentHintUppercase = 0x10;
const int zwpTextInputV3ContentHintTitlecase = 0x20;
const int zwpTextInputV3ContentHintHiddenText = 0x40;
const int zwpTextInputV3ContentHintSensitiveData = 0x80;
const int zwpTextInputV3ContentHintLatin = 0x100;
const int zwpTextInputV3ContentHintMultiline = 0x200;

/// `zwp_text_input_v3.content_purpose` values.
const int zwpTextInputV3ContentPurposeNormal = 0;
const int zwpTextInputV3ContentPurposeAlpha = 1;
const int zwpTextInputV3ContentPurposeDigits = 2;
const int zwpTextInputV3ContentPurposeNumber = 3;
const int zwpTextInputV3ContentPurposePhone = 4;
const int zwpTextInputV3ContentPurposeUrl = 5;
const int zwpTextInputV3ContentPurposeEmail = 6;
const int zwpTextInputV3ContentPurposeName = 7;
const int zwpTextInputV3ContentPurposePassword = 8;
const int zwpTextInputV3ContentPurposePin = 9;
const int zwpTextInputV3ContentPurposeDate = 10;
const int zwpTextInputV3ContentPurposeTime = 11;
const int zwpTextInputV3ContentPurposeDatetime = 12;
const int zwpTextInputV3ContentPurposeTerminal = 13;

/// The cap `set_surrounding_text` must stay under.
///
/// The protocol says the message must not exceed 4000 bytes, and a client that
/// exceeds it is disconnected - not warned. So a large document is clipped
/// around the caret before it is sent; see `WaylandTextInputManager`.
const int zwpTextInputV3SurroundingTextMaxBytes = 4000;
