import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

// ============================================================
// CONSTANTES WIN32
// ============================================================

const int CS_VREDRAW = 0x0001;
const int CS_HREDRAW = 0x0002;
const int CS_OWNDC = 0x0020;

const int WS_OVERLAPPEDWINDOW = 0x00CF0000;
const int WS_CLIPCHILDREN = 0x02000000;
const int WS_CLIPSIBLINGS = 0x04000000;

const int SW_SHOW = 5;

const int WM_DESTROY = 0x0002;
const int WM_CLOSE = 0x0010;
const int WM_QUIT = 0x0012;

const int PM_REMOVE = 0x0001;

const int PFD_DOUBLEBUFFER = 0x00000001;
const int PFD_DRAW_TO_WINDOW = 0x00000004;
const int PFD_SUPPORT_OPENGL = 0x00000020;

const int PFD_TYPE_RGBA = 0;
const int PFD_MAIN_PLANE = 0;

// HeapAlloc
const int HEAP_ZERO_MEMORY = 0x00000008;

// ============================================================
// CONSTANTES WGL
// ============================================================

const int WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const int WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const int WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;

const int WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;

// ============================================================
// CONSTANTES OPENGL
// ============================================================

const int GL_VERSION = 0x1F02;
const int GL_VENDOR = 0x1F00;
const int GL_RENDERER = 0x1F01;

const int GL_COLOR_BUFFER_BIT = 0x00004000;

const int GL_ARRAY_BUFFER = 0x8892;
const int GL_STATIC_DRAW = 0x88E4;

const int GL_FLOAT = 0x1406;

const int GL_VERTEX_SHADER = 0x8B31;
const int GL_FRAGMENT_SHADER = 0x8B30;

const int GL_COMPILE_STATUS = 0x8B81;
const int GL_LINK_STATUS = 0x8B82;
const int GL_INFO_LOG_LENGTH = 0x8B84;

const int GL_TEXTURE_2D = 0x0DE1;
const int GL_TEXTURE0 = 0x84C0;

const int GL_TEXTURE_MIN_FILTER = 0x2801;
const int GL_TEXTURE_MAG_FILTER = 0x2800;
const int GL_TEXTURE_WRAP_S = 0x2802;
const int GL_TEXTURE_WRAP_T = 0x2803;

const int GL_NEAREST = 0x2600;
const int GL_CLAMP_TO_EDGE = 0x812F;

const int GL_R8 = 0x8229;
const int GL_RED = 0x1903;
const int GL_UNSIGNED_BYTE = 0x1401;

const int GL_UNPACK_ALIGNMENT = 0x0CF5;

const int GL_TRIANGLES = 0x0004;

// ============================================================
// ESTRUTURAS WIN32
// ============================================================

typedef WndProcNative = IntPtr Function(
  Pointer<Void> hwnd,
  Uint32 message,
  UintPtr wParam,
  IntPtr lParam,
);

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

final class PIXELFORMATDESCRIPTOR extends Struct {
  @Uint16()
  external int nSize;

  @Uint16()
  external int nVersion;

  @Uint32()
  external int dwFlags;

  @Uint8()
  external int iPixelType;

  @Uint8()
  external int cColorBits;

  @Uint8()
  external int cRedBits;

  @Uint8()
  external int cRedShift;

  @Uint8()
  external int cGreenBits;

  @Uint8()
  external int cGreenShift;

  @Uint8()
  external int cBlueBits;

  @Uint8()
  external int cBlueShift;

  @Uint8()
  external int cAlphaBits;

  @Uint8()
  external int cAlphaShift;

  @Uint8()
  external int cAccumBits;

  @Uint8()
  external int cAccumRedBits;

  @Uint8()
  external int cAccumGreenBits;

  @Uint8()
  external int cAccumBlueBits;

  @Uint8()
  external int cAccumAlphaBits;

  @Uint8()
  external int cDepthBits;

  @Uint8()
  external int cStencilBits;

  @Uint8()
  external int cAuxBuffers;

  @Uint8()
  external int iLayerType;

  @Uint8()
  external int bReserved;

  @Uint32()
  external int dwLayerMask;

  @Uint32()
  external int dwVisibleMask;

  @Uint32()
  external int dwDamageMask;
}

final class MSG extends Struct {
  external Pointer<Void> hwnd;

  @Uint32()
  external int message;

  // WPARAM - 64 bits no Windows x64
  external Pointer<Void> wParam;

  // LPARAM - 64 bits no Windows x64
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

// ============================================================
// DLLs
// ============================================================

final DynamicLibrary kernel32 =
    DynamicLibrary.open('kernel32.dll');

final DynamicLibrary user32 =
    DynamicLibrary.open('user32.dll');

final DynamicLibrary gdi32 =
    DynamicLibrary.open('gdi32.dll');

final DynamicLibrary opengl32 =
    DynamicLibrary.open('opengl32.dll');

// ============================================================
// KERNEL32
// ============================================================

final getProcessHeap = kernel32.lookupFunction<
    Pointer<Void> Function(),
    Pointer<Void> Function()>('GetProcessHeap');

final heapAlloc = kernel32.lookupFunction<
    Pointer<Void> Function(
      Pointer<Void>,
      Uint32,
      UintPtr,
    ),
    Pointer<Void> Function(
      Pointer<Void>,
      int,
      int,
    )>('HeapAlloc');

final heapFree = kernel32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Uint32,
      Pointer<Void>,
    ),
    int Function(
      Pointer<Void>,
      int,
      Pointer<Void>,
    )>('HeapFree');

