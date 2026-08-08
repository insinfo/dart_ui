/// Wire constants of the X11 core protocol.
///
/// They live in one file so that no other file in this backend contains a bare
/// number. An X request built from magic constants is unreviewable: `1 << 17`
/// tells a reader nothing, [xcbEventMaskStructureNotify] tells them what the
/// window will actually receive.
///
/// Names follow the XCB spelling rather than the Xlib one, because XCB is what
/// this backend calls (roadmap section 15.1: asynchronous, explicit protocol,
/// less implicit state).
library;

// ---------------------------------------------------------------------------
// Event type codes, as found in `response_type & 0x7f`.
// ---------------------------------------------------------------------------

const int xcbError = 0;
const int xcbKeyPress = 2;
const int xcbKeyRelease = 3;
const int xcbButtonPress = 4;
const int xcbButtonRelease = 5;
const int xcbMotionNotify = 6;
const int xcbEnterNotify = 7;
const int xcbLeaveNotify = 8;
const int xcbFocusIn = 9;
const int xcbFocusOut = 10;
const int xcbExpose = 12;
const int xcbVisibilityNotify = 15;
const int xcbDestroyNotify = 17;
const int xcbUnmapNotify = 18;
const int xcbMapNotify = 19;
const int xcbReparentNotify = 21;
const int xcbConfigureNotify = 22;
const int xcbPropertyNotify = 28;
const int xcbClientMessage = 33;
const int xcbMappingNotify = 34;
const int xcbGenericEvent = 35;

/// Set in `response_type` when the event was produced by `SendEvent` rather
/// than by the server. ICCCM 4.2.3 makes this the flag that says a
/// ConfigureNotify carries root-relative coordinates.
const int xcbSendEventFlag = 0x80;

// ---------------------------------------------------------------------------
// Focus notify `mode`, at byte 8 of a FocusIn/FocusOut event.
// ---------------------------------------------------------------------------

const int xcbNotifyModeNormal = 0;
const int xcbNotifyModeGrab = 1;
const int xcbNotifyModeUngrab = 2;
const int xcbNotifyModeWhileGrabbed = 3;

/// Focus notify `detail`. `Pointer` and `PointerRoot` describe the pointer
/// moving, not the keyboard focus, and treating them as activation makes a
/// window flicker between active and inactive as the mouse crosses it.
const int xcbNotifyDetailPointer = 5;
const int xcbNotifyDetailPointerRoot = 6;

// ---------------------------------------------------------------------------
// Event masks for CW_EVENT_MASK.
// ---------------------------------------------------------------------------

const int xcbEventMaskKeyPress = 1 << 0;
const int xcbEventMaskKeyRelease = 1 << 1;
const int xcbEventMaskButtonPress = 1 << 2;
const int xcbEventMaskButtonRelease = 1 << 3;
const int xcbEventMaskEnterWindow = 1 << 4;
const int xcbEventMaskLeaveWindow = 1 << 5;
const int xcbEventMaskPointerMotion = 1 << 6;
const int xcbEventMaskExposure = 1 << 15;
const int xcbEventMaskVisibilityChange = 1 << 16;
const int xcbEventMaskStructureNotify = 1 << 17;
const int xcbEventMaskSubstructureNotify = 1 << 19;
const int xcbEventMaskSubstructureRedirect = 1 << 20;
const int xcbEventMaskFocusChange = 1 << 21;
const int xcbEventMaskPropertyChange = 1 << 22;

// ---------------------------------------------------------------------------
// CreateWindow / ChangeWindowAttributes value mask bits. The value list must
// be written in increasing bit order; getting that wrong produces a BadMatch
// with no hint as to which attribute was misread.
// ---------------------------------------------------------------------------

const int xcbCwBackPixmap = 1 << 0;
const int xcbCwBackPixel = 1 << 1;
const int xcbCwBorderPixel = 1 << 3;
const int xcbCwBitGravity = 1 << 4;
const int xcbCwWinGravity = 1 << 5;
const int xcbCwOverrideRedirect = 1 << 9;
const int xcbCwEventMask = 1 << 11;
const int xcbCwColormap = 1 << 13;
const int xcbCwCursor = 1 << 14;

/// `XCB_BACK_PIXMAP_NONE`. See [X11WindowAttributes] in `x11_window.dart` for
/// why the background is None rather than a solid colour.
const int xcbBackPixmapNone = 0;

/// `XCB_GRAVITY_NORTH_WEST`: keep the top-left corner put on a resize so the
/// server does not shuffle our pixels around behind the renderer's back.
const int xcbGravityNorthWest = 1;

// ---------------------------------------------------------------------------
// ConfigureWindow value mask bits.
// ---------------------------------------------------------------------------

const int xcbConfigWindowX = 1 << 0;
const int xcbConfigWindowY = 1 << 1;
const int xcbConfigWindowWidth = 1 << 2;
const int xcbConfigWindowHeight = 1 << 3;

// ---------------------------------------------------------------------------
// Misc request enumerations.
// ---------------------------------------------------------------------------

const int xcbWindowClassInputOutput = 1;
const int xcbCopyFromParent = 0;
const int xcbPropModeReplace = 0;
const int xcbImageFormatZPixmap = 2;
const int xcbNone = 0;
const int xcbCurrentTime = 0;

/// `XCB_INPUT_FOCUS_POINTER_ROOT`, used when revoking focus.
const int xcbInputFocusPointerRoot = 1;

// ---------------------------------------------------------------------------
// Predefined atoms (X11 protocol appendix B). Interning these would be a
// round trip for a value the protocol already fixed.
// ---------------------------------------------------------------------------

