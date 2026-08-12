import 'dart:ffi';

// ============================================================
// CONSTANTES WIN32
// ============================================================
const int CS_VREDRAW = 0x0001;
const int CS_HREDRAW = 0x0002;
const int CS_OWNDC = 0x0020;
const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
const int SW_SHOW = 5;
const int WM_DESTROY = 0x0002;
const int WM_SIZE = 0x0005;
const int WM_PAINT = 0x000F;
const int WM_CLOSE = 0x0010;
const int WM_QUIT = 0x0012;
const int WM_ERASEBKGND = 0x0014;
const int PM_REMOVE = 0x0001;
const int HEAP_ZERO_MEMORY = 0x00000008;

// ============================================================
// CONSTANTES DIRECT2D
// ============================================================
const int D2D1_FACTORY_TYPE_SINGLE_THREADED = 0;
const int D2D1_RENDER_TARGET_TYPE_DEFAULT = 0;
const int D2D1_RENDER_TARGET_USAGE_NONE = 0;
const int D2D1_FEATURE_LEVEL_DEFAULT = 0;
const int DXGI_FORMAT_B8G8R8A8_UNORM = 87;
const int D2D1_ALPHA_MODE_UNKNOWN = 0;
const int D2D1_ALPHA_MODE_PREMULTIPLIED = 1;
const int D2D1_ALPHA_MODE_IGNORE = 3;

// ============================================================
// ESTRUTURAS WIN32
// ============================================================
typedef WndProcNative = IntPtr Function(Pointer<Void> hwnd, Uint32 message, UintPtr wParam, IntPtr lParam);

final class WNDCLASSW extends Struct {
  @Uint32()
  external int style;
  external Pointer<NativeFunction<WndProcNative>> lpfnWndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  external Pointer<Void> hInstance;
  external Pointer<Void> hIcon;
  external Pointer<Void> hCursor;
  external Pointer<Void> hbrBackground;
  external Pointer<Uint16> lpszMenuName;
  external Pointer<Uint16> lpszClassName;
}

final class MSG extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int message;
  external Pointer<Void> wParam;
  external Pointer<Void> lParam;
  @Uint32()
  external int time;
  @Int32()
  external int ptX;
  @Int32()
  external int ptY;
  @Uint32()
  external int lPrivate;
}

final class RECT extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class GUID extends Struct {
  @Uint32()
  external int Data1;
  @Uint16()
  external int Data2;
  @Uint16()
  external int Data3;
  @Uint8()
  external int Data4_1;
  @Uint8()
  external int Data4_2;
  @Uint8()
  external int Data4_3;
  @Uint8()
  external int Data4_4;
  @Uint8()
  external int Data4_5;
  @Uint8()
  external int Data4_6;
  @Uint8()
  external int Data4_7;
  @Uint8()
  external int Data4_8;
}

// ============================================================
// ESTRUTURAS DIRECT2D
// ============================================================
final class D2D1_PIXEL_FORMAT extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int alphaMode;
}

final class D2D1_RENDER_TARGET_PROPERTIES extends Struct {
  @Uint32()
  external int type;
  external D2D1_PIXEL_FORMAT pixelFormat;
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
  @Uint32()
  external int usage;
  @Uint32()
  external int minLevel;
}

final class D2D1_SIZE_U extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
}

final class D2D1_HWND_RENDER_TARGET_PROPERTIES extends Struct {
  external Pointer<Void> hwnd;
  external D2D1_SIZE_U pixelSize;
  @Uint32()
  external int presentOptions;
}

final class D2D1_COLOR_F extends Struct {
  @Float()
  external double r;
  @Float()
  external double g;
  @Float()
  external double b;
  @Float()
  external double a;
}

final class D2D1_RECT_F extends Struct {
  @Float()
  external double left;
  @Float()
  external double top;
  @Float()
  external double right;
  @Float()
  external double bottom;
}