final getModuleHandleW = kernel32.lookupFunction<
    Pointer<Void> Function(Pointer<Uint16>),
    Pointer<Void> Function(Pointer<Uint16>)>(
  'GetModuleHandleW',
);

final getLastError = kernel32.lookupFunction<
    Uint32 Function(),
    int Function()>('GetLastError');

final Pointer<Void> processHeap = getProcessHeap();

// ============================================================
// USER32
// ============================================================

final registerClassW = user32.lookupFunction<
    Uint16 Function(Pointer<WNDCLASSW>),
    int Function(Pointer<WNDCLASSW>)>(
  'RegisterClassW',
);

final createWindowExW = user32.lookupFunction<
    Pointer<Void> Function(
      Uint32,
      Pointer<Uint16>,
      Pointer<Uint16>,
      Uint32,
      Int32,
      Int32,
      Int32,
      Int32,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    ),
    Pointer<Void> Function(
      int,
      Pointer<Uint16>,
      Pointer<Uint16>,
      int,
      int,
      int,
      int,
      int,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
    )>(
  'CreateWindowExW',
);

final defWindowProcW = user32.lookupFunction<
    IntPtr Function(
      Pointer<Void>,
      Uint32,
      UintPtr,
      IntPtr,
    ),
    int Function(
      Pointer<Void>,
      int,
      int,
      int,
    )>(
  'DefWindowProcW',
);

final showWindow = user32.lookupFunction<
    Int32 Function(Pointer<Void>, Int32),
    int Function(Pointer<Void>, int)>(
  'ShowWindow',
);

final getDC = user32.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)>(
  'GetDC',
);

final releaseDC = user32.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Void>),
    int Function(Pointer<Void>, Pointer<Void>)>(
  'ReleaseDC',
);

final destroyWindow = user32.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>(
  'DestroyWindow',
);

final peekMessageW = user32.lookupFunction<
    Int32 Function(
      Pointer<MSG>,
      Pointer<Void>,
      Uint32,
      Uint32,
      Uint32,
    ),
    int Function(
      Pointer<MSG>,
      Pointer<Void>,
      int,
      int,
      int,
    )>(
  'PeekMessageW',
);

final getMessageW = user32.lookupFunction<
    Int32 Function(
      Pointer<MSG>,
      Pointer<Void>,
      Uint32,
      Uint32,
    ),
    int Function(
      Pointer<MSG>,
      Pointer<Void>,
      int,
      int,
    )>(
  'GetMessageW',
);

final translateMessage = user32.lookupFunction<
    Int32 Function(Pointer<MSG>),
    int Function(Pointer<MSG>)>(
  'TranslateMessage',
);

final dispatchMessageW = user32.lookupFunction<
    IntPtr Function(Pointer<MSG>),
    int Function(Pointer<MSG>)>(
  'DispatchMessageW',
);

final postQuitMessage = user32.lookupFunction<
    Void Function(Int32),
    void Function(int)>(
  'PostQuitMessage',
);

final getClientRect = user32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<RECT>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<RECT>,
    )>(
  'GetClientRect',
);

// ============================================================
// GDI32
// ============================================================

final choosePixelFormat = gdi32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<PIXELFORMATDESCRIPTOR>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<PIXELFORMATDESCRIPTOR>,
    )>(
  'ChoosePixelFormat',
);

final setPixelFormat = gdi32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<PIXELFORMATDESCRIPTOR>,
    ),
    int Function(
      Pointer<Void>,
      int,
      Pointer<PIXELFORMATDESCRIPTOR>,
    )>(
  'SetPixelFormat',
);

final swapBuffers = gdi32.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>(
  'SwapBuffers',
);

// ============================================================
// WGL
// ============================================================

final wglCreateContext = opengl32.lookupFunction<
    Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)>(
  'wglCreateContext',
);

final wglMakeCurrent = opengl32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Void>,
    )>(
  'wglMakeCurrent',
);

final wglDeleteContext = opengl32.lookupFunction<
    Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>(
  'wglDeleteContext',
);

final wglGetProcAddress = opengl32.lookupFunction<
    Pointer<Void> Function(Pointer<Int8>),
    Pointer<Void> Function(Pointer<Int8>)>(
  'wglGetProcAddress',
);

// ============================================================
// MEMÓRIA NATIVA
// sem package:ffi
// ============================================================

Pointer<Void> allocNative(int bytes) {
  final p = heapAlloc(
    processHeap,
    HEAP_ZERO_MEMORY,
    bytes,
  );

  if (p.address == 0) {
    throw StateError(
      'HeapAlloc falhou para $bytes bytes',
    );
  }

  return p;
}

void freeNative(Pointer<Void> p) {
  if (p.address != 0) {
    heapFree(
      processHeap,
      0,
      p,
    );
  }
}