const int xcbAtomAtom = 4;
const int xcbAtomCardinal = 6;
const int xcbAtomResourceManager = 23;
const int xcbAtomString = 31;
const int xcbAtomWindow = 33;
const int xcbAtomWmName = 39;
const int xcbAtomWmNormalHints = 40;
const int xcbAtomWmSizeHints = 41;
const int xcbAtomWmClass = 67;

// ---------------------------------------------------------------------------
// ICCCM WM_SIZE_HINTS flags.
// ---------------------------------------------------------------------------

const int icccmSizeHintUsPosition = 1 << 0;
const int icccmSizeHintUsSize = 1 << 1;
const int icccmSizeHintPPosition = 1 << 2;
const int icccmSizeHintPSize = 1 << 3;
const int icccmSizeHintPMinSize = 1 << 4;
const int icccmSizeHintPMaxSize = 1 << 5;

/// `WM_SIZE_HINTS` is 18 32-bit words; the property is written with format 32
/// and length 18. Writing fewer makes older window managers read uninitialised
/// memory from their own buffer.
const int icccmSizeHintsWordCount = 18;

/// `_MOTIF_WM_HINTS` is 5 words: flags, functions, decorations, input mode,
/// status. Still the only portable way to ask for an undecorated window.
const int motifHintsWordCount = 5;
const int motifHintFlagDecorations = 1 << 1;

/// `_NET_WM_STATE` ClientMessage actions.
const int netWmStateRemove = 0;
const int netWmStateAdd = 1;
const int netWmStateToggle = 2;

/// `WM_STATE` values (ICCCM 4.1.3.1). Iconic is how X spells "minimised".
const int icccmWmStateWithdrawn = 0;
const int icccmWmStateNormal = 1;
const int icccmWmStateIconic = 3;

// ---------------------------------------------------------------------------
// Standard cursor font glyph indices (`X11/cursorfont.h`). The glyph, not the
// glyph + 1 mask index, which is derived at creation time.
// ---------------------------------------------------------------------------

const int xcGlyphCircle = 24;
const int xcGlyphCrosshair = 34;
const int xcGlyphHand2 = 60;
const int xcGlyphLeftPtr = 68;
const int xcGlyphSbHDoubleArrow = 108;
const int xcGlyphSbVDoubleArrow = 116;
const int xcGlyphTopLeftCorner = 134;
const int xcGlyphTopRightCorner = 136;
const int xcGlyphWatch = 150;
const int xcGlyphXterm = 152;

/// `xcb_connection_has_error` return values.
///
/// Reporting the number alone is what section 6.6 calls a useless failure: a
/// developer seeing `xcb_connect failed: 2` has to go and read libxcb's
/// headers, and a developer seeing `CLOSED_EXT_NOTSUPPORTED` already knows.
String xcbConnectionErrorName(int code) {
  switch (code) {
    case 0:
      return 'OK';
    case 1:
      return 'XCB_CONN_ERROR (socket, pipe or stream error)';
    case 2:
      return 'XCB_CONN_CLOSED_EXT_NOTSUPPORTED';
    case 3:
      return 'XCB_CONN_CLOSED_MEM_INSUFFICIENT';
    case 4:
      return 'XCB_CONN_CLOSED_REQ_LEN_EXCEED';
    case 5:
      return 'XCB_CONN_CLOSED_PARSE_ERR (bad DISPLAY value)';
    case 6:
      return 'XCB_CONN_CLOSED_INVALID_SCREEN';
    case 7:
      return 'XCB_CONN_CLOSED_FDPASSING_FAILED';
    default:
      return 'unknown xcb connection error $code';
  }
}

/// Core protocol error codes, as delivered in `xcb_generic_error_t.error_code`.
String x11ErrorName(int code) {
  switch (code) {
    case 1:
      return 'BadRequest';
    case 2:
      return 'BadValue';
    case 3:
      return 'BadWindow';
    case 4:
      return 'BadPixmap';
    case 5:
      return 'BadAtom';
    case 6:
      return 'BadCursor';
    case 7:
      return 'BadFont';
    case 8:
      return 'BadMatch';
    case 9:
      return 'BadDrawable';
    case 10:
      return 'BadAccess';
    case 11:
      return 'BadAlloc';
    case 12:
      return 'BadColor';
    case 13:
      return 'BadGC';
    case 14:
      return 'BadIDChoice';
    case 15:
      return 'BadName';
    case 16:
      return 'BadLength';
    case 17:
      return 'BadImplementation';
    default:
      return 'X error $code';
  }
}

/// Names of the core requests this backend issues, keyed by major opcode.
///
/// An X error carries the opcode of the request that caused it and nothing
/// else. Without this table a BadMatch says "something failed"; with it, it
/// says "CreateWindow failed", which is the difference between a five-minute
/// fix and an afternoon.
String x11RequestName(int majorOpcode) {
  switch (majorOpcode) {
    case 1:
      return 'CreateWindow';
    case 2:
      return 'ChangeWindowAttributes';
    case 8:
      return 'MapWindow';
    case 10:
      return 'UnmapWindow';
    case 12:
      return 'ConfigureWindow';
    case 14:
      return 'GetGeometry';
    case 16:
      return 'InternAtom';
    case 18:
      return 'ChangeProperty';
    case 20:
      return 'GetProperty';
    case 25:
      return 'SendEvent';
    case 40:
      return 'TranslateCoordinates';
    case 42:
      return 'SetInputFocus';
    case 45:
      return 'OpenFont';
    case 46:
      return 'CloseFont';
    case 55:
      return 'CreateGC';
    case 60:
      return 'FreeGC';
    case 61:
      return 'ClearArea';
    case 72:
      return 'PutImage';
    case 94:
      return 'CreateGlyphCursor';
    case 98:
      return 'QueryExtension';
    default:
      return 'request opcode $majorOpcode';
  }
}
