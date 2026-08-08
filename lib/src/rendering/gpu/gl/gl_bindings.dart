/// The OpenGL entry points this renderer uses, and nothing else.
///
/// Forty-odd functions, hand written. That is deliberate: a generated binding
/// to the whole of GL is thousands of symbols the framework will never call,
/// and every one of them is a symbol lookup that can fail on a driver that
/// only implements a profile. Section 18 of the roadmap asks for a *subset*
/// dispatch table per context, and this is that subset - buffers, vertex
/// arrays, textures, framebuffers, shaders, blend, scissor.
///
/// ## No package:ffi
///
/// `dart_ui` depends on `meta` and nothing else, and adding a dependency is
/// not this file's decision to make. So the two things `package:ffi` would
/// have provided - a native allocator and UTF-8 marshalling - are here, in
/// about sixty lines. [NativeHeap] binds `malloc` and `free` out of a library
/// that is already loaded rather than shipping an allocator, and every buffer
/// it hands out is long lived: the GL device allocates its staging memory
/// once and reuses it for every frame, so there is no per-frame native
/// allocation to make this a hot path.
///
/// ## Everything can fail, nothing may throw during a probe
///
/// [GlLibrary.open] and [GlApi.bind] report what was missing instead of
/// raising. That is what lets `GlRendererBackend.probe()` honour the rule in
/// section 6.6: a machine without a driver gets a named diagnostic and a
/// fallback to the CPU renderer, not a stack trace.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// ---------------------------------------------------------------------------
// Constants. Only the ones used; each is the value from the GL registry.
// ---------------------------------------------------------------------------

const int glNoError = 0;
const int glFalseValue = 0;

const int glTriangles = 0x0004;
const int glUnsignedByte = 0x1401;
const int glUnsignedInt = 0x1405;
const int glFloat = 0x1406;

const int glColorBufferBit = 0x00004000;

const int glBlend = 0x0BE2;
const int glScissorTest = 0x0C11;
const int glCullFace = 0x0B44;
const int glDepthTest = 0x0B71;

const int glZero = 0;
const int glOne = 1;
const int glOneMinusSrcAlpha = 0x0303;

const int glArrayBuffer = 0x8892;
const int glElementArrayBuffer = 0x8893;
const int glDynamicDraw = 0x88E8;

const int glVertexShader = 0x8B31;
const int glFragmentShader = 0x8B30;
const int glCompileStatus = 0x8B81;
const int glLinkStatus = 0x8B82;
const int glInfoLogLength = 0x8B84;

const int glTexture2D = 0x0DE1;
const int glTexture0 = 0x84C0;
const int glTextureMinFilter = 0x2801;
const int glTextureMagFilter = 0x2800;
const int glTextureWrapS = 0x2802;
const int glTextureWrapT = 0x2803;
const int glNearest = 0x2600;
const int glClampToEdge = 0x812F;

const int glRgba = 0x1908;
const int glRgba8 = 0x8058;
const int glRed = 0x1903;
const int glR8 = 0x8229;

const int glFramebuffer = 0x8D40;
const int glColorAttachment0 = 0x8CE0;
const int glFramebufferComplete = 0x8CD5;

const int glUnpackAlignment = 0x0CF5;
const int glPackAlignment = 0x0D05;

const int glVendor = 0x1F00;
const int glRenderer = 0x1F01;
const int glVersion = 0x1F02;
const int glMaxTextureSize = 0x0D33;

// ---------------------------------------------------------------------------
// Native memory
// ---------------------------------------------------------------------------

/// `malloc` and `free`, borrowed from a library that is already loaded.
///
/// `dlsym` on a library handle searches that library's dependency chain, and
/// every GL implementation links the C runtime, so asking the GL handle for
/// `malloc` finds libc's. On Windows the same is true of `msvcrt.dll`, and on
/// platforms where `DynamicLibrary.process()` works it is simply the process.
/// Whichever answers first is used; if none does, the backend reports that
/// rather than pretending it can allocate.
final class NativeHeap {
  NativeHeap._(this._malloc, this._free);