// ------------------------------------------------------------
// ID2D1Bitmap
// ------------------------------------------------------------
final class ID2D1Bitmap extends Struct {
  external Pointer<ID2D1BitmapVtbl> lpVtbl;
}

final class ID2D1BitmapVtbl extends Struct {
  @Array(2)
  external Array<Pointer<Void>> padding1;
  external Pointer<NativeFunction<Uint32 Function(Pointer<ID2D1Bitmap> self)>> Release;
}

final class D2D1_BITMAP_PROPERTIES extends Struct {
  external D2D1_PIXEL_FORMAT pixelFormat;
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
}

// ------------------------------------------------------------
// ID2D1SolidColorBrush
// ------------------------------------------------------------
final class ID2D1SolidColorBrush extends Struct {
  external Pointer<ID2D1SolidColorBrushVtbl> lpVtbl;
}

final class ID2D1SolidColorBrushVtbl extends Struct {
  @Array(8)
  external Array<Pointer<Void>> padding1;
}

// ------------------------------------------------------------
// ID2D1HwndRenderTarget
// ------------------------------------------------------------
final class ID2D1HwndRenderTarget extends Struct {
  external Pointer<ID2D1HwndRenderTargetVtbl> lpVtbl;
}

final class ID2D1HwndRenderTargetVtbl extends Struct {
  @Array(4)
  external Array<Pointer<Void>> paddingToCreateBitmap;

  // 4
  external Pointer<
      NativeFunction<
          Int32 Function(
            Pointer<ID2D1HwndRenderTarget> self,
            D2D1_SIZE_U size,
            Pointer<Void> srcData,
            Uint32 pitch,
            Pointer<D2D1_BITMAP_PROPERTIES> bitmapProperties,
            Pointer<Pointer<ID2D1Bitmap>> bitmap,
          )>> CreateBitmap;

  @Array(3)
  external Array<Pointer<Void>> paddingToCreateSolidColorBrush;

  // 8
  external Pointer<
      NativeFunction<
          Int32 Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<D2D1_COLOR_F> color,
            Pointer<Pointer<Void>> brushProperties,
            Pointer<Pointer<ID2D1SolidColorBrush>> solidColorBrush,
          )>> CreateSolidColorBrush;

  @Array(8)
  external Array<Pointer<Void>> paddingToFillRectangle;

  // 17
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<D2D1_RECT_F> rect,
            Pointer<ID2D1SolidColorBrush> brush,
          )>> FillRectangle;

  @Array(7)
  external Array<Pointer<Void>> paddingToFillOpacityMask;

  // 25
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<ID2D1Bitmap> opacityMask,
            Pointer<ID2D1SolidColorBrush> brush,
            Uint32 content,
            Pointer<D2D1_RECT_F> destinationRectangle,
            Pointer<D2D1_RECT_F> sourceRectangle,
          )>> FillOpacityMask;

  // 26
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<ID2D1Bitmap> bitmap,
            Pointer<D2D1_RECT_F> destinationRectangle,
            Float opacity,
            Uint32 interpolationMode,
            Pointer<D2D1_RECT_F> sourceRectangle,
          )>> DrawBitmap;

  @Array(5)
  external Array<Pointer<Void>> paddingToSetAntialiasMode;

  // 32
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Uint32 antialiasMode,
          )>> SetAntialiasMode;

  @Array(14)
  external Array<Pointer<Void>> paddingToClear;

  // 47
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<D2D1_COLOR_F> clearColor,
          )>> Clear;

  // 48
  external Pointer<
      NativeFunction<
          Void Function(
            Pointer<ID2D1HwndRenderTarget> self,
          )>> BeginDraw;

  // 49
  external Pointer<
      NativeFunction<
          Int32 Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<Uint64> tag1,
            Pointer<Uint64> tag2,
          )>> EndDraw;

  @Array(8)
  external Array<Pointer<Void>> paddingToResize;

  // 58
  external Pointer<
      NativeFunction<
          Int32 Function(
            Pointer<ID2D1HwndRenderTarget> self,
            Pointer<D2D1_SIZE_U> pixelSize,
          )>> Resize;
}

