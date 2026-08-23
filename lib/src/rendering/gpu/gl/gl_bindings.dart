/// The OpenGL entry points this renderer uses, and nothing else.
///
/// Forty-odd functions, hand written. That is deliberate: a generated binding
/// to the whole of GL is thousands of symbols the framework will never call,
/// and every one of them is a symbol lookup that can fail on a driver that
/// only implements a profile. Section 18 of the roadmap asks for a *subset*
/// dispatch table per context, and this is that subset - buffers, vertex
/// arrays, textures, framebuffers, shaders, blend, scissor.
///
/// ## Why the table is built from a resolver and not from a library handle
///
/// Looking every entry point up in the shared library works on exactly one
/// platform family. Windows is the counter-example that forces the design:
/// `opengl32.dll` exports OpenGL 1.1 and nothing later, because everything
/// since 1.1 is a *driver* entry point reached through `wglGetProcAddress`,
/// which only answers with a context already current - and may answer with a
/// different address for a different pixel format. A dispatch table built by
/// `DynamicLibrary.lookupFunction` therefore cannot populate there at all:
/// `glCreateShader`, `glGenBuffers` and `glGenVertexArrays` are simply not
/// symbols in that DLL.
///
/// So [GlApi] takes a [GlProcResolver] - one function from a name to an
/// address - and the context that was just made current supplies it. On
/// Windows that is the driver's `wglGetProcAddress` with the DLL's exports as
/// a fallback for the 1.1 subset; elsewhere it is a plain symbol lookup, and
/// on EGL it may be `eglGetProcAddress`. None of that is visible here.
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
/// [GlLibrary.open] and [missingGlSymbols] report what was missing instead of
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

/// The two errors that leave GL in an undefined state.
///
/// Every other error in the registry is defined to have "no other side effect
/// than to set the error flag" - the offending command is ignored and the
/// context carries on. These two are not: after either, the contents of every
/// object are undefined, which is what makes them device loss and the others
/// merely bugs. See `GlRenderDevice._checkError`.
const int glOutOfMemory = 0x0505;
const int glContextLost = 0x0507;

const int glTriangles = 0x0004;
const int glTriangleStrip = 0x0005;
const int glUnsignedByte = 0x1401;
const int glUnsignedInt = 0x1405;
const int glFloat = 0x1406;

const int glColorBufferBit = 0x00004000;
const int glStencilBufferBit = 0x00000400;

const int glBlend = 0x0BE2;
const int glScissorTest = 0x0C11;
const int glCullFace = 0x0B44;
const int glDepthTest = 0x0B71;
const int glStencilTest = 0x0B90;

const int glFront = 0x0404;
const int glBack = 0x0405;
const int glCw = 0x0900;
const int glCcw = 0x0901;
const int glAlways = 0x0207;
const int glEqual = 0x0202;
const int glNotEqual = 0x0205;
const int glKeep = 0x1E00;
const int glInvert = 0x150A;
const int glIncrementWrap = 0x8507;
const int glDecrementWrap = 0x8508;

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
const int glLinear = 0x2601;
const int glClampToEdge = 0x812F;

const int glRgba = 0x1908;
const int glRgba8 = 0x8058;
const int glRed = 0x1903;
const int glR8 = 0x8229;

const int glFramebuffer = 0x8D40;
const int glReadFramebuffer = 0x8CA8;
const int glDrawFramebuffer = 0x8CA9;
const int glReadFramebufferBinding = 0x8CAA;
const int glDrawFramebufferBinding = 0x8CA6;
const int glColorAttachment0 = 0x8CE0;
const int glStencilAttachment = 0x8D20;
const int glFramebufferAttachmentStencilSize = 0x8217;

/// `GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE`, and the only attachment query that
/// is legal before you know whether the attachment exists. See
/// `gl_stencil_cover_driver.dart`: asking for a size on a `GL_NONE` attachment
/// raises `GL_INVALID_OPERATION`, and a GL error is sticky.
const int glFramebufferAttachmentObjectType = 0x8CD0;