  final Pointer<Void> Function(int) _malloc;
  final void Function(Pointer<Void>) _free;

  static NativeHeap? tryBind(DynamicLibrary? preferred) {
    for (final library in <DynamicLibrary?>[
      preferred,
      _processLibrary(),
      _crtLibrary(),
    ]) {
      if (library == null) continue;
      try {
        final malloc =
            library.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void>
                Function(int)>('malloc');
        final free = library.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('free');
        return NativeHeap._(malloc, free);
      } on Object {
        continue;
      }
    }
    return null;
  }

  static DynamicLibrary? _processLibrary() {
    try {
      return DynamicLibrary.process();
    } on Object {
      // Not supported on Windows. Expected, not exceptional.
      return null;
    }
  }

  static DynamicLibrary? _crtLibrary() {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('msvcrt.dll');
    } on Object {
      return null;
    }
  }

  /// [bytes] of zeroed-on-first-use native memory. The caller owns it and
  /// must pass it to [release].
  Pointer<T> allocate<T extends NativeType>(int bytes) {
    final pointer = _malloc(bytes);
    if (pointer == nullptr) {
      throw StateError('malloc($bytes) returned null');
    }
    return pointer.cast<T>();
  }

  void release(Pointer<NativeType> pointer) {
    if (pointer == nullptr) return;
    _free(pointer.cast<Void>());
  }

  /// A NUL-terminated copy of [value]. Freed by the caller.
  Pointer<Uint8> allocateUtf8(String value) {
    final units = utf8.encode(value);
    final pointer = allocate<Uint8>(units.length + 1);
    final view = pointer.asTypedList(units.length + 1);
    view.setRange(0, units.length, units);
    view[units.length] = 0;
    return pointer;
  }
}

/// Reads a NUL-terminated C string, stopping at [limit] bytes.
///
/// The limit is not paranoia: `glGetString` on a broken driver has been known
/// to return a pointer into freed memory, and walking it unbounded turns a
/// diagnostic into a segfault.
String readNativeUtf8(Pointer<Uint8> pointer, {int limit = 4096}) {
  if (pointer == nullptr) return '';
  var length = 0;
  while (length < limit && pointer[length] != 0) {
    length++;
  }
  return utf8.decode(pointer.asTypedList(length), allowMalformed: true);
}

// ---------------------------------------------------------------------------
// Library loading
// ---------------------------------------------------------------------------

/// The result of trying to load the platform's GL library.
final class GlLibraryLoad {
  const GlLibraryLoad.loaded(this.library, this.name)
      : attempted = const <String>[],
        error = null;

  const GlLibraryLoad.failed(this.attempted, this.error)
      : library = null,
        name = null;

  final DynamicLibrary? library;

  /// The file name that answered, for the probe report.
  final String? name;

  /// Everything tried, in order, when nothing answered.
  final List<String> attempted;

  final String? error;

  bool get isLoaded => library != null;
}

/// Opens the platform's OpenGL shared library.
final class GlLibrary {
  /// Candidates per platform, most specific first.
  ///
  /// Windows is listed even though this backend cannot yet create a context
  /// there: `opengl32.dll` loads fine and exports GL 1.1, so the probe gets
  /// to report the *real* obstacle - the missing modern entry points and the
  /// missing offscreen context - instead of "library not found", which would
  /// send a reader looking for a driver install that is already present.
  static List<String> candidates() {
    if (Platform.isWindows) return const <String>['opengl32.dll'];
    if (Platform.isMacOS) {
      return const <String>[
        '/System/Library/Frameworks/OpenGL.framework/OpenGL',
      ];
    }
    return const <String>['libGL.so.1', 'libGL.so', 'libGLESv2.so.2'];
  }

  static GlLibraryLoad open() {
    final tried = <String>[];
    String? lastError;
    for (final candidate in candidates()) {
      tried.add(candidate);
      try {
        return GlLibraryLoad.loaded(DynamicLibrary.open(candidate), candidate);
      } on Object catch (error) {
        lastError = error.toString();
      }
    }
    return GlLibraryLoad.failed(tried, lastError);
  }
}