// ------------------------------------------------------------
// ID2D1Factory
// ------------------------------------------------------------
final class ID2D1Factory extends Struct {
  external Pointer<ID2D1FactoryVtbl> lpVtbl;
}

final class ID2D1FactoryVtbl extends Struct {
  @Array(14)
  external Array<Pointer<Void>> padding1;

  // 14
  external Pointer<
      NativeFunction<
          Int32 Function(
            Pointer<ID2D1Factory> self,
            Pointer<D2D1_RENDER_TARGET_PROPERTIES> renderTargetProperties,
            Pointer<D2D1_HWND_RENDER_TARGET_PROPERTIES> hwndRenderTargetProperties,
            Pointer<Pointer<ID2D1HwndRenderTarget>> hwndRenderTarget,
          )>> CreateHwndRenderTarget;
}

// ============================================================
// DLLs E FUNÇÕES
// ============================================================
final kernel32 = DynamicLibrary.open('kernel32.dll');
final user32 = DynamicLibrary.open('user32.dll');
final d2d1 = DynamicLibrary.open('d2d1.dll');

final getProcessHeap = kernel32.lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
final heapAlloc = kernel32.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr), Pointer<Void> Function(int, int, int)>('HeapAlloc');
final heapFree = kernel32.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>), int Function(int, int, Pointer<Void>)>('HeapFree');

final registerClassW = user32.lookupFunction<Uint16 Function(Pointer<WNDCLASSW>), int Function(Pointer<WNDCLASSW>)>('RegisterClassW');
final createWindowExW = user32.lookupFunction<Pointer<Void> Function(Uint32, Pointer<Uint16>, Pointer<Uint16>, Uint32, Int32, Int32, Int32, Int32, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>), Pointer<Void> Function(int, Pointer<Uint16>, Pointer<Uint16>, int, int, int, int, int, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)>('CreateWindowExW');
final defWindowProcW = user32.lookupFunction<IntPtr Function(Pointer<Void>, Uint32, UintPtr, IntPtr), int Function(Pointer<Void>, int, int, int)>('DefWindowProcW');
final showWindow = user32.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('ShowWindow');
final getMessageW = user32.lookupFunction<Int32 Function(Pointer<MSG>, Pointer<Void>, Uint32, Uint32), int Function(Pointer<MSG>, Pointer<Void>, int, int)>('GetMessageW');
final peekMessageW = user32.lookupFunction<Int32 Function(Pointer<MSG>, Pointer<Void>, Uint32, Uint32, Uint32), int Function(Pointer<MSG>, Pointer<Void>, int, int, int)>('PeekMessageW');
final translateMessage = user32.lookupFunction<Int32 Function(Pointer<MSG>), int Function(Pointer<MSG>)>('TranslateMessage');
final dispatchMessageW = user32.lookupFunction<IntPtr Function(Pointer<MSG>), int Function(Pointer<MSG>)>('DispatchMessageW');
final getClientRect = user32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<RECT>), int Function(Pointer<Void>, Pointer<RECT>)>('GetClientRect');
final postQuitMessage = user32.lookupFunction<Void Function(Int32), void Function(int)>('PostQuitMessage');
final destroyWindow = user32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('DestroyWindow');
final validateRect = user32.lookupFunction<Int32 Function(Pointer<Void>, Pointer<RECT>), int Function(Pointer<Void>, Pointer<RECT>)>('ValidateRect');

final d2d1CreateFactory = d2d1.lookupFunction<
    Int32 Function(Uint32, Pointer<GUID>, Pointer<Void>, Pointer<Pointer<ID2D1Factory>>),
    int Function(int, Pointer<GUID>, Pointer<Void>, Pointer<Pointer<ID2D1Factory>>)
>('D2D1CreateFactory');