Pointer<Uint16> wideString(String value) {
  final units = value.codeUnits;

  final p = allocNative(
    (units.length + 1) * sizeOf<Uint16>(),
  ).cast<Uint16>();

  final list = p.asTypedList(units.length + 1);

  list.setAll(0, units);
  list[units.length] = 0;

  return p;
}

Pointer<Int8> utf8String(String value) {
  final bytes = utf8.encode(value);

  final p = allocNative(
    bytes.length + 1,
  ).cast<Uint8>();

  final list = p.asTypedList(bytes.length + 1);

  list.setAll(0, bytes);
  list[bytes.length] = 0;

  return p.cast<Int8>();
}

String nativeUtf8(
  Pointer<Uint8> p, {
  int maxLength = 16384,
}) {
  if (p.address == 0) {
    return '';
  }

  final bytes = <int>[];

  for (var i = 0; i < maxLength; i++) {
    final value = p.elementAt(i).value;

    if (value == 0) {
      break;
    }

    bytes.add(value);
  }

  return utf8.decode(
    bytes,
    allowMalformed: true,
  );
}

// ============================================================
// CALLBACK WIN32
// ============================================================

int windowProc(
  Pointer<Void> hwnd,
  int message,
  int wParam,
  int lParam,
) {
  switch (message) {
    case WM_CLOSE:
      // Não destruímos imediatamente a janela.
      // Primeiro saímos do loop e liberamos o OpenGL.
      postQuitMessage(0);
      return 0;

    case WM_DESTROY:
      postQuitMessage(0);
      return 0;
  }

  return defWindowProcW(
    hwnd,
    message,
    wParam,
    lParam,
  );
}

final Pointer<NativeFunction<WndProcNative>> windowProcPointer =
    Pointer.fromFunction<WndProcNative>(
  windowProc,
  0,
);

// ============================================================
// LOADER OPENGL
// ============================================================

bool _validGLPointer(Pointer<Void> p) {
  final a = p.address;

  // Alguns drivers antigos retornam estes valores sentinela.
  if (a == 0 ||
      a == 1 ||
      a == 2 ||
      a == 3 ||
      a == 0xFFFFFFFF ||
      a == 0xFFFFFFFFFFFFFFFF) {
    return false;
  }

  return true;
}

Pointer<Void> getOpenGLProc(String name) {
  final namePtr = utf8String(name);

  final address = wglGetProcAddress(namePtr);

  freeNative(namePtr.cast<Void>());

  if (_validGLPointer(address)) {
    return address;
  }

  // OpenGL 1.1 e algumas funções básicas são
  // exportadas diretamente por opengl32.dll.
  try {
    return opengl32.lookup<Void>(name);
  } catch (_) {
    throw UnsupportedError(
      'Função OpenGL não encontrada: $name',
    );
  }
}

Pointer<Void> getWGLExtension(String name) {
  final namePtr = utf8String(name);

  final address = wglGetProcAddress(namePtr);

  freeNative(namePtr.cast<Void>());

  if (!_validGLPointer(address)) {
    throw UnsupportedError(
      'Extensão WGL não encontrada: $name',
    );
  }

  return address;
}

// ============================================================
// OPENGL 4.6 BINDINGS
// ============================================================

class GL {
  late final void Function(
    double,
    double,
    double,
    double,
  ) clearColor;

  late final void Function(int) clear;

  late final void Function(
    int,
    int,
    int,
    int,
  ) viewport;

  late final Pointer<Uint8> Function(int) getString;

  late final void Function(
    int,
    Pointer<Uint32>,
  ) genVertexArrays;

  late final void Function(int) bindVertexArray;

  late final void Function(
    int,
    Pointer<Uint32>,
  ) genBuffers;

  late final void Function(
    int,
    int,
  ) bindBuffer;

  late final void Function(
    int,
    int,
    Pointer<Void>,
    int,
  ) bufferData;

  late final void Function(int) enableVertexAttribArray;

  late final void Function(
    int,
    int,
    int,
    int,
    int,
    Pointer<Void>,
  ) vertexAttribPointer;

  late final int Function(int) createShader;

  late final void Function(
    int,
    int,
    Pointer<Pointer<Int8>>,
    Pointer<Int32>,
  ) shaderSource;

  late final void Function(int) compileShader;

  late final void Function(
    int,
    int,
    Pointer<Int32>,
  ) getShaderiv;

  late final void Function(
    int,
    int,
    Pointer<Int32>,
    Pointer<Int8>,
  ) getShaderInfoLog;

  late final void Function(int) deleteShader;

  late final int Function() createProgram;

  late final void Function(
    int,
    int,
  ) attachShader;

  late final void Function(int) linkProgram;

  late final void Function(
    int,
    int,
    Pointer<Int32>,
  ) getProgramiv;

  late final void Function(
    int,
    int,
    Pointer<Int32>,
    Pointer<Int8>,
  ) getProgramInfoLog;

  late final void Function(int) useProgram;

  late final void Function(
    int,
    Pointer<Uint32>,
  ) genTextures;

  late final void Function(
    int,
    int,
  ) bindTexture;

  late final void Function(
    int,
    int,
    int,
  ) texParameteri;