// ---------------------------------------------------------------------------
// The dispatch table
// ---------------------------------------------------------------------------

/// Symbols [GlApi.bind] needs. Checked before any of them is bound, so a
/// partial driver produces one report naming all of them rather than a throw
/// on the first.
const List<String> kRequiredGlSymbols = <String>[
  'glGetError',
  'glGetString',
  'glGetIntegerv',
  'glViewport',
  'glScissor',
  'glEnable',
  'glDisable',
  'glBlendFunc',
  'glClearColor',
  'glClear',
  'glFinish',
  'glGenBuffers',
  'glDeleteBuffers',
  'glBindBuffer',
  'glBufferData',
  'glGenVertexArrays',
  'glDeleteVertexArrays',
  'glBindVertexArray',
  'glEnableVertexAttribArray',
  'glVertexAttribPointer',
  'glCreateShader',
  'glDeleteShader',
  'glShaderSource',
  'glCompileShader',
  'glGetShaderiv',
  'glGetShaderInfoLog',
  'glCreateProgram',
  'glDeleteProgram',
  'glAttachShader',
  'glBindAttribLocation',
  'glLinkProgram',
  'glGetProgramiv',
  'glGetProgramInfoLog',
  'glUseProgram',
  'glGetUniformLocation',
  'glUniform2f',
  'glUniform1i',
  'glGenTextures',
  'glDeleteTextures',
  'glBindTexture',
  'glTexImage2D',
  'glTexSubImage2D',
  'glTexParameteri',
  'glActiveTexture',
  'glPixelStorei',
  'glGenFramebuffers',
  'glDeleteFramebuffers',
  'glBindFramebuffer',
  'glFramebufferTexture2D',
  'glCheckFramebufferStatus',
  'glDrawElements',
  'glReadPixels',
];

/// Names in [kRequiredGlSymbols] that [library] does not export.
///
/// On Windows this is expected to be long: `opengl32.dll` exports GL 1.1 and
/// everything since is reached through `wglGetProcAddress`, which needs a
/// current context, which needs a window. Reporting the list is exactly the
/// point - it names why this backend is unavailable there.
List<String> missingGlSymbols(DynamicLibrary library) {
  final missing = <String>[];
  for (final symbol in kRequiredGlSymbols) {
    try {
      if (!library.providesSymbol(symbol)) missing.add(symbol);
    } on Object {
      missing.add(symbol);
    }
  }
  return missing;
}

/// The bound entry points.
///
/// Every field is `late final`, so a symbol is looked up the first time it is
/// called and a missing one throws *there* rather than at construction. That
/// is why [missingGlSymbols] exists and why the backend runs it before it
/// builds one of these: the probe has to name every missing symbol at once,
/// and lazy binding alone would report them one crash at a time.
final class GlApi {
  GlApi(this.library);

  final DynamicLibrary library;

  late final int Function() getError =
      library.lookupFunction<Uint32 Function(), int Function()>('glGetError');

  late final Pointer<Uint8> Function(int) getString = library.lookupFunction<
      Pointer<Uint8> Function(Uint32),
      Pointer<Uint8> Function(int)>('glGetString');

  late final void Function(int, Pointer<Int32>) getIntegerv =
      library.lookupFunction<Void Function(Uint32, Pointer<Int32>),
          void Function(int, Pointer<Int32>)>('glGetIntegerv');

  late final void Function(int, int, int, int) viewport =
      library.lookupFunction<Void Function(Int32, Int32, Int32, Int32),
          void Function(int, int, int, int)>('glViewport');

  late final void Function(int, int, int, int) scissor =
      library.lookupFunction<Void Function(Int32, Int32, Int32, Int32),
          void Function(int, int, int, int)>('glScissor');

  late final void Function(int) enable = library
      .lookupFunction<Void Function(Uint32), void Function(int)>('glEnable');

  late final void Function(int) disable = library
      .lookupFunction<Void Function(Uint32), void Function(int)>('glDisable');

  late final void Function(int, int) blendFunc =
      library.lookupFunction<Void Function(Uint32, Uint32),
          void Function(int, int)>('glBlendFunc');