// Helpers
Pointer<Void> allocNative(int bytes) {
  final processHeap = getProcessHeap();
  return heapAlloc(processHeap, HEAP_ZERO_MEMORY, bytes);
}

void freeNative(Pointer<Void> p) {
  if (p.address != 0) {
    heapFree(getProcessHeap(), 0, p);
  }
}

Pointer<Uint16> wideString(String value) {
  final units = value.codeUnits;
  final p = allocNative((units.length + 1) * sizeOf<Uint16>()).cast<Uint16>();
  final list = p.asTypedList(units.length + 1);
  list.setAll(0, units);
  list[units.length] = 0;
  return p;
}

Pointer<GUID> createGUID(int d1, int d2, int d3, List<int> d4) {
  final p = allocNative(sizeOf<GUID>()).cast<GUID>();
  p.ref.Data1 = d1;
  p.ref.Data2 = d2;
  p.ref.Data3 = d3;
  p.ref.Data4_1 = d4[0];
  p.ref.Data4_2 = d4[1];
  p.ref.Data4_3 = d4[2];
  p.ref.Data4_4 = d4[3];
  p.ref.Data4_5 = d4[4];
  p.ref.Data4_6 = d4[5];
  p.ref.Data4_7 = d4[6];
  p.ref.Data4_8 = d4[7];
  return p;
}

// ============================================================
// RENDERIZAÇÃO
// ============================================================
Pointer<ID2D1HwndRenderTarget>? g_pRT;
Pointer<ID2D1SolidColorBrush>? g_pBrush;
Pointer<ID2D1SolidColorBrush>? g_pWhiteBrush;
Pointer<ID2D1Bitmap>? g_pBitmap;
Pointer<D2D1_COLOR_F>? g_clearColor;
Pointer<D2D1_RECT_F>? g_drawRect;
Pointer<RECT>? g_rect;
Pointer<D2D1_SIZE_U>? g_newSize;

void render(Pointer<Void> hwnd) {
  try {
    if (g_pRT == null || g_rect == null || g_newSize == null || g_clearColor == null || g_drawRect == null) return;
    final pRT = g_pRT!;
    
    getClientRect(hwnd, g_rect!);
    g_newSize!.ref.width = g_rect!.ref.right - g_rect!.ref.left;
    g_newSize!.ref.height = g_rect!.ref.bottom - g_rect!.ref.top;

    final resize = pRT.ref.lpVtbl.ref.Resize.asFunction<int Function(Pointer<ID2D1HwndRenderTarget>, Pointer<D2D1_SIZE_U>)>();
    resize(pRT, g_newSize!);

    final beginDraw = pRT.ref.lpVtbl.ref.BeginDraw.asFunction<void Function(Pointer<ID2D1HwndRenderTarget>)>();
    beginDraw(pRT);

    final clear = pRT.ref.lpVtbl.ref.Clear.asFunction<void Function(Pointer<ID2D1HwndRenderTarget>, Pointer<D2D1_COLOR_F>)>();
    clear(pRT, g_clearColor!);

    if (g_pBrush != null) {
      g_drawRect!.ref.left = g_newSize!.ref.width / 2 - 200;
      g_drawRect!.ref.top = g_newSize!.ref.height / 2 - 200;
      g_drawRect!.ref.right = g_newSize!.ref.width / 2 + 200;
      g_drawRect!.ref.bottom = g_newSize!.ref.height / 2 + 200;
      final fillRectangle = pRT.ref.lpVtbl.ref.FillRectangle.asFunction<void Function(Pointer<ID2D1HwndRenderTarget>, Pointer<D2D1_RECT_F>, Pointer<ID2D1SolidColorBrush>)>();
      fillRectangle(pRT, g_drawRect!, g_pBrush!);
    }

    if (g_pBitmap != null) {
      g_drawRect!.ref.left = g_newSize!.ref.width / 2 - 150;
      g_drawRect!.ref.top = g_newSize!.ref.height / 2 - 150;
      g_drawRect!.ref.right = g_newSize!.ref.width / 2 + 150;
      g_drawRect!.ref.bottom = g_newSize!.ref.height / 2 + 150;
      
      final drawBitmap = pRT.ref.lpVtbl.ref.DrawBitmap.asFunction<void Function(Pointer<ID2D1HwndRenderTarget>, Pointer<ID2D1Bitmap>, Pointer<D2D1_RECT_F>, double, int, Pointer<D2D1_RECT_F>)>();
      
      // 0 = D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR
      drawBitmap(pRT, g_pBitmap!, g_drawRect!, 1.0, 0, nullptr);
    }

    final endDraw = pRT.ref.lpVtbl.ref.EndDraw.asFunction<int Function(Pointer<ID2D1HwndRenderTarget>, Pointer<Uint64>, Pointer<Uint64>)>();
    int hr = endDraw(pRT, nullptr, nullptr);
    if (hr != 0) {
      print('EndDraw failed: 0x${hr.toRadixString(16)}');
    }
  } catch (e, stack) {
    print('Exception in render: $e\n$stack');
  }
}