  late final void Function(
    int,
    int,
  ) pixelStorei;

  late final void Function(
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    int,
    Pointer<Void>,
  ) texImage2D;

  late final void Function(int) activeTexture;

  late final void Function(
    int,
    int,
    int,
  ) drawArrays;

  GL() {
    clearColor = getOpenGLProc('glClearColor')
        .cast<
            NativeFunction<
                Void Function(
                  Float,
                  Float,
                  Float,
                  Float,
                )>>()
        .asFunction();

    clear = getOpenGLProc('glClear')
        .cast<
            NativeFunction<
                Void Function(Uint32)>>()
        .asFunction();

    viewport = getOpenGLProc('glViewport')
        .cast<
            NativeFunction<
                Void Function(
                  Int32,
                  Int32,
                  Int32,
                  Int32,
                )>>()
        .asFunction();

    getString = getOpenGLProc('glGetString')
        .cast<
            NativeFunction<
                Pointer<Uint8> Function(
                  Uint32,
                )>>()
        .asFunction();

    genVertexArrays =
        getOpenGLProc('glGenVertexArrays')
            .cast<
                NativeFunction<
                    Void Function(
                      Int32,
                      Pointer<Uint32>,
                    )>>()
            .asFunction();

    bindVertexArray =
        getOpenGLProc('glBindVertexArray')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                    )>>()
            .asFunction();

    genBuffers = getOpenGLProc('glGenBuffers')
        .cast<
            NativeFunction<
                Void Function(
                  Int32,
                  Pointer<Uint32>,
                )>>()
        .asFunction();

    bindBuffer = getOpenGLProc('glBindBuffer')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Uint32,
                )>>()
        .asFunction();

    bufferData = getOpenGLProc('glBufferData')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  IntPtr,
                  Pointer<Void>,
                  Uint32,
                )>>()
        .asFunction();

    enableVertexAttribArray =
        getOpenGLProc('glEnableVertexAttribArray')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                    )>>()
            .asFunction();

    vertexAttribPointer =
        getOpenGLProc('glVertexAttribPointer')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                      Int32,
                      Uint32,
                      Uint8,
                      Int32,
                      Pointer<Void>,
                    )>>()
            .asFunction();

    createShader = getOpenGLProc('glCreateShader')
        .cast<
            NativeFunction<
                Uint32 Function(
                  Uint32,
                )>>()
        .asFunction();

    shaderSource = getOpenGLProc('glShaderSource')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Int32,
                  Pointer<Pointer<Int8>>,
                  Pointer<Int32>,
                )>>()
        .asFunction();

    compileShader =
        getOpenGLProc('glCompileShader')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                    )>>()
            .asFunction();

    getShaderiv = getOpenGLProc('glGetShaderiv')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Uint32,
                  Pointer<Int32>,
                )>>()
        .asFunction();

    getShaderInfoLog =
        getOpenGLProc('glGetShaderInfoLog')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                      Int32,
                      Pointer<Int32>,
                      Pointer<Int8>,
                    )>>()
            .asFunction();

    deleteShader = getOpenGLProc('glDeleteShader')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                )>>()
        .asFunction();

    createProgram =
        getOpenGLProc('glCreateProgram')
            .cast<
                NativeFunction<
                    Uint32 Function()>>()
            .asFunction();

    attachShader = getOpenGLProc('glAttachShader')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Uint32,
                )>>()
        .asFunction();

    linkProgram = getOpenGLProc('glLinkProgram')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                )>>()
        .asFunction();

    getProgramiv =
        getOpenGLProc('glGetProgramiv')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                      Uint32,
                      Pointer<Int32>,
                    )>>()
            .asFunction();

    getProgramInfoLog =
        getOpenGLProc('glGetProgramInfoLog')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                      Int32,
                      Pointer<Int32>,
                      Pointer<Int8>,
                    )>>()
            .asFunction();

    useProgram = getOpenGLProc('glUseProgram')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                )>>()
        .asFunction();

    genTextures = getOpenGLProc('glGenTextures')
        .cast<
            NativeFunction<
                Void Function(
                  Int32,
                  Pointer<Uint32>,
                )>>()
        .asFunction();

    bindTexture = getOpenGLProc('glBindTexture')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Uint32,
                )>>()
        .asFunction();

    texParameteri =
        getOpenGLProc('glTexParameteri')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                      Uint32,
                      Int32,
                    )>>()
            .asFunction();

    pixelStorei = getOpenGLProc('glPixelStorei')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Int32,
                )>>()
        .asFunction();

    texImage2D = getOpenGLProc('glTexImage2D')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Int32,
                  Int32,
                  Int32,
                  Int32,
                  Int32,
                  Uint32,
                  Uint32,
                  Pointer<Void>,
                )>>()
        .asFunction();

    activeTexture =
        getOpenGLProc('glActiveTexture')
            .cast<
                NativeFunction<
                    Void Function(
                      Uint32,
                    )>>()
            .asFunction();

    drawArrays = getOpenGLProc('glDrawArrays')
        .cast<
            NativeFunction<
                Void Function(
                  Uint32,
                  Int32,
                  Int32,
                )>>()
        .asFunction();
  }
}