  late final void Function(double, double, double, double) clearColor =
      library.lookupFunction<Void Function(Float, Float, Float, Float),
          void Function(double, double, double, double)>('glClearColor');

  late final void Function(int) clear = library
      .lookupFunction<Void Function(Uint32), void Function(int)>('glClear');

  late final void Function() finish =
      library.lookupFunction<Void Function(), void Function()>('glFinish');

  late final void Function(int, Pointer<Uint32>) genBuffers =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glGenBuffers');

  late final void Function(int, Pointer<Uint32>) deleteBuffers =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glDeleteBuffers');

  late final void Function(int, int) bindBuffer =
      library.lookupFunction<Void Function(Uint32, Uint32),
          void Function(int, int)>('glBindBuffer');

  late final void Function(int, int, Pointer<Void>, int) bufferData =
      library.lookupFunction<
          Void Function(Uint32, IntPtr, Pointer<Void>, Uint32),
          void Function(int, int, Pointer<Void>, int)>('glBufferData');

  late final void Function(int, Pointer<Uint32>) genVertexArrays =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glGenVertexArrays');

  late final void Function(int, Pointer<Uint32>) deleteVertexArrays =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glDeleteVertexArrays');

  late final void Function(int) bindVertexArray =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glBindVertexArray');

  late final void Function(int) enableVertexAttribArray =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glEnableVertexAttribArray');

  late final void Function(int, int, int, int, int, Pointer<Void>)
      vertexAttribPointer = library.lookupFunction<
          Void Function(Uint32, Int32, Uint32, Uint8, Int32, Pointer<Void>),
          void Function(
              int, int, int, int, int, Pointer<Void>)>('glVertexAttribPointer');

