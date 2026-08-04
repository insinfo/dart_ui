/// Win32 constants for POC-01.
///
/// Only the minimum constants needed to create a window,
/// handle messages, and present a CPU-rendered framebuffer.
library;

// ============================================================
// Window Messages
// ============================================================
const WM_NULL = 0x0000;
const WM_CREATE = 0x0001;
const WM_DESTROY = 0x0002;
const WM_MOVE = 0x0003;
const WM_SIZE = 0x0005;
const WM_ACTIVATE = 0x0006;
const WM_SETFOCUS = 0x0007;
const WM_KILLFOCUS = 0x0008;
const WM_ENABLE = 0x000A;
const WM_PAINT = 0x000F;
const WM_CLOSE = 0x0010;
const WM_QUIT = 0x0012;
const WM_ERASEBKGND = 0x0014;
const WM_SHOWWINDOW = 0x0018;
const WM_NCCREATE = 0x0081;
const WM_NCDESTROY = 0x0082;
const WM_NCHITTEST = 0x0084;
const WM_NCCALCSIZE = 0x0083;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_SYSCHAR = 0x0106;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_LBUTTONDBLCLK = 0x0203;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020A;
const WM_MOUSEHWHEEL = 0x020E;
const WM_MOUSELEAVE = 0x02A3;
const WM_DPICHANGED = 0x02E0;
const WM_GETMINMAXINFO = 0x0024;
const WM_WINDOWPOSCHANGING = 0x0046;
const WM_WINDOWPOSCHANGED = 0x0047;
const WM_DISPLAYCHANGE = 0x007E;
const WM_THEMECHANGED = 0x031A;
const WM_SETTINGCHANGE = 0x001A;
const WM_USER = 0x0400;
const WM_APP = 0x8000;

// ============================================================
// Window Styles
// ============================================================
const WS_OVERLAPPED = 0x00000000;
const WS_CAPTION = 0x00C00000;
const WS_SYSMENU = 0x00080000;
const WS_THICKFRAME = 0x00040000;
const WS_MINIMIZEBOX = 0x00020000;
const WS_MAXIMIZEBOX = 0x00010000;
const WS_OVERLAPPEDWINDOW =
    WS_OVERLAPPED |
    WS_CAPTION |
    WS_SYSMENU |
    WS_THICKFRAME |
    WS_MINIMIZEBOX |
    WS_MAXIMIZEBOX;
const WS_VISIBLE = 0x10000000;
const WS_POPUP = 0x80000000;
const WS_CHILD = 0x40000000;

// Extended Window Styles
const WS_EX_APPWINDOW = 0x00040000;
const WS_EX_WINDOWEDGE = 0x00000100;
const WS_EX_CLIENTEDGE = 0x00000200;
const WS_EX_OVERLAPPEDWINDOW = WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE;

// ============================================================
// ShowWindow Commands
// ============================================================
const SW_HIDE = 0;
const SW_SHOWNORMAL = 1;
const SW_SHOW = 5;
const SW_SHOWDEFAULT = 10;

// ============================================================
// Class Styles
// ============================================================
const CS_VREDRAW = 0x0001;
const CS_HREDRAW = 0x0002;
const CS_DBLCLKS = 0x0008;
const CS_OWNDC = 0x0020;

// ============================================================
// Window Long Ptr indices
// ============================================================
const GWLP_USERDATA = -21;
const GWLP_WNDPROC = -4;

// ============================================================
// Cursor/Icon
// ============================================================
const IDC_ARROW = 32512;
const IDI_APPLICATION = 32512;
const IMAGE_CURSOR = 2;
const IMAGE_ICON = 1;
const LR_DEFAULTSIZE = 0x00000040;
const LR_SHARED = 0x00008000;

// ============================================================
// Colors / Brushes
// ============================================================
const COLOR_WINDOW = 5;
const COLOR_BTNFACE = 15;

// ============================================================
// GDI / DIBSection
// ============================================================
const SRCCOPY = 0x00CC0020;
const DIB_RGB_COLORS = 0;
const BI_RGB = 0;

// ============================================================
// System Metrics
// ============================================================
const SM_CXSCREEN = 0;
const SM_CYSCREEN = 1;

// ============================================================
// DPI Awareness
// ============================================================
const DPI_AWARENESS_CONTEXT_UNAWARE = -1;
const DPI_AWARENESS_CONTEXT_SYSTEM_AWARE = -2;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE = -3;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;

// ============================================================
// Virtual Key Codes
// ============================================================
const VK_ESCAPE = 0x1B;
const VK_RETURN = 0x0D;
const VK_SPACE = 0x20;
const VK_TAB = 0x09;
const VK_F4 = 0x73;

// ============================================================
// Misc
// ============================================================
const CW_USEDEFAULT = 0x80000000;
const NULL = 0;
const TRUE = 1;
const FALSE = 0;