// ============================================================
// CONTEXTO OPENGL 4.6 CORE
// ============================================================

Pointer<Void> createOpenGL46Context(
  Pointer<Void> hdc,
) {
  // ----------------------------------------------------------
  // 1. Contexto antigo apenas para acessar wglGetProcAddress
  // ----------------------------------------------------------

  final legacyContext = wglCreateContext(hdc);

  if (legacyContext.address == 0) {
    throw StateError(
      'wglCreateContext falhou. '
      'GetLastError=${getLastError()}',
    );
  }

  if (wglMakeCurrent(
        hdc,
        legacyContext,
      ) ==
      0) {
    throw StateError(
      'wglMakeCurrent do contexto bootstrap falhou.',
    );
  }

  // ----------------------------------------------------------
  // 2. Obter wglCreateContextAttribsARB
  // ----------------------------------------------------------

  final createContextAddress =
      getWGLExtension(
    'wglCreateContextAttribsARB',
  );

  final createContextAttribs =
      createContextAddress
          .cast<
              NativeFunction<
                  Pointer<Void> Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Int32>,
                  )>>()
          .asFunction<
              Pointer<Void> Function(
                Pointer<Void>,
                Pointer<Void>,
                Pointer<Int32>,
              )>();

  // ----------------------------------------------------------
  // 3. Pedir exatamente OpenGL 4.6 CORE
  // ----------------------------------------------------------

  final attributes = allocNative(
    7 * sizeOf<Int32>(),
  ).cast<Int32>();

  attributes.asTypedList(7).setAll(
    0,
    const [
      WGL_CONTEXT_MAJOR_VERSION_ARB,
      4,

      WGL_CONTEXT_MINOR_VERSION_ARB,
      6,

      WGL_CONTEXT_PROFILE_MASK_ARB,
      WGL_CONTEXT_CORE_PROFILE_BIT_ARB,

      0,
    ],
  );

  final modernContext =
      createContextAttribs(
    hdc,
    nullptr,
    attributes,
  );

  freeNative(attributes.cast<Void>());

  if (modernContext.address == 0) {
    final error = getLastError();

    wglMakeCurrent(
      nullptr,
      nullptr,
    );

    wglDeleteContext(
      legacyContext,
    );

    throw UnsupportedError(
      'Não foi possível criar OpenGL 4.6 Core. '
      'GetLastError=$error\n'
      'A GPU ou o driver provavelmente não oferece '
      'um contexto OpenGL 4.6 Core.',
    );
  }

  // ----------------------------------------------------------
  // 4. Descartar bootstrap
  // ----------------------------------------------------------

  wglMakeCurrent(
    nullptr,
    nullptr,
  );

  wglDeleteContext(
    legacyContext,
  );

  // ----------------------------------------------------------
  // 5. Tornar OpenGL 4.6 atual
  // ----------------------------------------------------------

  if (wglMakeCurrent(
        hdc,
        modernContext,
      ) ==
      0) {
    throw StateError(
      'Não foi possível ativar '
      'o contexto OpenGL 4.6.',
    );
  }

  return modernContext;
}

// ============================================================
// SHADERS
// ============================================================

int compileShader(
  GL gl,
  int shaderType,
  String source,
) {
  final shader = gl.createShader(shaderType);

  if (shader == 0) {
    throw StateError(
      'glCreateShader falhou',
    );
  }

  final sourcePtr = utf8String(source);

  final sourceArray = allocNative(
    sizeOf<Pointer<Int8>>(),
  ).cast<Pointer<Int8>>();

  sourceArray.value = sourcePtr;

  gl.shaderSource(
    shader,
    1,
    sourceArray,
    nullptr.cast<Int32>(),
  );

  gl.compileShader(shader);

  freeNative(
    sourceArray.cast<Void>(),
  );

  freeNative(
    sourcePtr.cast<Void>(),
  );

  final status = allocNative(
    sizeOf<Int32>(),
  ).cast<Int32>();

  gl.getShaderiv(
    shader,
    GL_COMPILE_STATUS,
    status,
  );

  final success = status.value;

  freeNative(
    status.cast<Void>(),
  );

  if (success == 0) {
    final logLength = allocNative(
      sizeOf<Int32>(),
    ).cast<Int32>();

    gl.getShaderiv(
      shader,
      GL_INFO_LOG_LENGTH,
      logLength,
    );

    final length = logLength.value;

    freeNative(
      logLength.cast<Void>(),
    );

    final log = allocNative(
      length > 0 ? length : 1,
    ).cast<Int8>();

    gl.getShaderInfoLog(
      shader,
      length,
      nullptr.cast<Int32>(),
      log,
    );

    final message = nativeUtf8(
      log.cast<Uint8>(),
      maxLength: length > 0
          ? length
          : 1,
    );

    freeNative(
      log.cast<Void>(),
    );

    gl.deleteShader(shader);

    throw StateError(
      'Erro compilando shader:\n$message',
    );
  }

  return shader;
}

