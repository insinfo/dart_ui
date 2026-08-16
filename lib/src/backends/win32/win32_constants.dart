/// The Win32 numeric vocabulary this backend needs, and nothing more.
///
/// Names are lowerCamelCase because the analyser's `constant_identifier_names`
/// applies to library code even when the value came from a C header. The
/// original spelling is on every doc comment so a search for `WM_DPICHANGED`
/// in a bug report still lands here.
library;

// ---------------------------------------------------------------------------
// Window class styles (CS_*)
// ---------------------------------------------------------------------------

/// `CS_VREDRAW` - repaint the whole client area when the height changes.
const int csVredraw = 0x0001;

/// `CS_HREDRAW` - repaint the whole client area when the width changes.
const int csHredraw = 0x0002;

/// `CS_DBLCLKS` - deliver WM_LBUTTONDBLCLK instead of a second down.
///
/// Kept, and the reason is the whole of the double-click fix: with this style
/// Windows matches the second press against `GetDoubleClickTime()` and the
/// `SM_CXDOUBLECLK` rectangle *the user configured*, and tells us the answer.
/// Dropping the style would restore a plain second `WM_LBUTTONDOWN` and throw
/// that answer away, leaving every control to guess with a constant. So the
/// style stays and the `*DBLCLK` messages are handled - see [wmLbuttondblclk].
const int csDblclks = 0x0008;

/// `CS_OWNDC` - a private device context per window.
///
/// Not used: a private DC is a per-window GDI allocation that only pays off
/// for OpenGL, and the GL/GPU path belongs to the renderer backend.
const int csOwndc = 0x0020;

// ---------------------------------------------------------------------------
// Window styles (WS_*)
// ---------------------------------------------------------------------------

const int wsOverlapped = 0x00000000;
const int wsPopup = 0x80000000;
const int wsVisible = 0x10000000;
const int wsCaption = 0x00C00000;
const int wsSysmenu = 0x00080000;
const int wsThickframe = 0x00040000;
const int wsMinimizebox = 0x00020000;
const int wsMaximizebox = 0x00010000;
const int wsBorder = 0x00800000;

/// `WS_OVERLAPPEDWINDOW`.
const int wsOverlappedWindow = wsOverlapped |
    wsCaption |
    wsSysmenu |
    wsThickframe |
    wsMinimizebox |
    wsMaximizebox;

/// `WS_EX_APPWINDOW` - force a taskbar button.
const int wsExAppwindow = 0x00040000;

/// `WS_EX_TOOLWINDOW` - no taskbar button; used by the wake window so it never
/// shows up in Alt+Tab.
const int wsExToolwindow = 0x00000080;

/// `CW_USEDEFAULT`. The parameter is a signed 32-bit int, and `0x80000000`
/// is exactly `INT32_MIN` there; spelling it negative keeps FFI from having
/// to truncate a value Dart holds as positive.
const int cwUseDefault = -0x80000000;

/// `HWND_MESSAGE` - parent of a message-only window. Such a window has a
/// queue and a WndProc but is never composited, which is precisely what a
/// wake target should be.
const int hwndMessage = -3;

// ---------------------------------------------------------------------------
// GetWindowLongPtr / SetWindowLongPtr indices
// ---------------------------------------------------------------------------

/// `GWLP_USERDATA`.
const int gwlpUserdata = -21;

/// `GWL_STYLE`.
const int gwlStyle = -16;

/// `GWL_EXSTYLE`.
const int gwlExstyle = -20;

// ---------------------------------------------------------------------------
// ShowWindow commands (SW_*)
// ---------------------------------------------------------------------------

const int swHide = 0;
const int swShowNormal = 1;
const int swShowMinimized = 2;
const int swMaximize = 3;
const int swShowNoActivate = 4;
const int swShow = 5;
const int swMinimize = 6;
const int swRestore = 9;

// ---------------------------------------------------------------------------
// Messages (WM_*)
// ---------------------------------------------------------------------------

const int wmNull = 0x0000;
const int wmCreate = 0x0001;
const int wmDestroy = 0x0002;
const int wmMove = 0x0003;
const int wmSize = 0x0005;
const int wmActivate = 0x0006;
const int wmSetfocus = 0x0007;
const int wmKillfocus = 0x0008;
const int wmPaint = 0x000F;
const int wmClose = 0x0010;
const int wmQueryendsession = 0x0011;
const int wmQuit = 0x0012;
const int wmErasebkgnd = 0x0014;
const int wmEndsession = 0x0016;
const int wmShowwindow = 0x0018;