  late final int Function(int) createShader =
      library.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'glCreateShader');

  late final void Function(int) deleteShader =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glDeleteShader');

  late final void Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)
      shaderSource = library.lookupFunction<
              Void Function(
                  Uint32, Int32, Pointer<Pointer<Uint8>>, Pointer<Int32>),
              void Function(
                  int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)>(
          'glShaderSource');

  late final void Function(int) compileShader =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glCompileShader');

  late final void Function(int, int, Pointer<Int32>) getShaderiv =
      library.lookupFunction<Void Function(Uint32, Uint32, Pointer<Int32>),
          void Function(int, int, Pointer<Int32>)>('glGetShaderiv');

  late final void Function(int, int, Pointer<Int32>, Pointer<Uint8>)
      getShaderInfoLog = library.lookupFunction<
          Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint8>),
          void Function(
              int, int, Pointer<Int32>, Pointer<Uint8>)>('glGetShaderInfoLog');

  late final int Function() createProgram =
      library.lookupFunction<Uint32 Function(), int Function()>(
          'glCreateProgram');

  late final void Function(int) deleteProgram =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glDeleteProgram');

  late final void Function(int, int) attachShader =
      library.lookupFunction<Void Function(Uint32, Uint32),
          void Function(int, int)>('glAttachShader');

  late final void Function(int, int, Pointer<Uint8>) bindAttribLocation =
      library.lookupFunction<Void Function(Uint32, Uint32, Pointer<Uint8>),
          void Function(int, int, Pointer<Uint8>)>('glBindAttribLocation');

  late final void Function(int) linkProgram =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glLinkProgram');

  late final void Function(int, int, Pointer<Int32>) getProgramiv =
      library.lookupFunction<Void Function(Uint32, Uint32, Pointer<Int32>),
          void Function(int, int, Pointer<Int32>)>('glGetProgramiv');

  late final void Function(int, int, Pointer<Int32>, Pointer<Uint8>)
      getProgramInfoLog = library.lookupFunction<
          Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint8>),
          void Function(
              int, int, Pointer<Int32>, Pointer<Uint8>)>('glGetProgramInfoLog');

  late final void Function(int) useProgram =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glUseProgram');

  late final int Function(int, Pointer<Uint8>) getUniformLocation =
      library.lookupFunction<Int32 Function(Uint32, Pointer<Uint8>),
          int Function(int, Pointer<Uint8>)>('glGetUniformLocation');

  late final void Function(int, double, double) uniform2f =
      library.lookupFunction<Void Function(Int32, Float, Float),
          void Function(int, double, double)>('glUniform2f');

  late final void Function(int, int) uniform1i =
      library.lookupFunction<Void Function(Int32, Int32),
          void Function(int, int)>('glUniform1i');

  late final void Function(int, Pointer<Uint32>) genTextures =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glGenTextures');

  late final void Function(int, Pointer<Uint32>) deleteTextures =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glDeleteTextures');

  late final void Function(int, int) bindTexture =
      library.lookupFunction<Void Function(Uint32, Uint32),
          void Function(int, int)>('glBindTexture');

  late final void Function(
      int, int, int, int, int, int, int, int, Pointer<Void>) texImage2D =
      library.lookupFunction<
          Void Function(Uint32, Int32, Int32, Int32, Int32, Int32, Uint32,
              Uint32, Pointer<Void>),
          void Function(int, int, int, int, int, int, int, int,
              Pointer<Void>)>('glTexImage2D');

  late final void Function(
      int, int, int, int, int, int, int, int, Pointer<Void>) texSubImage2D =
      library.lookupFunction<
          Void Function(Uint32, Int32, Int32, Int32, Int32, Int32, Uint32,
              Uint32, Pointer<Void>),
          void Function(int, int, int, int, int, int, int, int,
              Pointer<Void>)>('glTexSubImage2D');

  late final void Function(int, int, int) texParameteri =
      library.lookupFunction<Void Function(Uint32, Uint32, Int32),
          void Function(int, int, int)>('glTexParameteri');

  late final void Function(int) activeTexture =
      library.lookupFunction<Void Function(Uint32), void Function(int)>(
          'glActiveTexture');

  late final void Function(int, int) pixelStorei =
      library.lookupFunction<Void Function(Uint32, Int32),
          void Function(int, int)>('glPixelStorei');

  late final void Function(int, Pointer<Uint32>) genFramebuffers =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glGenFramebuffers');

  late final void Function(int, Pointer<Uint32>) deleteFramebuffers =
      library.lookupFunction<Void Function(Int32, Pointer<Uint32>),
          void Function(int, Pointer<Uint32>)>('glDeleteFramebuffers');

  late final void Function(int, int) bindFramebuffer =
      library.lookupFunction<Void Function(Uint32, Uint32),
          void Function(int, int)>('glBindFramebuffer');

  late final void Function(int, int, int, int, int) framebufferTexture2D =
      library.lookupFunction<
          Void Function(Uint32, Uint32, Uint32, Uint32, Int32),
          void Function(int, int, int, int, int)>('glFramebufferTexture2D');

  late final int Function(int) checkFramebufferStatus =
      library.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
          'glCheckFramebufferStatus');

  late final void Function(int, int, int, Pointer<Void>) drawElements =
      library.lookupFunction<Void Function(Uint32, Int32, Uint32, Pointer<Void>),
          void Function(int, int, int, Pointer<Void>)>('glDrawElements');

  late final void Function(int, int, int, int, int, int, Pointer<Void>)
      readPixels = library.lookupFunction<
          Void Function(Int32, Int32, Int32, Int32, Uint32, Uint32,
              Pointer<Void>),
          void Function(
              int, int, int, int, int, int, Pointer<Void>)>('glReadPixels');

  /// The GL string for [name], or an empty string when the driver refuses.
  String stringOf(int name) => readNativeUtf8(getString(name));

  /// Drains the error queue and returns the first error, or [glNoError].
  ///
  /// Draining matters: GL keeps a queue, and reading one error leaves the
  /// rest to be blamed on the next unrelated call. The loop is bounded
  /// because a lost context can return the same error forever.
  int drainErrors() {
    var first = glNoError;
    for (var i = 0; i < 32; i++) {
      final error = getError();
      if (error == glNoError) break;
      if (first == glNoError) first = error;
    }
    return first;
  }
}