int createShaderProgram(GL gl) {
  const vertexShaderSource = '''
#version 460 core

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;

out vec2 vTexCoord;

void main() {
    vTexCoord = aTexCoord;

    gl_Position = vec4(
        aPosition,
        0.0,
        1.0
    );
}
''';

  const fragmentShaderSource = '''
#version 460 core

layout(binding = 0)
uniform sampler2D fontTexture;

in vec2 vTexCoord;

out vec4 fragColor;

void main() {
    float pixel = texture(
        fontTexture,
        vTexCoord
    ).r;

    if (pixel < 0.5) {
        discard;
    }

    fragColor = vec4(
        1.0,
        1.0,
        1.0,
        1.0
    );
}
''';

  final vertexShader = compileShader(
    gl,
    GL_VERTEX_SHADER,
    vertexShaderSource,
  );

  final fragmentShader = compileShader(
    gl,
    GL_FRAGMENT_SHADER,
    fragmentShaderSource,
  );

  final program = gl.createProgram();

  gl.attachShader(
    program,
    vertexShader,
  );

  gl.attachShader(
    program,
    fragmentShader,
  );

  gl.linkProgram(program);

  final status = allocNative(
    sizeOf<Int32>(),
  ).cast<Int32>();

  gl.getProgramiv(
    program,
    GL_LINK_STATUS,
    status,
  );

  final success = status.value;

  freeNative(
    status.cast<Void>(),
  );

  gl.deleteShader(vertexShader);
  gl.deleteShader(fragmentShader);

  if (success == 0) {
    final logLength = allocNative(
      sizeOf<Int32>(),
    ).cast<Int32>();

    gl.getProgramiv(
      program,
      GL_INFO_LOG_LENGTH,
      logLength,
    );

    final length = logLength.value;

    freeNative(
      logLength.cast<Void>(),
    );

    final log = allocNative(
      length > 0 ? length : 1,
    ).cast<Int8>();

    gl.getProgramInfoLog(
      program,
      length,
      nullptr.cast<Int32>(),
      log,
    );

    final message = nativeUtf8(
      log.cast<Uint8>(),
      maxLength: length > 0
          ? length
          : 1,
    );

    freeNative(
      log.cast<Void>(),
    );

    throw StateError(
      'Erro linkando programa:\n$message',
    );
  }

  return program;
}

// ============================================================
// BITMAP FONT 8x8
// ============================================================

Uint8List createLetterA() {
  // Cada bit representa um pixel.
  //
  //      ██
  //     █  █
  //    █    █
  //    █    █
  //    ██████
  //    █    █
  //    █    █
  //    █    █

  const rows = <int>[
    0x18, // 0b00011000
    0x24, // 0b00100100
    0x42, // 0b01000010
    0x42, // 0b01000010
    0x7E, // 0b01111110
    0x42, // 0b01000010
    0x42, // 0b01000010
    0x42, // 0b01000010
  ];

  final pixels = Uint8List(8 * 8);

  for (var y = 0; y < 8; y++) {
    final row = rows[y];

    for (var x = 0; x < 8; x++) {
      final bit =
          (row >> (7 - x)) & 1;

      pixels[y * 8 + x] =
          bit != 0 ? 255 : 0;
    }
  }

  return pixels;
}

// ============================================================
// MAIN
// ============================================================

