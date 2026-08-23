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
const int xcbSelectionClear = 29;
const int xcbSelectionRequest = 30;
const int xcbSelectionNotify = 31;
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

/// `XCB_GET_PROPERTY_TYPE_ANY`: read the property whatever its type is.
///
/// Named rather than written as `0` because a GetProperty that names a type
/// the owner did not use succeeds with an *empty* value and a reply that
/// reports the real type - which reads exactly like "the source sent nothing"
/// and is the classic way a selection transfer appears to silently fail.
const int xcbGetPropertyTypeAny = 0;

/// `XCB_INPUT_FOCUS_POINTER_ROOT`, used when revoking focus.
const int xcbInputFocusPointerRoot = 1;

// ---------------------------------------------------------------------------
// Predefined atoms (X11 protocol appendix B). Interning these would be a
// round trip for a value the protocol already fixed.
// ---------------------------------------------------------------------------

const int xcbAtomAtom = 4;
const int xcbAtomCardinal = 6;

/// `XA_INTEGER`. ICCCM 2.6.2 types the answer to a `TIMESTAMP` conversion with
/// it, which is the one place this backend produces an INTEGER property.
const int xcbAtomInteger = 19;
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
// XDND (freedesktop drag-and-drop). The protocol is entirely ClientMessages
// and properties, so these are the only numbers in it; the atom *names* are in
// `x11_drag_drop.dart` next to the state machine that sends them.
// ---------------------------------------------------------------------------

/// The version this destination advertises in `XdndAware`.
///
/// 5 rather than the newest-imaginable: 5 is what has been current since 2002
/// and is what GTK, Qt, Motif and every file manager speak. There is no 6.
const int xdndVersion = 5;

/// The oldest source version this destination will talk to.
///
/// 3 is where the protocol became what it is today - version 2 has a different
/// `XdndEnter` layout and no `XdndActionList`, and no source that old is still
/// in circulation. Refusing below 3 is refusing to guess at a layout that
/// cannot be tested against anything.
const int xdndMinimumVersion = 3;

/// `XdndEnter` `data.l[1]`: the source's protocol version is the high byte.
const int xdndEnterVersionShift = 24;

/// `XdndEnter` `data.l[1]` bit 0: the source offers more than three types and
/// the real list is in the `XdndTypeList` property on the source window.
const int xdndEnterMoreTypesBit = 1 << 0;

/// How many type atoms `XdndEnter` carries inline, in `data.l[2..4]`.
const int xdndEnterInlineTypeCount = 3;

/// `XdndStatus` `data.l[1]` bit 0: this destination will accept a drop.
const int xdndStatusAcceptBit = 1 << 0;

/// `XdndStatus` `data.l[1]` bit 1: send an `XdndPosition` for every pointer
/// motion, ignoring the rectangle in `data.l[2..3]`.
const int xdndStatusWantPositionBit = 1 << 1;

/// `XdndFinished` `data.l[1]` bit 0: the drop was accepted and the data was
/// transferred. Version 5 only; older sources ignore the whole word, which is
/// why a *move* must never be reported to a version 4 source as performed.
const int xdndFinishedAcceptedBit = 1 << 0;

/// The first version whose `XdndFinished` carries `data.l[1..2]` at all.
///
/// A version 3 or 4 destination sends only `data.l[0]`, so the remaining words
/// hold whatever `SendEvent` padded them with. A source that read them would
/// decide at random whether the drop it just performed succeeded - which is why
/// [X11DragDropManager] treats a pre-5 finish as "accepted, with the action the
/// last `XdndStatus` agreed to" instead of guessing from uninitialised bytes.
const int xdndFinishedVersionedReply = 5;

/// How deep the source's `QueryPointer` walk from the root may go.
///
/// The walk terminates on its own - each step descends into a child of the
/// previous window - but a server that answered with a cycle, or a window
/// hierarchy being reparented underneath the walk, would spin forever inside
/// one pointer motion. Sixteen is far past any real desktop: a client window
/// inside a frame inside the root is three.
const int xdndPointerWalkDepthLimit = 16;

/// A ClientMessage carrying five 32-bit words has format 32. XDND messages are
/// all of this shape, and one arriving with any other format is not XDND.
const int xdndClientMessageFormat = 32;

/// The five `data.l` words every XDND ClientMessage carries.
const int xdndClientMessageWordCount = 5;

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
    case 3:
      return 'GetWindowAttributes';
    case 8:
      return 'MapWindow';
    case 10:
      return 'UnmapWindow';
    case 12:
      return 'ConfigureWindow';
    case 14:
      return 'GetGeometry';
    case 15:
      return 'QueryTree';
    case 16:
      return 'InternAtom';
    case 17:
      return 'GetAtomName';
    case 18:
      return 'ChangeProperty';
    case 19:
      return 'DeleteProperty';
    case 20:
      return 'GetProperty';
    case 22:
      return 'SetSelectionOwner';
    case 23:
      return 'GetSelectionOwner';
    case 24:
      return 'ConvertSelection';
    case 25:
      return 'SendEvent';
    case 38:
      return 'QueryPointer';
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