/// `WM_SETTINGCHANGE` (alias `WM_WININICHANGE`) - a system-wide setting moved
/// while the process was running: light/dark mode, high contrast, the mouse
/// wheel's lines-per-notch, the double-click time.
///
/// **Unhandled, and deliberately so for now**: nothing above the platform layer
/// can receive it. `ThemeData.highContrast` exists but every example picks its
/// theme from `argv` (`example/gallery_shell.dart`), and `window_events.dart`
/// has no settings-changed event to carry the news. Wiring the message before
/// the event exists would just be a `switch` arm that drops its argument. See
/// the message-coverage audit in `doc/architecture/overview.md`.
const int wmSettingchange = 0x001A;

const int wmSetcursor = 0x0020;

/// `WM_GETMINMAXINFO` - the chance to clamp how small or large the user may
/// drag the window.
///
/// Unhandled, and there is nothing to answer it with: `WindowOptions` has no
/// minimum or maximum size, so no caller has ever expressed one. The platform
/// default therefore applies and a window can be dragged down to its caption
/// buttons. Fixing this starts in `platform/native_window.dart`, not here.
const int wmGetminmaxinfo = 0x0024;

/// `WM_DISPLAYCHANGE` - the desktop's resolution or colour depth changed.
///
/// Unhandled. Consequence is mild here because a resolution change that moves
/// or resizes the window is followed by WM_SIZE / WM_MOVE / WM_DPICHANGED,
/// which are handled; what is lost is the chance to re-read monitor bounds,
/// which this backend does not track yet (no screens module, no fullscreen).
const int wmDisplaychange = 0x007E;

const int wmNccreate = 0x0081;
const int wmNcdestroy = 0x0082;

/// `WM_NCHITTEST` - which part of the window a screen point is over.
///
/// Deliberately **not** handled: the frame is the platform's here (the class
/// uses `WS_OVERLAPPEDWINDOW`), so `DefWindowProcW`'s answer is the correct
/// one, and it is what makes dragging the caption and resizing the border
/// work. A custom title bar would have to claim it - and would then also owe
/// `WM_NCCALCSIZE`. The audit pins the current behaviour instead: the default
/// arm of `handleMessage` must keep returning DefWindowProc's hit-test code,
/// because an arm that returned 0 (`HTNOWHERE`) would make the whole frame
/// dead to the mouse.
const int wmNchittest = 0x0084;
const int wmKeydown = 0x0100;
const int wmKeyup = 0x0101;

/// `WM_CHAR` - one UTF-16 code unit, produced by `TranslateMessage` from the
/// key that is being pressed *after* Windows applied the keyboard layout,
/// Shift, CapsLock, NumLock, AltGr and any pending dead key. This is the only
/// truthful source of typed text; a virtual key code is not one.
const int wmChar = 0x0102;

/// `WM_DEADCHAR` - the accent half of a dead-key sequence. Not text: the
/// composed character arrives later as its own [wmChar].
const int wmDeadchar = 0x0103;

const int wmSyskeydown = 0x0104;
const int wmSyskeyup = 0x0105;

/// `WM_SYSCHAR` - the character form of an Alt chord. Not text either: Alt+F
/// is a menu mnemonic, and inserting `f` for it would type into the document
/// while the user was aiming at a menu.
const int wmSyschar = 0x0106;

/// `WM_SYSDEADCHAR`, the [wmDeadchar] of an Alt chord.
const int wmSysdeadchar = 0x0107;

/// `WM_UNICHAR` - the UTF-32 sibling of [wmChar], sent by injectors and by a
/// few non-IME input tools rather than by `TranslateMessage`.
///
/// Unhandled, and the *protocol* is the part that bites: a window is supposed
/// to answer `wParam == UNICODE_NOCHAR` (0xFFFF) with TRUE to advertise that it
/// speaks the message. `DefWindowProcW` answers FALSE, so senders fall back to
/// WM_CHAR, which this backend does handle. The fallback is why nothing is
/// visibly broken today; astral characters from such a sender arrive as a
/// surrogate pair through [wmChar] and `TextInputAssembler` rejoins them.
const int wmUnichar = 0x0109;

/// `WM_SYSCOMMAND` - Close, Minimise, Maximise, Move, Size, and the Alt key
/// opening the (non-existent) menu bar as `SC_KEYMENU`.
///
/// Deliberately left to `DefWindowProcW`: every one of those behaviours is the
/// platform's, and claiming the message would mean re-implementing them. The
/// one visible side effect is that Alt+key chords with no menu to match play
/// the system ding, which is what `SC_KEYMENU` does when the menu bar is empty.
const int wmSyscommand = 0x0112;

const int wmMousemove = 0x0200;
const int wmLbuttondown = 0x0201;
const int wmLbuttonup = 0x0202;

/// `WM_LBUTTONDBLCLK` - the **second** press of a double click, sent *instead
/// of* a second `WM_LBUTTONDOWN` because the class carries [csDblclks].
///
/// "Instead of" is the trap, and it is what broke double click here: a window
/// that handles only `WM_LBUTTONDOWN` sees one press where the user made two,
/// so nothing downstream can ever count to two. The message is not an extra
/// notification on top of a down - it *replaces* it - so the backend turns it
/// into an ordinary `PointerDownEvent` carrying `clickCount: 2`.
const int wmLbuttondblclk = 0x0203;