void main() {
  if (sizeOf<IntPtr>() != 8) {
    throw UnsupportedError(
      'Este exemplo foi escrito para Windows x64.',
    );
  }

  // ----------------------------------------------------------
  // Criar classe Win32
  // ----------------------------------------------------------

  final hInstance = getModuleHandleW(
    nullptr.cast<Uint16>(),
  );

  final className = wideString(
    'DartOpenGL46Window',
  );

  final wc = allocNative(
    sizeOf<WNDCLASSW>(),
  ).cast<WNDCLASSW>();

  wc.ref.style =
      CS_HREDRAW |
      CS_VREDRAW |
      CS_OWNDC;

  wc.ref.lpfnWndProc =
      windowProcPointer;

  wc.ref.cbClsExtra = 0;
  wc.ref.cbWndExtra = 0;

  wc.ref.hInstance = hInstance;
  wc.ref.hIcon = nullptr;
  wc.ref.hCursor = nullptr;
  wc.ref.hbrBackground = nullptr;

  wc.ref.lpszMenuName =
      nullptr.cast<Uint16>();

  wc.ref.lpszClassName =
      className;

  final atom = registerClassW(wc);

  freeNative(
    wc.cast<Void>(),
  );

  if (atom == 0) {
    throw StateError(
      'RegisterClassW falhou. '
      'GetLastError=${getLastError()}',
    );
  }

  // ----------------------------------------------------------
  // Criar janela
  // ----------------------------------------------------------

  final title = wideString(
    'Dart + OpenGL 4.6 + Bitmap Font',
  );

  final hwnd = createWindowExW(
    0,
    className,
    title,
    WS_OVERLAPPEDWINDOW |
        WS_CLIPCHILDREN |
        WS_CLIPSIBLINGS,
    100,
    100,
    800,
    600,
    nullptr,
    nullptr,
    hInstance,
    nullptr,
  );

  freeNative(
    title.cast<Void>(),
  );

  freeNative(
    className.cast<Void>(),
  );

  if (hwnd.address == 0) {
    throw StateError(
      'CreateWindowExW falhou. '
      'GetLastError=${getLastError()}',
    );
  }

  // ----------------------------------------------------------
  // Device Context
  // ----------------------------------------------------------

  final hdc = getDC(hwnd);

  if (hdc.address == 0) {
    throw StateError(
      'GetDC falhou.',
    );
  }

  // ----------------------------------------------------------
  // Pixel format
  // ----------------------------------------------------------

  final pfd = allocNative(
    sizeOf<PIXELFORMATDESCRIPTOR>(),
  ).cast<PIXELFORMATDESCRIPTOR>();

  pfd.ref.nSize =
      sizeOf<PIXELFORMATDESCRIPTOR>();

  pfd.ref.nVersion = 1;

  pfd.ref.dwFlags =
      PFD_DRAW_TO_WINDOW |
      PFD_SUPPORT_OPENGL |
      PFD_DOUBLEBUFFER;

  pfd.ref.iPixelType =
      PFD_TYPE_RGBA;

  pfd.ref.cColorBits = 32;
  pfd.ref.cDepthBits = 24;
  pfd.ref.cStencilBits = 8;

  pfd.ref.iLayerType =
      PFD_MAIN_PLANE;

  final pixelFormat =
      choosePixelFormat(
    hdc,
    pfd,
  );

  if (pixelFormat == 0) {
    throw StateError(
      'ChoosePixelFormat falhou.',
    );
  }

  if (setPixelFormat(
        hdc,
        pixelFormat,
        pfd,
      ) ==
      0) {
    throw StateError(
      'SetPixelFormat falhou. '
      'GetLastError=${getLastError()}',
    );
  }

  freeNative(
    pfd.cast<Void>(),
  );

  // ----------------------------------------------------------
  // OPENGL 4.6 CORE
  // ----------------------------------------------------------

  final glContext =
      createOpenGL46Context(hdc);

  // Agora podemos carregar as funções modernas.
  final gl = GL();

  print(
    'OpenGL : '
    '${nativeUtf8(gl.getString(GL_VERSION))}',
  );

  print(
    'Vendor : '
    '${nativeUtf8(gl.getString(GL_VENDOR))}',
  );

  print(
    'GPU    : '
    '${nativeUtf8(gl.getString(GL_RENDERER))}',
  );

  // ----------------------------------------------------------
  // VSYNC
  // ----------------------------------------------------------

  try {
    final swapIntervalName = utf8String('wglSwapIntervalEXT');
    final swapIntervalAddress = wglGetProcAddress(swapIntervalName);
    
    if (swapIntervalAddress != nullptr) {
      final wglSwapIntervalEXT = swapIntervalAddress
          .cast<NativeFunction<Int32 Function(Int32)>>()
          .asFunction<int Function(int)>();

      final result = wglSwapIntervalEXT(1);

      if (result != 0) {
        print('VSync: ativado');
      } else {
        print('VSync: driver recusou');
      }
    } else {
      print('VSync: wglSwapIntervalEXT nao encontrada');
    }
    
    freeNative(swapIntervalName.cast<Void>());
  } catch (e) {
    print('VSync nao disponivel: $e');
  }

  // ----------------------------------------------------------
  // SHADERS GLSL 4.60
  // ----------------------------------------------------------

  final shaderProgram =
      createShaderProgram(gl);

  // ----------------------------------------------------------
  // QUAD
  //
  // posição X/Y + UV
  //
  // 6 vértices = 2 triângulos
  // ----------------------------------------------------------

  final vertices = Float32List.fromList([
    // x     y      u    v

    -0.30, -0.40,  0.0, 1.0,
     0.30, -0.40,  1.0, 1.0,
     0.30,  0.40,  1.0, 0.0,

    -0.30, -0.40,  0.0, 1.0,
     0.30,  0.40,  1.0, 0.0,
    -0.30,  0.40,  0.0, 0.0,
  ]);

  // ----------------------------------------------------------
  // VAO
  // ----------------------------------------------------------

  final idPtr = allocNative(
    sizeOf<Uint32>(),
  ).cast<Uint32>();

  gl.genVertexArrays(
    1,
    idPtr,
  );

  final vao = idPtr.value;

  gl.bindVertexArray(vao);

  // ----------------------------------------------------------
  // VBO
  // ----------------------------------------------------------

  gl.genBuffers(
    1,
    idPtr,
  );

  final vbo = idPtr.value;

  gl.bindBuffer(
    GL_ARRAY_BUFFER,
    vbo,
  );

  final vertexMemory = allocNative(
    vertices.length *
        sizeOf<Float>(),
  ).cast<Float>();

  vertexMemory
      .asTypedList(vertices.length)
      .setAll(
        0,
        vertices,
      );

  gl.bufferData(
    GL_ARRAY_BUFFER,
    vertices.length *
        sizeOf<Float>(),
    vertexMemory.cast<Void>(),
    GL_STATIC_DRAW,
  );

  freeNative(
    vertexMemory.cast<Void>(),
  );

  // ----------------------------------------------------------
  // layout(location = 0)
  // vec2 posição
  // ----------------------------------------------------------

  gl.enableVertexAttribArray(0);

  gl.vertexAttribPointer(
    0,
    2,
    GL_FLOAT,
    0,
    4 * sizeOf<Float>(),
    nullptr,
  );

  // ----------------------------------------------------------
  // layout(location = 1)
  // vec2 UV
  // offset = 2 floats = 8 bytes
  // ----------------------------------------------------------

  gl.enableVertexAttribArray(1);

  gl.vertexAttribPointer(
    1,
    2,
    GL_FLOAT,
    0,
    4 * sizeOf<Float>(),
    Pointer<Void>.fromAddress(
      2 * sizeOf<Float>(),
    ),
  );

  // ----------------------------------------------------------
  // TEXTURA DO BITMAP FONT
  // ----------------------------------------------------------

  gl.genTextures(
    1,
    idPtr,
  );

  final fontTexture =
      idPtr.value;

  freeNative(
    idPtr.cast<Void>(),
  );

  gl.activeTexture(
    GL_TEXTURE0,
  );

  gl.bindTexture(
    GL_TEXTURE_2D,
    fontTexture,
  );

  gl.texParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MIN_FILTER,
    GL_NEAREST,
  );

  gl.texParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_MAG_FILTER,
    GL_NEAREST,
  );

  gl.texParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_S,
    GL_CLAMP_TO_EDGE,
  );

  gl.texParameteri(
    GL_TEXTURE_2D,
    GL_TEXTURE_WRAP_T,
    GL_CLAMP_TO_EDGE,
  );

  gl.pixelStorei(
    GL_UNPACK_ALIGNMENT,
    1,
  );

  final bitmap = createLetterA();

  final bitmapMemory =
      allocNative(
    bitmap.length,
  ).cast<Uint8>();

  bitmapMemory
      .asTypedList(bitmap.length)
      .setAll(
        0,
        bitmap,
      );

  // Apenas 1 byte por pixel.
  //
  // 0   = fundo
  // 255 = pixel da letra
  //
  // GL_R8 = textura de um canal.
  gl.texImage2D(
    GL_TEXTURE_2D,
    0,
    GL_R8,
    8,
    8,
    0,
    GL_RED,
    GL_UNSIGNED_BYTE,
    bitmapMemory.cast<Void>(),
  );

  freeNative(
    bitmapMemory.cast<Void>(),
  );

  // ----------------------------------------------------------
  // Mostrar janela
  // ----------------------------------------------------------

  showWindow(
    hwnd,
    SW_SHOW,
  );

  // ----------------------------------------------------------
  // LOOP
  // ----------------------------------------------------------

  final msg = allocNative(
    sizeOf<MSG>(),
  ).cast<MSG>();

  final rect = allocNative(
    sizeOf<RECT>(),
  ).cast<RECT>();

  var running = true;
  var dirty = true;

  while (running) {
    if (dirty) {
      // --------------------------------------------------------
      // Obter tamanho atual da janela
      // --------------------------------------------------------

      getClientRect(
        hwnd,
        rect,
      );

      final width =
          rect.ref.right -
          rect.ref.left;

      final height =
          rect.ref.bottom -
          rect.ref.top;

      gl.viewport(
        0,
        0,
        width,
        height,
      );

      // --------------------------------------------------------
      // Limpar fundo
      // --------------------------------------------------------

      gl.clearColor(
        0.04,
        0.04,
        0.06,
        1.0,
      );

      gl.clear(
        GL_COLOR_BUFFER_BIT,
      );

      // --------------------------------------------------------
      // Desenhar letra A
      // --------------------------------------------------------

      gl.useProgram(
        shaderProgram,
      );

      gl.activeTexture(
        GL_TEXTURE0,
      );

      gl.bindTexture(
        GL_TEXTURE_2D,
        fontTexture,
      );

      gl.bindVertexArray(
        vao,
      );

      gl.drawArrays(
        GL_TRIANGLES,
        0,
        6,
      );

      // --------------------------------------------------------
      // Front/back buffer
      // --------------------------------------------------------

      swapBuffers(hdc);
      
      dirty = false;
    }

    // --------------------------------------------------------
    // Eventos Win32 (Modo Sob Demanda)
    // --------------------------------------------------------

    final result = getMessageW(
      msg,
      nullptr,
      0,
      0,
    );

    if (result == 0) {
      running = false;
      break;
    } else if (result > 0) {
      translateMessage(msg);
      dispatchMessageW(msg);
      dirty = true;

      // Esvazia eventos acumulados na fila para evitar latência
      while (peekMessageW(
            msg,
            nullptr,
            0,
            0,
            PM_REMOVE,
          ) !=
          0) {
        if (msg.ref.message == WM_QUIT) {
          running = false;
          break;
        }

        translateMessage(msg);
        dispatchMessageW(msg);
      }
    }
  }

  // ==========================================================
  // LIMPEZA
  // ==========================================================

  freeNative(
    rect.cast<Void>(),
  );

  freeNative(
    msg.cast<Void>(),
  );

  wglMakeCurrent(
    nullptr,
    nullptr,
  );

  wglDeleteContext(
    glContext,
  );

  releaseDC(
    hwnd,
    hdc,
  );

  destroyWindow(
    hwnd,
  );
}