/// `GL_NONE`, the object type of an attachment that is not present.
const int glNone = 0;
const int glFramebufferComplete = 0x8CD5;
const int glRenderbuffer = 0x8D41;
const int glStencilIndex8 = 0x8D48;
const int glMaxSamples = 0x8D57;
const int glFrontLeft = 0x0400;
const int glBackLeft = 0x0402;

const int glUnpackAlignment = 0x0CF5;
const int glPackAlignment = 0x0D05;

const int glVendor = 0x1F00;
const int glRenderer = 0x1F01;
const int glVersion = 0x1F02;
const int glShadingLanguageVersion = 0x8B8C;
const int glMaxTextureSize = 0x0D33;
const int glStencilBits = 0x0D57;
const int glSamples = 0x80A9;

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
        final malloc = library.lookupFunction<Pointer<Void> Function(IntPtr),
            Pointer<Void> Function(int)>('malloc');
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
    for (final name in const <String>['msvcrt.dll', 'ucrtbase.dll']) {
      try {
        return DynamicLibrary.open(name);
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// [bytes] of native memory - **bytes**, not elements of `T`.
  ///
  /// The type parameter only casts the result. `allocate<Int32>(16)` is four
  /// integers, not sixteen, and writing sixteen into it corrupts the heap in
  /// a way that surfaces much later and somewhere else. Every attribute list
  /// in this renderer goes through [allocateInt32] or [allocatePointers] for
  /// exactly that reason; reach for this one only when the size is already a
  /// byte count.
  Pointer<T> allocate<T extends NativeType>(int bytes) {
    final pointer = _malloc(bytes);
    if (pointer == nullptr) {
      throw StateError('malloc($bytes) returned null');
    }
    return pointer.cast<T>();
  }

  /// [count] 32-bit integers. The size every GL and EGL attribute list is in.
  Pointer<Int32> allocateInt32(int count) =>
      allocate<Int32>(count * sizeOf<Int32>());

  /// [count] machine pointers, for the out-parameters GL and EGL fill in.
  Pointer<Pointer<T>> allocatePointers<T extends NativeType>(int count) =>
      allocate<Pointer<T>>(count * sizeOf<Pointer<Void>>());

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
  /// On Windows the library that answers exports GL 1.1 and the WGL entry
  /// points; everything modern comes from the resolver the context builds on
  /// top of it. See the library comment.
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

/// A name to an address, or [nullptr] when this context has no such entry
/// point. Never throws: a missing symbol is an answer, not a failure.
typedef GlProcResolver = Pointer<Void> Function(String name);

/// A resolver that only looks in [library]'s export table.
///
/// Correct wherever the GL library exports the whole API - Mesa, and any
/// `libGL.so` - and deliberately not enough on Windows, where it finds only
/// the 1.1 subset and is used as the *fallback* half of a WGL resolver.
GlProcResolver libraryProcResolver(DynamicLibrary library) => (String name) {
      try {
        return library.lookup<Void>(name);
      } on Object {
        return nullptr;
      }
    };

/// Symbols [GlApi] needs. Checked before any of them is bound, so a partial
/// driver produces one report naming all of them rather than a throw on the
/// first.
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

/// Additional core GL 3.3 / ES 3.0 symbols used only by the experimental
/// sparse-strip executor. Keeping these out of [kRequiredGlSymbols] means an
/// unused experiment cannot make the established dense renderer fail probe.
const List<String> kSparseGlRequiredSymbols = <String>[
  'glVertexAttribDivisor',
  'glUniform4f',
  'glDrawArraysInstanced',
];

/// Additional symbols used only by the opt-in stencil-then-cover executor.
const List<String> kStencilCoverGlRequiredSymbols = <String>[
  'glColorMask',
  'glClearStencil',
  'glStencilMask',
  'glStencilFunc',
  'glStencilOpSeparate',
  'glFrontFace',
  'glDrawArrays',
  'glGetFramebufferAttachmentParameteriv',
];

/// Additional symbols used only by attachment-aware/MSAA framebuffer pools.
const List<String> kAttachmentFramebufferGlRequiredSymbols = <String>[
  'glGenRenderbuffers',
  'glDeleteRenderbuffers',
  'glBindRenderbuffer',
  'glRenderbufferStorage',
  'glRenderbufferStorageMultisample',
  'glFramebufferRenderbuffer',
  'glBlitFramebuffer',
];

/// Names in [kRequiredGlSymbols] that [resolve] cannot find.
///
/// Must be called with the context current on any platform whose resolver
/// asks the driver rather than the export table - which is all of them that
/// matter. Reporting the whole list at once is the point: a driver missing
/// vertex array objects and framebuffer objects should say so in one probe,
/// not one crash at a time.
List<String> missingGlSymbols(GlProcResolver resolve) {
  final missing = <String>[];
  for (final symbol in kRequiredGlSymbols) {
    Pointer<Void> address;
    try {
      address = resolve(symbol);
    } on Object {
      address = nullptr;
    }
    if (address == nullptr) missing.add(symbol);
  }
  return missing;
}

/// Names in [kSparseGlRequiredSymbols] that [resolve] cannot find.
List<String> missingSparseGlSymbols(GlProcResolver resolve) {
  final missing = <String>[];
  for (final symbol in kSparseGlRequiredSymbols) {
    Pointer<Void> address;
    try {
      address = resolve(symbol);
    } on Object {
      address = nullptr;
    }
    if (address == nullptr) missing.add(symbol);
  }
  return missing;
}

/// Names in [kStencilCoverGlRequiredSymbols] that [resolve] cannot find.
List<String> missingStencilCoverGlSymbols(GlProcResolver resolve) {
  final missing = <String>[];
  for (final symbol in kStencilCoverGlRequiredSymbols) {
    Pointer<Void> address;
    try {
      address = resolve(symbol);
    } on Object {
      address = nullptr;
    }
    if (address == nullptr) missing.add(symbol);
  }
  return missing;
}

/// Names in [kAttachmentFramebufferGlRequiredSymbols] not resolved by GL.
List<String> missingAttachmentFramebufferGlSymbols(GlProcResolver resolve) {
  final missing = <String>[];
  for (final symbol in kAttachmentFramebufferGlRequiredSymbols) {
    Pointer<Void> address;
    try {
      address = resolve(symbol);
    } on Object {
      address = nullptr;
    }
    if (address == nullptr) missing.add(symbol);
  }
  return missing;
}

/// The bound entry points.
///
/// Every field is `late final`, so an entry point is resolved the first time
/// it is called and a missing one throws *there* rather than at construction.
/// That is why [missingGlSymbols] exists and why the backend runs it before
/// it builds one of these: the probe has to name every missing symbol at
/// once, and lazy binding alone would report them one crash at a time.
final class GlApi {
  GlApi(this.resolveProc);

  /// Where the addresses come from. Bound to the context that was current
  /// when this table was built; using it under a different context is
  /// undefined on Windows, which is why a device owns exactly one of each.
  final GlProcResolver resolveProc;

  Pointer<Void> _proc(String name) {
    final address = resolveProc(name);
    if (address == nullptr) {
      throw StateError(
        'the GL entry point $name could not be resolved; the probe is '
        'supposed to have refused this device before anything called it',
      );
    }
    return address;
  }

  late final int Function() getError = _proc('glGetError')
      .cast<NativeFunction<Uint32 Function()>>()
      .asFunction<int Function()>();

  late final Pointer<Uint8> Function(int) getString = _proc('glGetString')
      .cast<NativeFunction<Pointer<Uint8> Function(Uint32)>>()
      .asFunction<Pointer<Uint8> Function(int)>();

  late final void Function(int, Pointer<Int32>) getIntegerv =
      _proc('glGetIntegerv')
          .cast<NativeFunction<Void Function(Uint32, Pointer<Int32>)>>()
          .asFunction<void Function(int, Pointer<Int32>)>();

  late final void Function(int, int, int, int) viewport = _proc('glViewport')
      .cast<NativeFunction<Void Function(Int32, Int32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int, int)>();

  late final void Function(int, int, int, int) scissor = _proc('glScissor')
      .cast<NativeFunction<Void Function(Int32, Int32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int, int)>();

  late final void Function(int) enable = _proc('glEnable')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int) disable = _proc('glDisable')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int) blendFunc = _proc('glBlendFunc')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(double, double, double, double) clearColor =
      _proc('glClearColor')
          .cast<NativeFunction<Void Function(Float, Float, Float, Float)>>()
          .asFunction<void Function(double, double, double, double)>();

  late final void Function(int) clear = _proc('glClear')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int, int, int) colorMask = _proc('glColorMask')
      .cast<NativeFunction<Void Function(Uint8, Uint8, Uint8, Uint8)>>()
      .asFunction<void Function(int, int, int, int)>();

  late final void Function(int) clearStencil = _proc('glClearStencil')
      .cast<NativeFunction<Void Function(Int32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int) stencilMask = _proc('glStencilMask')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int, int) stencilFunc = _proc('glStencilFunc')
      .cast<NativeFunction<Void Function(Uint32, Int32, Uint32)>>()
      .asFunction<void Function(int, int, int)>();

  late final void Function(int, int, int, int) stencilOpSeparate =
      _proc('glStencilOpSeparate')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Uint32, Uint32)>>()
          .asFunction<void Function(int, int, int, int)>();

  late final void Function(int) frontFace = _proc('glFrontFace')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function() finish = _proc('glFinish')
      .cast<NativeFunction<Void Function()>>()
      .asFunction<void Function()>();

  late final void Function(int, Pointer<Uint32>) genBuffers =
      _proc('glGenBuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, Pointer<Uint32>) deleteBuffers =
      _proc('glDeleteBuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, int) bindBuffer = _proc('glBindBuffer')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(int, int, Pointer<Void>, int) bufferData =
      _proc('glBufferData')
          .cast<
              NativeFunction<
                  Void Function(Uint32, IntPtr, Pointer<Void>, Uint32)>>()
          .asFunction<void Function(int, int, Pointer<Void>, int)>();

  late final void Function(int, Pointer<Uint32>) genVertexArrays =
      _proc('glGenVertexArrays')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, Pointer<Uint32>) deleteVertexArrays =
      _proc('glDeleteVertexArrays')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int) bindVertexArray = _proc('glBindVertexArray')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int) enableVertexAttribArray =
      _proc('glEnableVertexAttribArray')
          .cast<NativeFunction<Void Function(Uint32)>>()
          .asFunction<void Function(int)>();

  late final void Function(int, int, int, int, int, Pointer<Void>)
      vertexAttribPointer = _proc('glVertexAttribPointer')
          .cast<
              NativeFunction<
                  Void Function(
                      Uint32, Int32, Uint32, Uint8, Int32, Pointer<Void>)>>()
          .asFunction<void Function(int, int, int, int, int, Pointer<Void>)>();

  late final void Function(int, int) vertexAttribDivisor =
      _proc('glVertexAttribDivisor')
          .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
          .asFunction<void Function(int, int)>();

  late final int Function(int) createShader = _proc('glCreateShader')
      .cast<NativeFunction<Uint32 Function(Uint32)>>()
      .asFunction<int Function(int)>();

  late final void Function(int) deleteShader = _proc('glDeleteShader')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)
      shaderSource = _proc('glShaderSource')
          .cast<
              NativeFunction<
                  Void Function(Uint32, Int32, Pointer<Pointer<Uint8>>,
                      Pointer<Int32>)>>()
          .asFunction<
              void Function(
                  int, int, Pointer<Pointer<Uint8>>, Pointer<Int32>)>();

  late final void Function(int) compileShader = _proc('glCompileShader')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int, Pointer<Int32>) getShaderiv =
      _proc('glGetShaderiv')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Pointer<Int32>)>>()
          .asFunction<void Function(int, int, Pointer<Int32>)>();

  late final void Function(
      int, int, Pointer<Int32>, Pointer<Uint8>) getShaderInfoLog = _proc(
          'glGetShaderInfoLog')
      .cast<
          NativeFunction<
              Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint8>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>, Pointer<Uint8>)>();

  late final int Function() createProgram = _proc('glCreateProgram')
      .cast<NativeFunction<Uint32 Function()>>()
      .asFunction<int Function()>();

  late final void Function(int) deleteProgram = _proc('glDeleteProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int) attachShader = _proc('glAttachShader')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(int, int, Pointer<Uint8>) bindAttribLocation =
      _proc('glBindAttribLocation')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Pointer<Uint8>)>>()
          .asFunction<void Function(int, int, Pointer<Uint8>)>();

  late final void Function(int) linkProgram = _proc('glLinkProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int, Pointer<Int32>) getProgramiv =
      _proc('glGetProgramiv')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Pointer<Int32>)>>()
          .asFunction<void Function(int, int, Pointer<Int32>)>();

  late final void Function(
      int, int, Pointer<Int32>, Pointer<Uint8>) getProgramInfoLog = _proc(
          'glGetProgramInfoLog')
      .cast<
          NativeFunction<
              Void Function(Uint32, Int32, Pointer<Int32>, Pointer<Uint8>)>>()
      .asFunction<void Function(int, int, Pointer<Int32>, Pointer<Uint8>)>();

  late final void Function(int) useProgram = _proc('glUseProgram')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final int Function(int, Pointer<Uint8>) getUniformLocation =
      _proc('glGetUniformLocation')
          .cast<NativeFunction<Int32 Function(Uint32, Pointer<Uint8>)>>()
          .asFunction<int Function(int, Pointer<Uint8>)>();

  late final void Function(int, double, double) uniform2f = _proc('glUniform2f')
      .cast<NativeFunction<Void Function(Int32, Float, Float)>>()
      .asFunction<void Function(int, double, double)>();

  late final void Function(
      int, double, double, double, double) uniform4f = _proc(
          'glUniform4f')
      .cast<NativeFunction<Void Function(Int32, Float, Float, Float, Float)>>()
      .asFunction<void Function(int, double, double, double, double)>();

  late final void Function(int, int) uniform1i = _proc('glUniform1i')
      .cast<NativeFunction<Void Function(Int32, Int32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(int, Pointer<Uint32>) genTextures =
      _proc('glGenTextures')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, Pointer<Uint32>) deleteTextures =
      _proc('glDeleteTextures')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, int) bindTexture = _proc('glBindTexture')
      .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(
          int, int, int, int, int, int, int, int, Pointer<Void>) texImage2D =
      _proc('glTexImage2D')
          .cast<
              NativeFunction<
                  Void Function(Uint32, Int32, Int32, Int32, Int32, Int32,
                      Uint32, Uint32, Pointer<Void>)>>()
          .asFunction<
              void Function(
                  int, int, int, int, int, int, int, int, Pointer<Void>)>();

  late final void Function(
          int, int, int, int, int, int, int, int, Pointer<Void>) texSubImage2D =
      _proc('glTexSubImage2D')
          .cast<
              NativeFunction<
                  Void Function(Uint32, Int32, Int32, Int32, Int32, Int32,
                      Uint32, Uint32, Pointer<Void>)>>()
          .asFunction<
              void Function(
                  int, int, int, int, int, int, int, int, Pointer<Void>)>();

  late final void Function(int, int, int) texParameteri =
      _proc('glTexParameteri')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Int32)>>()
          .asFunction<void Function(int, int, int)>();

  late final void Function(int) activeTexture = _proc('glActiveTexture')
      .cast<NativeFunction<Void Function(Uint32)>>()
      .asFunction<void Function(int)>();

  late final void Function(int, int) pixelStorei = _proc('glPixelStorei')
      .cast<NativeFunction<Void Function(Uint32, Int32)>>()
      .asFunction<void Function(int, int)>();

  late final void Function(int, Pointer<Uint32>) genFramebuffers =
      _proc('glGenFramebuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, Pointer<Uint32>) deleteFramebuffers =
      _proc('glDeleteFramebuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, int) bindFramebuffer =
      _proc('glBindFramebuffer')
          .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
          .asFunction<void Function(int, int)>();

  late final void Function(int, int, int, int, int) framebufferTexture2D =
      _proc('glFramebufferTexture2D')
          .cast<
              NativeFunction<
                  Void Function(Uint32, Uint32, Uint32, Uint32, Int32)>>()
          .asFunction<void Function(int, int, int, int, int)>();

  late final int Function(int) checkFramebufferStatus =
      _proc('glCheckFramebufferStatus')
          .cast<NativeFunction<Uint32 Function(Uint32)>>()
          .asFunction<int Function(int)>();

  late final void Function(int, Pointer<Uint32>) genRenderbuffers =
      _proc('glGenRenderbuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, Pointer<Uint32>) deleteRenderbuffers =
      _proc('glDeleteRenderbuffers')
          .cast<NativeFunction<Void Function(Int32, Pointer<Uint32>)>>()
          .asFunction<void Function(int, Pointer<Uint32>)>();

  late final void Function(int, int) bindRenderbuffer =
      _proc('glBindRenderbuffer')
          .cast<NativeFunction<Void Function(Uint32, Uint32)>>()
          .asFunction<void Function(int, int)>();

  late final void Function(int, int, int, int) renderbufferStorage =
      _proc('glRenderbufferStorage')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Int32, Int32)>>()
          .asFunction<void Function(int, int, int, int)>();

  late final void Function(
      int, int, int, int, int) renderbufferStorageMultisample = _proc(
          'glRenderbufferStorageMultisample')
      .cast<
          NativeFunction<Void Function(Uint32, Int32, Uint32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int, int, int)>();

  late final void Function(int, int, int, int) framebufferRenderbuffer =
      _proc('glFramebufferRenderbuffer')
          .cast<NativeFunction<Void Function(Uint32, Uint32, Uint32, Uint32)>>()
          .asFunction<void Function(int, int, int, int)>();

  late final void Function(int, int, int, int, int, int, int, int, int, int)
      blitFramebuffer = _proc('glBlitFramebuffer')
          .cast<
              NativeFunction<
                  Void Function(Int32, Int32, Int32, Int32, Int32, Int32, Int32,
                      Int32, Uint32, Uint32)>>()
          .asFunction<
              void Function(
                  int, int, int, int, int, int, int, int, int, int)>();

  late final void Function(int, int, int, Pointer<Void>) drawElements = _proc(
          'glDrawElements')
      .cast<
          NativeFunction<Void Function(Uint32, Int32, Uint32, Pointer<Void>)>>()
      .asFunction<void Function(int, int, int, Pointer<Void>)>();

  late final void Function(int, int, int) drawArrays = _proc('glDrawArrays')
      .cast<NativeFunction<Void Function(Uint32, Int32, Int32)>>()
      .asFunction<void Function(int, int, int)>();

  late final void Function(int, int, int, Pointer<Int32>)
      getFramebufferAttachmentParameteriv =
      _proc('glGetFramebufferAttachmentParameteriv')
          .cast<
              NativeFunction<
                  Void Function(Uint32, Uint32, Uint32, Pointer<Int32>)>>()
          .asFunction<void Function(int, int, int, Pointer<Int32>)>();

  late final void Function(int, int, int, int) drawArraysInstanced =
      _proc('glDrawArraysInstanced')
          .cast<NativeFunction<Void Function(Uint32, Int32, Int32, Int32)>>()
          .asFunction<void Function(int, int, int, int)>();

  late final void Function(
      int, int, int, int, int, int, Pointer<Void>) readPixels = _proc(
          'glReadPixels')
      .cast<
          NativeFunction<
              Void Function(
                  Int32, Int32, Int32, Int32, Uint32, Uint32, Pointer<Void>)>>()
      .asFunction<void Function(int, int, int, int, int, int, Pointer<Void>)>();

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