const int wmRbuttondown = 0x0204;
const int wmRbuttonup = 0x0205;

/// `WM_RBUTTONDBLCLK`, the [wmLbuttondblclk] of the right button.
const int wmRbuttondblclk = 0x0206;

const int wmMbuttondown = 0x0207;
const int wmMbuttonup = 0x0208;

/// `WM_MBUTTONDBLCLK`, the [wmLbuttondblclk] of the middle button.
const int wmMbuttondblclk = 0x0209;

/// `WM_MOUSEWHEEL` - the vertical wheel, in screen coordinates.
///
/// `HIWORD(wParam)` is a **signed** multiple of [wheelDelta], and its sign is
/// the trap: positive means the wheel was rotated *forward, away from the
/// user*, which scrolls the content **up** - toward offset zero. The
/// framework's contract is the opposite one, and says so out loud: positive
/// `PointerScrollEvent.scrollDelta` moves toward increasing coordinates, Down
/// arrow is `applyDelta(+lineExtent)`, and X11's wheel-down (button 5) is
/// `Offset(0, +1)`. So a correct translation **negates** this word.
const int wmMousewheel = 0x020A;

const int wmXbuttondown = 0x020B;
const int wmXbuttonup = 0x020C;

/// `WM_XBUTTONDBLCLK`, the [wmLbuttondblclk] of a side button.
const int wmXbuttondblclk = 0x020D;

/// `WM_MOUSEHWHEEL` - the **horizontal** wheel: a tilt wheel, a trackpad's
/// two-finger sideways swipe, or a thumb wheel. Screen coordinates, like
/// [wmMousewheel].
///
/// Unlike [wmMousewheel] the sign needs no correction: positive means the wheel
/// went *right*, which is toward increasing coordinates, which is what the
/// framework's contract already calls positive.
///
/// Unhandled today, and this one has a consumer waiting: a `ScrollViewer` built
/// with `ScrollAxis.horizontal` reads `event.scrollDelta.dx`
/// (`widgets/controls.dart`), and X11 already fills it from core buttons 6 and
/// 7. On Windows `dx` is non-zero only while Shift is held, so a horizontal
/// list simply does not answer a horizontal wheel.
const int wmMousehwheel = 0x020E;

/// Sent when this window loses the mouse capture, whether it released it or
/// something else took it. Section 27.4 calls this capture-lost.
const int wmCapturechanged = 0x0215;

/// `WM_ENTERSIZEMOVE` - the user grabbed the border or the caption and Windows
/// is about to run its **own** modal message loop until they let go.
///
/// The consequence is specific to how this framework paints. `DispatchMessageW`
/// does not return for the whole drag, so `Win32Dispatcher._pumpNative` never
/// gets back to `_drainQueues` / `_fireDueTimers`, and the Dart side - which is
/// where layout, paint and present live - is frozen. WM_PAINT still arrives,
/// but all it does here is put a `WindowExposedEvent` on a stream nobody is
/// draining. The window therefore shows stale pixels for the length of the
/// drag. The standard cure is a `SetTimer` armed here and killed in
/// [wmExitsizemove], with WM_TIMER pumping one frame.
const int wmEntersizemove = 0x0231;

/// `WM_EXITSIZEMOVE` - the modal loop of [wmEntersizemove] is over.
const int wmExitsizemove = 0x0232;

const int wmMouseleave = 0x02A3;
const int wmDpichanged = 0x02E0;

/// `WM_GETDPISCALEDSIZE` - asked just before [wmDpichanged] so a window can
/// propose its own client size for the new scale.
///
/// Unhandled, and correctly so: answering FALSE (which `DefWindowProcW` does)
/// tells Windows to scale the current size linearly, and this backend's layout
/// is scale-independent, so linear is the right answer.
const int wmGetdpiscaledsize = 0x02E4;

/// `WM_THEMECHANGED` - the visual style changed. Unhandled for the same reason
/// as [wmSettingchange]: there is no theme event above the platform layer to
/// deliver it to.
const int wmThemechanged = 0x031A;

// Virtual keys used when sampling modifier state.
const int vkShift = 0x10;
const int vkControl = 0x11;
const int vkMenu = 0x12;
const int vkLwin = 0x5B;
const int vkRwin = 0x5C;
const int vkCapital = 0x14;
const int vkNumlock = 0x90;
const int vkScroll = 0x91;

/// `TME_LEAVE`
const int tmeLeave = 0x0002;

/// `WM_APP`. Everything from here up is private to the application, so the
/// wake message can never collide with a system or control message.
const int wmApp = 0x8000;