int mainWindowProc(Pointer<Void> hwnd, int uMsg, int wParam, int lParam) {
  try {
    if (uMsg == WM_DESTROY) {
      postQuitMessage(0);
      return 0;
    } else if (uMsg == WM_PAINT || uMsg == WM_SIZE) {
      render(hwnd);
      if (uMsg == WM_PAINT) {
        validateRect(hwnd, nullptr);
      }
      return 0;
    } else if (uMsg == WM_ERASEBKGND) {
      return 1;
    }
  } catch (e, stack) {
    print('Exception in proc: $e\n$stack');
  }
  return defWindowProcW(hwnd, uMsg, wParam, lParam);
}

// ============================================================
// MAIN
// ============================================================
void main() {
  // Configurar Janela
  final className = wideString('DartUI_Direct2D_Class');
  final windowName = wideString('Dart + Direct2D Puro FFI');

  final wc = allocNative(sizeOf<WNDCLASSW>()).cast<WNDCLASSW>();
  wc.ref.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
  wc.ref.lpfnWndProc = Pointer.fromFunction<WndProcNative>(mainWindowProc, 0);
  wc.ref.lpszClassName = className;

  if (registerClassW(wc) == 0) {
    print('Erro RegisterClassW');
    return;
  }

  final hwnd = createWindowExW(
    0,
    className,
    windowName,
    WS_OVERLAPPEDWINDOW,
    100,
    100,
    800,
    600,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
  );

  if (hwnd == nullptr) {
    print('Erro CreateWindowExW');
    return;
  }

  // ------------------------------------------------------------
  // INICIALIZAR DIRECT2D
  // ------------------------------------------------------------
  final riid = createGUID(0x06152247, 0x6F50, 0x465A, [0x92, 0x45, 0x11, 0x8B, 0xFD, 0x3B, 0x60, 0x07]);
  final ppFactory = allocNative(sizeOf<Pointer<ID2D1Factory>>()).cast<Pointer<ID2D1Factory>>();
  
  final hr = d2d1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, riid, nullptr, ppFactory);
  if (hr != 0 || ppFactory.value == nullptr) {
    print('Erro ao criar ID2D1Factory: $hr');
    return;
  }
  
  final pFactory = ppFactory.value;
  print('Direct2D Factory criado com sucesso!');

  // Criar HwndRenderTarget
  final renderTargetProps = allocNative(sizeOf<D2D1_RENDER_TARGET_PROPERTIES>()).cast<D2D1_RENDER_TARGET_PROPERTIES>();
  renderTargetProps.ref.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
  renderTargetProps.ref.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
  renderTargetProps.ref.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
  renderTargetProps.ref.dpiX = 0.0;
  renderTargetProps.ref.dpiY = 0.0;
  renderTargetProps.ref.usage = D2D1_RENDER_TARGET_USAGE_NONE;
  renderTargetProps.ref.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;

  final hwndProps = allocNative(sizeOf<D2D1_HWND_RENDER_TARGET_PROPERTIES>()).cast<D2D1_HWND_RENDER_TARGET_PROPERTIES>();
  hwndProps.ref.hwnd = hwnd;
  hwndProps.ref.pixelSize.width = 800;
  hwndProps.ref.pixelSize.height = 600;
  hwndProps.ref.presentOptions = 0;
  
  final ppHwndRenderTarget = allocNative(sizeOf<Pointer<ID2D1HwndRenderTarget>>()).cast<Pointer<ID2D1HwndRenderTarget>>();
  
  final createHwndRenderTarget = pFactory.ref.lpVtbl.ref.CreateHwndRenderTarget.asFunction<
      int Function(
        Pointer<ID2D1Factory>,
        Pointer<D2D1_RENDER_TARGET_PROPERTIES>,
        Pointer<D2D1_HWND_RENDER_TARGET_PROPERTIES>,
        Pointer<Pointer<ID2D1HwndRenderTarget>>
      )>();

  final hrRt = createHwndRenderTarget(pFactory, renderTargetProps, hwndProps, ppHwndRenderTarget);
  if (hrRt != 0 || ppHwndRenderTarget.value == nullptr) {
    print('Erro ao criar HwndRenderTarget: $hrRt');
    return;
  }
  
  g_pRT = ppHwndRenderTarget.value;
  print('ID2D1HwndRenderTarget criado!');
  
  // Variáveis globais para o renderizador
  g_rect = allocNative(sizeOf<RECT>()).cast<RECT>();
  g_newSize = allocNative(sizeOf<D2D1_SIZE_U>()).cast<D2D1_SIZE_U>();
  g_drawRect = allocNative(sizeOf<D2D1_RECT_F>()).cast<D2D1_RECT_F>();

  g_clearColor = allocNative(sizeOf<D2D1_COLOR_F>()).cast<D2D1_COLOR_F>();
  g_clearColor!.ref.r = 0.1;
  g_clearColor!.ref.g = 0.1;
  g_clearColor!.ref.b = 0.12;
  g_clearColor!.ref.a = 1.0;

  final brushColor = allocNative(sizeOf<D2D1_COLOR_F>()).cast<D2D1_COLOR_F>();
  brushColor.ref.r = 0.8;
  brushColor.ref.g = 0.2;
  brushColor.ref.b = 0.2;
  brushColor.ref.a = 1.0;

  final ppBrush = allocNative(sizeOf<Pointer<ID2D1SolidColorBrush>>()).cast<Pointer<ID2D1SolidColorBrush>>();
  final createSolidColorBrush = g_pRT!.ref.lpVtbl.ref.CreateSolidColorBrush.asFunction<
    int Function(
      Pointer<ID2D1HwndRenderTarget>,
      Pointer<D2D1_COLOR_F>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<ID2D1SolidColorBrush>>
    )>();

  createSolidColorBrush(g_pRT!, brushColor, nullptr, ppBrush);
  g_pBrush = ppBrush.value;

  final whiteColor = allocNative(sizeOf<D2D1_COLOR_F>()).cast<D2D1_COLOR_F>();
  whiteColor.ref.r = 1.0;
  whiteColor.ref.g = 1.0;
  whiteColor.ref.b = 1.0;
  whiteColor.ref.a = 1.0;

  final ppWhiteBrush = allocNative(sizeOf<Pointer<ID2D1SolidColorBrush>>()).cast<Pointer<ID2D1SolidColorBrush>>();
  createSolidColorBrush(g_pRT!, whiteColor, nullptr, ppWhiteBrush);
  g_pWhiteBrush = ppWhiteBrush.value;

  // Letra A em Bitmap 8x8 (agora em RGBA para usar Nearest Neighbor)
  const fontRows = <int>[
    0x18, // 0b00011000
    0x24, // 0b00100100
    0x42, // 0b01000010
    0x42, // 0b01000010
    0x7E, // 0b01111110
    0x42, // 0b01000010
    0x42, // 0b01000010
    0x42, // 0b01000010
  ];
  final fontPixels = allocNative(8 * 8 * 4).cast<Uint32>();
  for (var y = 0; y < 8; y++) {
    final row = fontRows[y];
    for (var x = 0; x < 8; x++) {
      final bit = (row >> (7 - x)) & 1;
      fontPixels[y * 8 + x] = bit != 0 ? 0xFFFFFFFF : 0x00000000;
    }
  }

  final bitmapSize = allocNative(sizeOf<D2D1_SIZE_U>()).cast<D2D1_SIZE_U>();
  bitmapSize.ref.width = 8;
  bitmapSize.ref.height = 8;

  final bitmapProps = allocNative(sizeOf<D2D1_BITMAP_PROPERTIES>()).cast<D2D1_BITMAP_PROPERTIES>();
  bitmapProps.ref.pixelFormat.format = 87; // DXGI_FORMAT_B8G8R8A8_UNORM
  bitmapProps.ref.pixelFormat.alphaMode = 1; // D2D1_ALPHA_MODE_PREMULTIPLIED
  bitmapProps.ref.dpiX = 96.0;
  bitmapProps.ref.dpiY = 96.0;

  final ppBitmap = allocNative(sizeOf<Pointer<ID2D1Bitmap>>()).cast<Pointer<ID2D1Bitmap>>();
  final createBitmap = g_pRT!.ref.lpVtbl.ref.CreateBitmap.asFunction<
      int Function(
        Pointer<ID2D1HwndRenderTarget>,
        D2D1_SIZE_U,
        Pointer<Void>,
        int,
        Pointer<D2D1_BITMAP_PROPERTIES>,
        Pointer<Pointer<ID2D1Bitmap>>
      )>();

  final hrBitmap = createBitmap(g_pRT!, bitmapSize.ref, fontPixels.cast<Void>(), 8 * 4, bitmapProps, ppBitmap);
  if (hrBitmap != 0 || ppBitmap.value == nullptr) {
    print('Erro ao criar Bitmap: $hrBitmap');
  } else {
    g_pBitmap = ppBitmap.value;
  }

  // Loop de eventos Win32
  showWindow(hwnd, SW_SHOW);

  final msg = allocNative(sizeOf<MSG>()).cast<MSG>();
  var running = true;
  var dirty = true;

  while (running) {
    if (dirty) {
      render(hwnd);
      dirty = false;
    }

    final result = getMessageW(msg, nullptr, 0, 0);
    if (result == 0) {
      running = false;
      break;
    } else if (result > 0) {
      translateMessage(msg);
      dispatchMessageW(msg);
      dirty = true;

      while (peekMessageW(msg, nullptr, 0, 0, PM_REMOVE) != 0) {
        if (msg.ref.message == WM_QUIT) {
          running = false;
          break;
        }
        translateMessage(msg);
        dispatchMessageW(msg);
      }
    }
  }

  // Cleanup
  freeNative(brushColor.cast());
  freeNative(whiteColor.cast());
  freeNative(ppWhiteBrush.cast());
  freeNative(fontPixels.cast());
  freeNative(bitmapSize.cast());
  freeNative(bitmapProps.cast());
  freeNative(ppBitmap.cast());
  freeNative(g_rect!.cast());
  freeNative(g_newSize!.cast());
  freeNative(g_drawRect!.cast());
  freeNative(g_clearColor!.cast());
  freeNative(msg.cast());
  freeNative(ppFactory.cast());
  freeNative(renderTargetProps.cast());
  freeNative(hwndProps.cast());
  freeNative(ppHwndRenderTarget.cast());
  freeNative(ppBrush.cast());
  freeNative(riid.cast());
  freeNative(wc.cast());
  freeNative(className.cast());
  freeNative(windowName.cast());
  
  destroyWindow(hwnd);
}
