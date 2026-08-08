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
const int wmSetcursor = 0x0020;
const int wmGetminmaxinfo = 0x0024;
const int wmNccreate = 0x0081;
const int wmNcdestroy = 0x0082;
const int wmDpichanged = 0x02E0;
const int wmMousemove = 0x0200;

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

/// `HEAP_ZERO_MEMORY`.
const int heapZeroMemory = 0x00000008;