/// The message `Win32WindowingBackend.wake` posts. Handled by returning 0: its
/// only job is to make a blocked wait return.
const int wmAppWake = wmApp + 1;

// ---------------------------------------------------------------------------
// WM_SIZE / WM_ACTIVATE parameters
// ---------------------------------------------------------------------------

const int sizeRestored = 0;
const int sizeMinimized = 1;
const int sizeMaximized = 2;

const int waInactive = 0;

/// `HTCLIENT` - the hit-test code WM_SETCURSOR reports for the client area.
const int htClient = 1;

/// `HTCAPTION` - the title bar. Named so the audit can assert that
/// WM_SETCURSOR over the *frame* is handed back to `DefWindowProcW`, which is
/// what keeps the resize arrows on the border.
const int htCaption = 2;

/// `MK_SHIFT`, held in the low word of mouse messages.
const int mkShift = 0x0004;

/// `MK_XBUTTON1` / `MK_XBUTTON2`, the side buttons as reported in the low word
/// of any mouse message while they are held.
const int mkXbutton1 = 0x0020;
const int mkXbutton2 = 0x0040;

/// `XBUTTON1` / `XBUTTON2` - which side button a [wmXbuttondown] is about,
/// carried in `HIWORD(wParam)` rather than encoded in the message id the way
/// left, right and middle are.
///
/// XBUTTON1 is "back" and XBUTTON2 is "forward" on every mouse that ships with
/// them, which is the mapping `PointerButton.back` / `PointerButton.forward`
/// already exists for and the one the X11 backend already produces (core
/// buttons 8 and 9).
const int xbutton1 = 0x0001;
const int xbutton2 = 0x0002;

/// `WHEEL_DELTA` - one detent of a wheel. Both wheel messages report a signed
/// multiple of this, and a high-resolution wheel reports fractions of it.
const int wheelDelta = 120;

// ---------------------------------------------------------------------------
// Message queue
// ---------------------------------------------------------------------------

const int pmNoremove = 0x0000;
const int pmRemove = 0x0001;

/// `QS_ALLINPUT` - wake for any queued message, posted or sent.
const int qsAllinput = 0x04FF;

/// `MWMO_INPUTAVAILABLE` - return immediately when a message is already
/// queued. Without it a message that arrived between the drain and the wait
/// would be slept through, which is the classic missed-wakeup race.
const int mwmoInputavailable = 0x0004;

/// `MWMO_ALERTABLE` - also return for APCs, so an overlapped I/O completion
/// does not have to wait out the timeout.
const int mwmoAlertable = 0x0002;

/// `INFINITE`.
const int infiniteTimeout = 0xFFFFFFFF;

/// `WAIT_TIMEOUT`.
const int waitTimeout = 0x00000102;

// ---------------------------------------------------------------------------
// SetWindowPos flags (SWP_*)
// ---------------------------------------------------------------------------

const int swpNosize = 0x0001;
const int swpNomove = 0x0002;
const int swpNozorder = 0x0004;
const int swpNoactivate = 0x0010;
const int swpFramechanged = 0x0020;
const int swpNoownerzorder = 0x0200;

// ---------------------------------------------------------------------------
// Cursors (IDC_*)
// ---------------------------------------------------------------------------

const int idcArrow = 32512;
const int idcIbeam = 32513;
const int idcWait = 32514;
const int idcCross = 32515;
const int idcSizeNwse = 32642;
const int idcSizeNesw = 32643;
const int idcSizeWe = 32644;
const int idcSizeNs = 32645;
const int idcNo = 32648;
const int idcHand = 32649;

// ---------------------------------------------------------------------------
// DPI
// ---------------------------------------------------------------------------

/// `USER_DEFAULT_SCREEN_DPI`. Every scale in this backend is `dpi / 96`.
const int defaultScreenDpi = 96;

/// `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`.
///
/// V2 rather than V1 because V2 is the one that scales the non-client area and
/// sends WM_DPICHANGED for dialogs too; V1 leaves the caption bar at the old
/// scale, which looks like a framework bug and is not one.
const int dpiAwarenessContextPerMonitorAwareV2 = -4;

/// `PROCESS_PER_MONITOR_DPI_AWARE`, the shcore-era equivalent.
const int processPerMonitorDpiAware = 2;

/// `LOGPIXELSX`, for the GetDeviceCaps fallback when GetDpiForSystem is
/// missing.
const int logPixelsX = 88;

// ---------------------------------------------------------------------------
// GDI
// ---------------------------------------------------------------------------

const int biRgb = 0;
const int dibRgbColors = 0;
const int srccopy = 0x00CC0020;

/// Clipboard and process-global memory constants.
const int cfUnicodeText = 13;
const int gmemMoveable = 0x0002;

/// `HEAP_ZERO_MEMORY`.
const int heapZeroMemory = 0x00000008;
