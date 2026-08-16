/// The Objective-C runtime, bound directly, with the signature discipline
/// section 20.5 of the roadmap demands.
///
/// ## The hazard this file is built around
///
/// The runtime exports **one** message-send trampoline. It has no prototype:
/// the caller is expected to know the selector's real signature and to call
/// through a function pointer cast to it. On arm64 that is not a formality.
/// Integer arguments go in `x0..x7`, floating-point arguments go in `d0..d7`,
/// and an aggregate larger than 16 bytes that is not a homogeneous float
/// aggregate is copied by the *caller* and replaced by a pointer (AAPCS64
/// stage B.3). So a selector declared with the wrong shape does not fail: it
/// reads a register nobody wrote, or writes a stack slot the callee owns, and
/// the damage appears somewhere else entirely, usually minutes later.
///
/// x86_64 disagrees with arm64 in the other direction - a four-`double`
/// aggregate is an HFA passed in `d0..d3` on arm64 and a MEMORY-class argument
/// passed on the stack under System V - so "it worked on my Mac" is not
/// evidence either.
///
/// ## How the match is guaranteed here
///
/// Three mechanisms, in increasing strength, and the first two work on a
/// machine with no Objective-C runtime at all:
///
///   1. **A closed set of shapes.** Every send goes through one of the
///      [ObjCSendShape] members below. There is no generic sender, and a call
///      site cannot invent a shape: it picks one from the enum. All non-struct
///      arguments are declared `IntPtr`, which is exactly what an `id`, a
///      `SEL`, a `void*`, an `NSUInteger` and a `BOOL` are once they reach a
///      general-purpose register, so one shape covers every word-sized
///      argument list of that length instead of one per element type.
///   2. **A declared type encoding per selector.** A caller registers the
///      selector's Objective-C type encoding - the same string the runtime
///      itself stores - next to the shape it intends to use.
///      [parseObjCTypeEncoding] turns that string into an [ObjCSignature], and
///      [ObjCSendShape.signature] is what the shape actually implements.
///      Comparing the two is a pure-Dart equality that a Windows test runs.
///   3. **The runtime's own answer.** On a machine that has libobjc,
///      [objcMethodTypeEncoding] reads the encoding the class really declares,
///      and the same comparison then checks the header rather than a comment.
///      That check can only run on macOS; mechanisms 1 and 2 are what make the
///      *transcription* checkable everywhere else.
///
/// Struct returns are refused outright rather than supported. `objc_msgSend`
/// is not the right trampoline for a large struct return on x86_64 - the
/// `_stret` variant is, and it does not exist on arm64 - so a shape that
/// returned an aggregate would have to branch on the architecture. Nothing in
/// this framework needs one: sizes and indices come back as `NSUInteger`.
/// [ObjCSignature.hasAggregateReturn] exists so a test can assert that no
/// registered selector ever grows one.
///
/// ## Nothing is opened at import time
///
/// Every handle below is a lazy top-level final, exactly as
/// `backends/macos/io_surface.dart` does it and for the same reason: a probe
/// on Windows imports this file transitively and must neither pay for it nor
/// throw.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../foundation/lifecycle.dart';
import 'native_memory.dart';

/// An Objective-C instance or class. Classes are objects, so one type covers
/// both; the distinction lives in the selectors a caller sends, not in Dart.
final class ObjCObject extends Opaque {}

/// A registered selector - a `SEL`. Uniqued by the runtime, never freed.
final class ObjCSelector extends Opaque {}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

const String _libraryPath = 'libobjc.A.dylib';

DynamicLibrary? _library;
bool _libraryAttempted = false;
Object? _libraryError;

/// The runtime, or null when this machine has none.
///
/// Never throws. A probe that wants to say *why* reads [objcRuntimeLoadError]
/// afterwards, which is section 6.6's rule applied to a `dlopen`.
DynamicLibrary? tryLoadObjCRuntime() {
  if (_libraryAttempted) return _library;
  _libraryAttempted = true;
  try {
    _library = DynamicLibrary.open(_libraryPath);
  } on Object catch (error) {
    _libraryError = error;
    _library = null;
  }
  return _library;
}

/// Why [tryLoadObjCRuntime] returned null, or null when it did not.
Object? get objcRuntimeLoadError => _libraryError;

/// Whether an Objective-C runtime is present in this process.
bool get isObjCRuntimeAvailable => tryLoadObjCRuntime() != null;

DynamicLibrary get _runtime {
  final DynamicLibrary? library = tryLoadObjCRuntime();
  if (library != null) return library;
  throw StateError(
    'the Objective-C runtime is not available in this process: '
    '$_libraryPath could not be opened '
    '(${_libraryError ?? 'no reason reported'}). Guard with '
    'isObjCRuntimeAvailable before touching anything in objc_runtime.dart',
  );
}

// ---------------------------------------------------------------------------
// The three C entry points that are not messages
// ---------------------------------------------------------------------------

final Pointer<ObjCSelector> Function(Pointer<Uint8>) _selRegisterName =
    _runtime.lookupFunction<Pointer<ObjCSelector> Function(Pointer<Uint8>),
        Pointer<ObjCSelector> Function(Pointer<Uint8>)>('sel_registerName');

final Pointer<ObjCObject> Function(Pointer<Uint8>) _lookUpClass =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<Uint8>),
        Pointer<ObjCObject> Function(Pointer<Uint8>)>('objc_getClass');

/// `Class objc_getMetaClass(const char*)`.
///
/// Was named `_allocateClassPair0` in the first draft, next to the real
/// `_allocateClassPair`, which is how a caller reaching for "the one that
/// takes only a name" would have got a metaclass lookup instead of a class
/// creation. Renamed, because the two are one keystroke apart and one of them
/// returns a live object for a name nobody registered.
final Pointer<ObjCObject> Function(Pointer<Uint8>) _getMetaClass =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<Uint8>),
        Pointer<ObjCObject> Function(Pointer<Uint8>)>('objc_getMetaClass');

/// `Method class_getInstanceMethod(Class, SEL)`.
final Pointer<Void> Function(Pointer<ObjCObject>, Pointer<ObjCSelector>)
    _classGetInstanceMethod = _runtime.lookupFunction<
        Pointer<Void> Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        Pointer<Void> Function(Pointer<ObjCObject>,
            Pointer<ObjCSelector>)>('class_getInstanceMethod');

/// `const char* method_getTypeEncoding(Method)`.
final Pointer<Uint8> Function(Pointer<Void>) _methodGetTypeEncoding =
    _runtime.lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)>('method_getTypeEncoding');

/// `Method class_getClassMethod(Class, SEL)`.
///
/// The metaclass half of [_classGetInstanceMethod]. `+[NSObject alloc]` and
/// `+[MTLRenderPassDescriptor renderPassDescriptor]` are class methods, and
/// asking `class_getInstanceMethod` for either returns null - which reads as
/// "this selector does not exist" when it means "you asked the wrong side of
/// the class pair".
final Pointer<Void> Function(Pointer<ObjCObject>, Pointer<ObjCSelector>)
    _classGetClassMethod = _runtime.lookupFunction<
        Pointer<Void> Function(Pointer<ObjCObject>, Pointer<ObjCSelector>),
        Pointer<Void> Function(Pointer<ObjCObject>,
            Pointer<ObjCSelector>)>('class_getClassMethod');

/// `Class object_getClass(id)`.
final Pointer<ObjCObject> Function(Pointer<ObjCObject>) _objectGetClass =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<ObjCObject>),
        Pointer<ObjCObject> Function(Pointer<ObjCObject>)>('object_getClass');

/// `Protocol* objc_getProtocol(const char*)`.
final Pointer<ObjCObject> Function(Pointer<Uint8>) _getProtocol =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<Uint8>),
        Pointer<ObjCObject> Function(Pointer<Uint8>)>('objc_getProtocol');

/// `struct objc_method_description protocol_getMethodDescription(Protocol*,
/// SEL, BOOL isRequiredMethod, BOOL isInstanceMethod)`.
///
/// A **struct return by value**, and one of the few this file can afford: it is
/// a plain C function, so `dart:ffi` applies the platform's aggregate rule to
/// [ObjCMethodDescription] itself. The prohibition stated at the top is on
/// struct returns through `objc_msgSend`, which needs a different trampoline
/// per architecture; nothing of the sort applies here.
final ObjCMethodDescription Function(
        Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int)
    _protocolGetMethodDescription = _runtime.lookupFunction<
        ObjCMethodDescription Function(
            Pointer<ObjCObject>, Pointer<ObjCSelector>, Uint8, Uint8),
        ObjCMethodDescription Function(Pointer<ObjCObject>,
            Pointer<ObjCSelector>, int, int)>('protocol_getMethodDescription');

/// `Class objc_allocateClassPair(Class superclass, const char* name, size_t)`.
final Pointer<ObjCObject> Function(Pointer<ObjCObject>, Pointer<Uint8>, int)
    _allocateClassPair = _runtime.lookupFunction<
        Pointer<ObjCObject> Function(
            Pointer<ObjCObject>, Pointer<Uint8>, IntPtr),
        Pointer<ObjCObject> Function(Pointer<ObjCObject>, Pointer<Uint8>,
            int)>('objc_allocateClassPair');

/// `void objc_registerClassPair(Class)`.
final void Function(Pointer<ObjCObject>) _registerClassPair =
    _runtime.lookupFunction<Void Function(Pointer<ObjCObject>),
        void Function(Pointer<ObjCObject>)>('objc_registerClassPair');

/// `BOOL class_addMethod(Class, SEL, IMP, const char* types)`.
final int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, Pointer<Void>,
        Pointer<Uint8>) _classAddMethod =
    _runtime.lookupFunction<
        Uint8 Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
            Pointer<Void>, Pointer<Uint8>),
        int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, Pointer<Void>,
            Pointer<Uint8>)>('class_addMethod');

/// `id objc_retain(id)` / `void objc_release(id)` / `id objc_autorelease(id)`.
final Pointer<ObjCObject> Function(Pointer<ObjCObject>) _retain =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<ObjCObject>),
        Pointer<ObjCObject> Function(Pointer<ObjCObject>)>('objc_retain');

final void Function(Pointer<ObjCObject>) _release = _runtime.lookupFunction<
    Void Function(Pointer<ObjCObject>),
    void Function(Pointer<ObjCObject>)>('objc_release');

final Pointer<ObjCObject> Function(Pointer<ObjCObject>) _autorelease =
    _runtime.lookupFunction<Pointer<ObjCObject> Function(Pointer<ObjCObject>),
        Pointer<ObjCObject> Function(Pointer<ObjCObject>)>('objc_autorelease');

/// Three rules from Apple's own `metal-cpp` documentation that this binding
/// has to obey, written down because none of them announces itself at runtime.
///
/// **A pool is per thread, and a thread without one leaks.** Apple states it
/// plainly: the typical pool scope is one frame on the main thread, and *"you
/// are required to [create additional pools] for any additional threads your
/// program creates"*. That is not academic here. The recommended macOS backend
/// draws from a **worker process** ([`doc/adr/0005`]), so the isolate that
/// renders is never the thread AppKit drains, and every object returned by a
/// method whose name does **not** begin with `alloc`/`new`/`copy`/
/// `mutableCopy`/`Create` is autoreleased into a pool that will never exist
/// unless this code pushes one. A frame's worth of descriptors and command
/// buffers leaks per frame, silently, at a rate nothing reports.
///
/// **`OBJC_DEBUG_MISSING_POOLS=YES` turns that silence into a warning.** The
/// Objective-C runtime prints when an object is autoreleased with no enclosing
/// pool. It costs nothing to set in a smoke run on a Mac and is the only cheap
/// way to catch the rule above, since a leak is invisible until it is large.
///
/// **Calling a method on `nullptr` is legal and does nothing.** Apple is
/// explicit that `retain()` and `release()` on a null pointer are effectively
/// no-ops - and equally explicit about the trap that follows: *"do not assume
/// that because calling a method on a pointer did not result in a crash, that
/// the pointed-to object is valid."* So a smoke test that sends a message and
/// checks for absence of a crash proves **nothing** about whether the object
/// exists. Every test here that touches a real object asserts a returned
/// value, never merely survival.
final Pointer<Void> Function() _autoreleasePoolPush =
    _runtime.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
  'objc_autoreleasePoolPush',
);

final void Function(Pointer<Void>) _autoreleasePoolPop = _runtime
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
  'objc_autoreleasePoolPop',
);

// ---------------------------------------------------------------------------
// C strings
// ---------------------------------------------------------------------------

/// Encodes [value] as a NUL-terminated UTF-8 buffer the caller frees with
/// [objcFreeCString].
///
/// Selector names, class names and type encodings are ASCII by construction;
/// Metal shader source is UTF-8 and goes through the same call.
///
/// ## Why this is [NativeAllocator] and not `calloc`
///
/// The first draft of this file bound `calloc`/`free` out of
/// `DynamicLibrary.process()`, on the theory that the process always has a
/// libc. It does on macOS - and `DynamicLibrary.process()` is **unsupported on
/// Windows**, where it throws. That made every function on this path
/// unreachable from a Windows test, including the encoder, which is pure
/// arithmetic and is exactly the kind of thing that ought to be checkable
/// without a Mac. `native_memory.dart` already solved the same problem for
/// COM and picks `CoTaskMemAlloc` on Windows, so this file uses it and the
/// round trip below is covered by a test that runs anywhere.
Pointer<Uint8> objcAllocateCString(String value) {
  final Uint8List bytes = _encodeUtf8(value);
  final Pointer<Uint8> buffer =
      NativeAllocator.instance.allocate<Uint8>(bytes.length + 1);
  final Uint8List view = buffer.asTypedList(bytes.length + 1);
  view.setRange(0, bytes.length, bytes);
  // NativeAllocator zeroes, so the terminator is already there. Written
  // anyway, because "the allocator zeroes" is a property of the allocator and
  // not of this function's contract.
  view[bytes.length] = 0;
  return buffer;
}

/// Frees a buffer from [objcAllocateCString].
void objcFreeCString(Pointer<Uint8> buffer) =>
    NativeAllocator.instance.free(buffer);

/// The UTF-8 bytes of [value], surrogate pairs recombined.
///
/// Hand-rolled rather than `utf8.encode` for one reason that matters: this is
/// also how [objcCStringLength] and the block layout below stay free of
/// `dart:convert`, and the encoder is small enough that a test can enumerate
/// its four branches. It is the same table `NativeArena.allocateUtf8` gets
/// from the converter, and a test asserts they agree.
Uint8List _encodeUtf8(String value) {
  final List<int> bytes = <int>[];
  for (final int rune in value.runes) {
    if (rune < 0x80) {
      bytes.add(rune);
    } else if (rune < 0x800) {
      bytes
        ..add(0xC0 | (rune >> 6))
        ..add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      bytes
        ..add(0xE0 | (rune >> 12))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    } else {
      bytes
        ..add(0xF0 | (rune >> 18))
        ..add(0x80 | ((rune >> 12) & 0x3F))
        ..add(0x80 | ((rune >> 6) & 0x3F))
        ..add(0x80 | (rune & 0x3F));
    }
  }
  return Uint8List.fromList(bytes);
}

/// How many bytes [objcAllocateCString] will write for [value], terminator
/// excluded. Exposed so a caller sizing a buffer does not reach for
/// `value.length`, which is wrong for every string outside ASCII.
int objcCStringLength(String value) => _encodeUtf8(value).length;

/// Reads a NUL-terminated C string the runtime owns. Never frees it.
///
/// [limit] bounds the scan in **bytes**: a type encoding that is somehow not
/// terminated would otherwise be read past the end of whatever the runtime
/// allocated. Decoded as UTF-8 rather than latin-1 - the previous draft copied
/// each byte with `writeCharCode`, which mangles every class name outside
/// ASCII into mojibake instead of failing.
String objcReadCString(Pointer<Uint8> buffer, {int limit = 1 << 16}) =>
    readNativeUtf8(buffer, limit: limit);

// ---------------------------------------------------------------------------
// Selectors and classes
// ---------------------------------------------------------------------------

final Map<String, Pointer<ObjCSelector>> _selectorCache =
    <String, Pointer<ObjCSelector>>{};
final Map<String, Pointer<ObjCObject>> _classCache =
    <String, Pointer<ObjCObject>>{};

/// The `SEL` for [name], registered once and cached.
///
/// Cached because `sel_registerName` takes a C string, and building one per
/// call would allocate on the draw path. The runtime uniques selectors, so the
/// cache holds the same pointer the runtime would have returned anyway.
Pointer<ObjCSelector> objcSelector(String name) {
  final Pointer<ObjCSelector>? cached = _selectorCache[name];
  if (cached != null) return cached;
  final Pointer<Uint8> text = objcAllocateCString(name);
  try {
    final Pointer<ObjCSelector> selector = _selRegisterName(text);
    _selectorCache[name] = selector;
    return selector;
  } finally {
    objcFreeCString(text);
  }
}

/// The class named [name], or `nullptr` when the framework declaring it is not
/// loaded. Callers check rather than assume: a nil class turns every later
/// message into a silent no-op returning zero.
Pointer<ObjCObject> objcClass(String name) {
  final Pointer<ObjCObject>? cached = _classCache[name];
  if (cached != null) return cached;
  final Pointer<Uint8> text = objcAllocateCString(name);
  try {
    final Pointer<ObjCObject> value = _lookUpClass(text);
    if (value != nullptr) _classCache[name] = value;
    return value;
  } finally {
    objcFreeCString(text);
  }
}

/// The metaclass of [name]. Only needed when adding a class method to a class
/// registered by [ObjCClassBuilder].
Pointer<ObjCObject> objcMetaClass(String name) {
  final Pointer<Uint8> text = objcAllocateCString(name);
  try {
    return _getMetaClass(text);
  } finally {
    objcFreeCString(text);
  }
}

/// The type encoding the runtime records for `-[cls selector]`, or null when
/// the class does not implement it.
///
/// The strongest of the three matching mechanisms, and the only one that needs
/// a Mac. Compare against [ObjCSendShape.signature] via
/// [parseObjCTypeEncoding].
String? objcMethodTypeEncoding(
  Pointer<ObjCObject> cls,
  String selector,
) {
  if (cls == nullptr) return null;
  final Pointer<Void> method =
      _classGetInstanceMethod(cls, objcSelector(selector));
  if (method == nullptr) return null;
  final Pointer<Uint8> encoding = _methodGetTypeEncoding(method);
  if (encoding == nullptr) return null;
  return objcReadCString(encoding);
}

/// The type encoding the runtime records for `+[cls selector]` - the class
/// method, not the instance one.
String? objcClassMethodTypeEncoding(
  Pointer<ObjCObject> cls,
  String selector,
) {
  if (cls == nullptr) return null;
  final Pointer<Void> method =
      _classGetClassMethod(cls, objcSelector(selector));
  if (method == nullptr) return null;
  final Pointer<Uint8> encoding = _methodGetTypeEncoding(method);
  if (encoding == nullptr) return null;
  return objcReadCString(encoding);
}

/// `object_getClass` - the class an instance really is.
///
/// Not the same as `-[NSObject class]`, which a proxy may lie about, and the
/// only way to reach the *implementation* of a protocol method: `MTLDevice` is
/// a protocol, and the object `MTLCreateSystemDefaultDevice` returns is some
/// private concrete class that conforms to it.
Pointer<ObjCObject> objcClassOfObject(Pointer<ObjCObject> object) {
  if (object == nullptr) return nullptr;
  return _objectGetClass(object);
}

/// `struct objc_method_description` - a selector and its type encoding.
final class ObjCMethodDescription extends Struct {
  external Pointer<ObjCSelector> name;
  external Pointer<Uint8> types;
}

/// The protocol named [name], or `nullptr` when nothing has declared it.
///
/// Most of Metal is protocols rather than classes - `MTLDevice`, `MTLTexture`,
/// `MTLCommandBuffer` and `MTLRenderCommandEncoder` are all `@protocol`, and
/// `objc_getClass("MTLDevice")` returns nil for every one of them. A check that
/// only knew about classes would silently skip two thirds of this framework's
/// selectors and report that it had verified them.
Pointer<ObjCObject> objcProtocol(String name) {
  final Pointer<Uint8> text = objcAllocateCString(name);
  try {
    return _getProtocol(text);
  } finally {
    objcFreeCString(text);
  }
}

/// The type encoding [protocol] declares for [selector], or null.
///
/// A protocol keeps four separate method lists - required/optional crossed with
/// instance/class - and `protocol_getMethodDescription` answers for exactly one
/// of them. All four are tried, because the split is not visible from the
/// selector and a method declared optional would otherwise read as absent. A
/// `@property` ends up in these lists as its accessors, which is how
/// `-[MTLDevice name]` is found.
String? objcProtocolMethodTypeEncoding(
  Pointer<ObjCObject> protocol,
  String selector,
) {
  if (protocol == nullptr) return null;
  final Pointer<ObjCSelector> sel = objcSelector(selector);
  for (final bool required in <bool>[true, false]) {
    for (final bool instance in <bool>[true, false]) {
      final ObjCMethodDescription description = _protocolGetMethodDescription(
        protocol,
        sel,
        required ? 1 : 0,
        instance ? 1 : 0,
      );
      // A miss is `{nil, nil}`, not an error. Both fields are checked because
      // the encoding is the only half a caller can use.
      if (description.name == nullptr || description.types == nullptr) continue;
      return objcReadCString(description.types);
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Type encodings - section 20.5's "gerar e testar variantes", as data
// ---------------------------------------------------------------------------

/// How one value travels, once the calling convention has classified it.
///
/// Deliberately coarser than the Objective-C encoding alphabet. `c`, `i`, `q`,
/// `Q`, `B`, `@`, `:`, `#` and every pointer all arrive in one general-purpose
/// register on both architectures this framework targets, so distinguishing
/// them would multiply the shape table without catching a single ABI mismatch.
/// What *does* change the register file is the float/integer split and
/// aggregates, and those are the members that exist.
enum ObjCAbiClass {
  /// `v`. Only ever a return.
  none,

  /// One general-purpose register: every integer width, `BOOL`, `id`, `SEL`,
  /// `Class`, and every pointer.
  word,

  /// `f` - one 32-bit floating-point register.
  float32,

  /// `d` - one 64-bit floating-point register.
  float64,

  /// `{...}`, `(...)` or `[...]`. Passed by the aggregate rules, which differ
  /// between arm64 and x86_64; `dart:ffi` implements both from the [Struct]
  /// declaration, which is why an aggregate argument gets a shape of its own
  /// with a real struct type rather than a word.
  aggregate,
}

/// The shape of one Objective-C method call, as ABI classes.
final class ObjCSignature {
  const ObjCSignature(this.returnClass, this.argumentClasses);

  final ObjCAbiClass returnClass;

  /// Receiver first, selector second, then the declared arguments. Always at
  /// least two entries, both [ObjCAbiClass.word].
  final List<ObjCAbiClass> argumentClasses;

  /// Declared arguments, excluding the receiver and the selector.
  int get explicitArgumentCount => argumentClasses.length - 2;

  bool get hasAggregateReturn => returnClass == ObjCAbiClass.aggregate;

  bool get hasAggregateArgument =>
      argumentClasses.contains(ObjCAbiClass.aggregate);

  @override
  bool operator ==(Object other) {
    if (other is! ObjCSignature) return false;
    if (other.returnClass != returnClass) return false;
    if (other.argumentClasses.length != argumentClasses.length) return false;
    for (var i = 0; i < argumentClasses.length; i++) {
      if (other.argumentClasses[i] != argumentClasses[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(returnClass, Object.hashAll(argumentClasses));

  @override
  String toString() => 'ObjCSignature(${returnClass.name} <- '
      '${argumentClasses.map((ObjCAbiClass c) => c.name).join(', ')})';
}

/// Raised when a type encoding cannot be read. Carries the offset, because the
/// encodings that fail are the ones with a nested struct and a bare index is
/// useless for finding which one.
final class ObjCTypeEncodingError extends Error {
  ObjCTypeEncodingError(this.encoding, this.offset, this.message);

  final String encoding;
  final int offset;
  final String message;

  @override
  String toString() =>
      'ObjCTypeEncodingError: $message at offset $offset of "$encoding"';
}

const int _charDigit0 = 0x30;
const int _charDigit9 = 0x39;

/// Parses an Objective-C type encoding into the ABI shape it implies.
///
/// Accepts both spellings the runtime produces:
///
///   * bare, as a header would be transcribed - `v@:Q`;
///   * with frame offsets, as `method_getTypeEncoding` returns them -
///     `v24@0:8Q16`.
///
/// The offsets are skipped rather than checked. They are the *old* frame
/// layout of a stack-based calling convention and are meaningless on arm64;
/// treating them as authoritative is a classic way to derive a wrong shape
/// from a right encoding.
ObjCSignature parseObjCTypeEncoding(String encoding) {
  final _EncodingReader reader = _EncodingReader(encoding);
  final ObjCAbiClass returnClass = reader.readType();
  final List<ObjCAbiClass> arguments = <ObjCAbiClass>[];
  while (!reader.atEnd) {
    arguments.add(reader.readType());
  }
  if (arguments.length < 2) {
    throw ObjCTypeEncodingError(
      encoding,
      encoding.length,
      'an Objective-C method takes at least a receiver and a selector; '
      'found ${arguments.length} argument(s)',
    );
  }
  return ObjCSignature(returnClass, arguments);
}

final class _EncodingReader {
  _EncodingReader(this.source);

  final String source;
  int offset = 0;

  bool get atEnd {
    _skipNoise();
    return offset >= source.length;
  }

  void _skipNoise() {
    while (offset < source.length) {
      final int code = source.codeUnitAt(offset);
      if (code >= _charDigit0 && code <= _charDigit9) {
        offset++;
        continue;
      }
      // Method-encoding qualifiers: const, in, inout, out, bycopy, byref,
      // oneway, and the GC write-barrier markers. They change nothing about
      // how the value travels.
      const String qualifiers = 'rnNoORV';
      if (qualifiers.contains(source[offset])) {
        offset++;
        continue;
      }
      return;
    }
  }

  ObjCAbiClass readType() {
    _skipNoise();
    if (offset >= source.length) {
      throw ObjCTypeEncodingError(source, offset, 'unexpected end of encoding');
    }
    final String c = source[offset++];
    switch (c) {
      case 'v':
        return ObjCAbiClass.none;
      case 'f':
        return ObjCAbiClass.float32;
      case 'd':
        return ObjCAbiClass.float64;
      case 'c':
      case 'C':
      case 's':
      case 'S':
      case 'i':
      case 'I':
      case 'l':
      case 'L':
      case 'q':
      case 'Q':
      case 'B':
      case ':':
      case '#':
      case '*':
      case '?':
        return ObjCAbiClass.word;
      case '@':
        // `@` alone is `id`, but two suffixes belong to it and are *not*
        // separate arguments:
        //
        //   * `@?` - a block. `addCompletedHandler:` is encoded `v@:@?`, and a
        //     reader that took the `?` for a second argument would compute a
        //     three-argument signature for a one-argument method and reject
        //     the correct shape.
        //   * `@"NSString"` - an object with its class named, which is what
        //     `method_getTypeEncoding` returns for a good deal of AppKit.
        //
        // Both are still one `id` in one general-purpose register; only the
        // *count* was wrong before, which is exactly the kind of error that
        // makes the shape check reject a correct call site and get switched
        // off.
        if (offset < source.length) {
          final String suffix = source[offset];
          if (suffix == '?') {
            offset++;
          } else if (suffix == '"') {
            offset++;
            while (offset < source.length && source[offset] != '"') {
              offset++;
            }
            if (offset >= source.length) {
              throw ObjCTypeEncodingError(
                source,
                offset,
                'unterminated class name after "@"',
              );
            }
            offset++;
          }
        }
        return ObjCAbiClass.word;
      case '^':
        // A pointer to anything is still a pointer; the pointee is consumed so
        // that `^{CGImage=}` does not leave a stray struct behind.
        readType();
        return ObjCAbiClass.word;
      case 'j':
      case 'A':
        // _Complex and _Atomic take a following type. Neither appears in any
        // API this framework calls; consuming them keeps the parser honest
        // rather than silently misaligning the rest of the string.
        readType();
        return ObjCAbiClass.aggregate;
      case '{':
        _skipBalanced('{', '}');
        return ObjCAbiClass.aggregate;
      case '(':
        _skipBalanced('(', ')');
        return ObjCAbiClass.aggregate;
      case '[':
        _skipBalanced('[', ']');
        return ObjCAbiClass.aggregate;
      case 'b':
        // Bitfield: `b` followed by a width. The width is digits, which
        // _skipNoise eats on the next read.
        return ObjCAbiClass.word;
      default:
        throw ObjCTypeEncodingError(
          source,
          offset - 1,
          'unknown type code "$c"',
        );
    }
  }

  void _skipBalanced(String open, String close) {
    var depth = 1;
    while (offset < source.length) {
      final String c = source[offset++];
      if (c == open) {
        depth++;
      } else if (c == close) {
        depth--;
        if (depth == 0) return;
      }
    }
    throw ObjCTypeEncodingError(
      source,
      offset,
      'unterminated "$open" group',
    );
  }
}

// ---------------------------------------------------------------------------
// The closed set of send shapes
// ---------------------------------------------------------------------------

const List<ObjCAbiClass> _args0 = <ObjCAbiClass>[];
const List<ObjCAbiClass> _args1w = <ObjCAbiClass>[ObjCAbiClass.word];
const List<ObjCAbiClass> _args2w = <ObjCAbiClass>[
  ObjCAbiClass.word,
  ObjCAbiClass.word,
];
const List<ObjCAbiClass> _args3w = <ObjCAbiClass>[
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
];
const List<ObjCAbiClass> _args4w = <ObjCAbiClass>[
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
];
const List<ObjCAbiClass> _args5w = <ObjCAbiClass>[
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
];
const List<ObjCAbiClass> _args1a = <ObjCAbiClass>[ObjCAbiClass.aggregate];
const List<ObjCAbiClass> _argsA3w = <ObjCAbiClass>[
  ObjCAbiClass.aggregate,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.word,
];
const List<ObjCAbiClass> _args2wA1w = <ObjCAbiClass>[
  ObjCAbiClass.word,
  ObjCAbiClass.word,
  ObjCAbiClass.aggregate,
  ObjCAbiClass.word,
];

/// Every message shape this framework is allowed to send.
///
/// The word-argument members cover any argument list of that length whose
/// elements all fit a general-purpose register. Aggregate arguments get their
/// own member with a real [Struct] type, because that is the only way
/// `dart:ffi` can apply the platform's aggregate rules.
///
/// [signature] is the shape as declared *here*; a selector's registered
/// encoding is parsed and compared against it. The two agreeing is the whole
/// guarantee, and it is checked by a test that needs no Mac.
///
/// ## The aggregate members, and the comment they exist to refute
///
/// `poc/poc_07_metal/lib/metal_bindings.dart` declares `MTLClearColor` - four
/// `double`s - with the note *"on both arm64 and x86_64 it fits in two GP
/// registers (16 bytes per pair), so the standard `objc_msgSend` trampoline
/// handles it as a value argument"*. That is wrong twice over, and it is the
/// exact class of wrongness this enum exists to make impossible:
///
///   * it is **32 bytes**, not 16, and no part of it goes in a general-purpose
///     register on either architecture;
///   * on arm64 it is a homogeneous float aggregate and travels in `d0..d3`
///     (AAPCS64 stage B.1), while under System V on x86_64 a 32-byte aggregate
///     is class MEMORY and travels on the **stack**.
///
/// The POC worked anyway, because `dart:ffi` was given the real [Struct] type
/// and applied the right rule per architecture - which is precisely why the
/// aggregate shapes here carry a `Struct` and not a pair of `IntPtr`s. A
/// call site that "flattened" a `CGSize` into two `IntPtr` arguments would
/// compile, run, and read two integers out of `x2`/`x3` that nobody wrote.
enum ObjCSendShape {
  /// `id (*)(id, SEL)`
  pointerReturn0(ObjCAbiClass.word, _args0),

  /// `id (*)(id, SEL, uintptr_t)`
  pointerReturn1(ObjCAbiClass.word, _args1w),

  /// `id (*)(id, SEL, uintptr_t, uintptr_t)`
  pointerReturn2(ObjCAbiClass.word, _args2w),

  /// `id (*)(id, SEL, uintptr_t, uintptr_t, uintptr_t)`
  pointerReturn3(ObjCAbiClass.word, _args3w),

  /// `id (*)(id, SEL, uintptr_t x 4)` - `+[MTLTextureDescriptor
  /// texture2DDescriptorWithPixelFormat:width:height:mipmapped:]`.
  pointerReturn4(ObjCAbiClass.word, _args4w),

  /// `void (*)(id, SEL)`
  voidReturn0(ObjCAbiClass.none, _args0),

  /// `void (*)(id, SEL, uintptr_t)`
  voidReturn1(ObjCAbiClass.none, _args1w),

  /// `void (*)(id, SEL, uintptr_t, uintptr_t)`
  voidReturn2(ObjCAbiClass.none, _args2w),

  /// `void (*)(id, SEL, uintptr_t, uintptr_t, uintptr_t)`
  voidReturn3(ObjCAbiClass.none, _args3w),

  /// `void (*)(id, SEL, uintptr_t x 4)`
  voidReturn4(ObjCAbiClass.none, _args4w),

  /// `void (*)(id, SEL, uintptr_t x 5)`
  voidReturn5(ObjCAbiClass.none, _args5w),

  /// `BOOL (*)(id, SEL)` - still one word; named apart from
  /// [pointerReturn0] only so a call site reads correctly.
  boolReturn0(ObjCAbiClass.word, _args0),

  /// `BOOL (*)(id, SEL, uintptr_t)`
  boolReturn1(ObjCAbiClass.word, _args1w),

  /// `NSUInteger (*)(id, SEL)`
  unsignedReturn0(ObjCAbiClass.word, _args0),

  /// `NSUInteger (*)(id, SEL, uintptr_t)`
  unsignedReturn1(ObjCAbiClass.word, _args1w),

  /// `void (*)(id, SEL, CGSize)` - `-[CAMetalLayer setDrawableSize:]`.
  /// Two `double`s: `d0`/`d1` on arm64, `xmm0`/`xmm1` under System V.
  voidReturnDouble2(ObjCAbiClass.none, _args1a),

  /// `void (*)(id, SEL, MTLClearColor)` and `void (*)(id, SEL, CGRect)`.
  /// Four `double`s. See the enum comment for why this is not two words.
  voidReturnDouble4(ObjCAbiClass.none, _args1a),

  /// `void (*)(id, SEL, MTLViewport)` - `-[MTLRenderCommandEncoder
  /// setViewport:]`. Six `double`s: still an HFA on arm64 (`d0..d5`), still
  /// MEMORY under System V.
  voidReturnDouble6(ObjCAbiClass.none, _args1a),

  /// `void (*)(id, SEL, MTLScissorRect)` - four `NSUInteger`s, so 32 bytes and
  /// *not* an HFA: arm64 passes it indirectly (AAPCS64 stage B.3, the caller
  /// copies it and passes a pointer) and System V puts it on the stack.
  voidReturnWord4(ObjCAbiClass.none, _args1a),

  /// `void (*)(id, SEL, MTLRegion, NSUInteger, const void*, NSUInteger)` -
  /// `-[MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:]`.
  ///
  /// The one shape here that mixes an aggregate with words, and the reason
  /// [ObjCSignature] keeps the classes in order rather than counting them: on
  /// arm64 the 48-byte `MTLRegion` is passed indirectly, so `mipmapLevel`
  /// lands in `x3` and not in `x2`, and a caller that guessed would upload
  /// every texture at the wrong mip level.
  voidReturnRegionLevelBytesStride(ObjCAbiClass.none, _argsA3w),

  /// `void (*)(id, SEL, void*, NSUInteger, MTLRegion, NSUInteger)` -
  /// `-[MTLTexture getBytes:bytesPerRow:fromRegion:mipmapLevel:]`, the
  /// readback that makes a rendered texture comparable against the CPU
  /// rasteriser.
  ///
  /// The mirror image of [voidReturnRegionLevelBytesStride] and a separate
  /// member for exactly that reason: the two selectors take the same four
  /// values in the opposite order, so one shape could not serve both and a
  /// call site that reused the upload's shape for the readback would hand the
  /// driver a destination pointer where it expects a rectangle.
  voidReturnBytesStrideRegionLevel(ObjCAbiClass.none, _args2wA1w);

  const ObjCSendShape(this._returnClass, this._declaredArguments);

  final ObjCAbiClass _returnClass;
  final List<ObjCAbiClass> _declaredArguments;

  /// The shape as this file implements it, for comparison against a parsed
  /// type encoding.
  ObjCSignature get signature => ObjCSignature(
        _returnClass,
        <ObjCAbiClass>[
          ObjCAbiClass.word,
          ObjCAbiClass.word,
          ..._declaredArguments,
        ],
      );
}

/// The single trampoline every typed sender below is a cast of.
Pointer<NativeFunction<Void Function()>> get _sendBase =>
    _runtime.lookup<NativeFunction<Void Function()>>('objc_msgSend');

typedef _P0N = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _P0D = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _P1N = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr);
typedef _P1D = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int);
typedef _P2N = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr);
typedef _P2D = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int);
typedef _P3N = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr, IntPtr);
typedef _P3D = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int, int);
typedef _P4N = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr, IntPtr, IntPtr);
typedef _P4D = Pointer<ObjCObject> Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int, int, int);

typedef _V0N = Void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _V0D = void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _V1N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr);
typedef _V1D = void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, int);
typedef _V2N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr);
typedef _V2D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int);
typedef _V3N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr, IntPtr);
typedef _V3D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int, int);
typedef _V4N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr, IntPtr, IntPtr, IntPtr);
typedef _V4D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int, int, int);
typedef _V5N = Void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr,
    IntPtr, IntPtr, IntPtr, IntPtr);
typedef _V5D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, int, int, int, int, int);

typedef _B0N = Uint8 Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _B0D = int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _B1N = Uint8 Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr);
typedef _B1D = int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, int);

typedef _U0N = UintPtr Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _U0D = int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>);
typedef _U1N = UintPtr Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, IntPtr);
typedef _U1D = int Function(Pointer<ObjCObject>, Pointer<ObjCSelector>, int);

final _P0D _sendPointer0 =
    _sendBase.cast<NativeFunction<_P0N>>().asFunction<_P0D>();
final _P1D _sendPointer1 =
    _sendBase.cast<NativeFunction<_P1N>>().asFunction<_P1D>();
final _P2D _sendPointer2 =
    _sendBase.cast<NativeFunction<_P2N>>().asFunction<_P2D>();
final _P3D _sendPointer3 =
    _sendBase.cast<NativeFunction<_P3N>>().asFunction<_P3D>();
final _P4D _sendPointer4 =
    _sendBase.cast<NativeFunction<_P4N>>().asFunction<_P4D>();

final _V0D _sendVoid0 =
    _sendBase.cast<NativeFunction<_V0N>>().asFunction<_V0D>();
final _V1D _sendVoid1 =
    _sendBase.cast<NativeFunction<_V1N>>().asFunction<_V1D>();
final _V2D _sendVoid2 =
    _sendBase.cast<NativeFunction<_V2N>>().asFunction<_V2D>();
final _V3D _sendVoid3 =
    _sendBase.cast<NativeFunction<_V3N>>().asFunction<_V3D>();
final _V4D _sendVoid4 =
    _sendBase.cast<NativeFunction<_V4N>>().asFunction<_V4D>();
final _V5D _sendVoid5 =
    _sendBase.cast<NativeFunction<_V5N>>().asFunction<_V5D>();

final _B0D _sendBool0 =
    _sendBase.cast<NativeFunction<_B0N>>().asFunction<_B0D>();
final _B1D _sendBool1 =
    _sendBase.cast<NativeFunction<_B1N>>().asFunction<_B1D>();

final _U0D _sendUnsigned0 =
    _sendBase.cast<NativeFunction<_U0N>>().asFunction<_U0D>();
final _U1D _sendUnsigned1 =
    _sendBase.cast<NativeFunction<_U1N>>().asFunction<_U1D>();

/// `id` result, no declared arguments.
Pointer<ObjCObject> objcSendPointer(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
) =>
    _sendPointer0(target, selector);

/// `id` result, one word argument.
Pointer<ObjCObject> objcSendPointer1(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
) =>
    _sendPointer1(target, selector, a0);

/// `id` result, two word arguments.
Pointer<ObjCObject> objcSendPointer2(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
) =>
    _sendPointer2(target, selector, a0, a1);

/// `id` result, three word arguments.
Pointer<ObjCObject> objcSendPointer3(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
  int a2,
) =>
    _sendPointer3(target, selector, a0, a1, a2);

/// `id` result, four word arguments.
Pointer<ObjCObject> objcSendPointer4(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
  int a2,
  int a3,
) =>
    _sendPointer4(target, selector, a0, a1, a2, a3);

/// `void` result, no declared arguments.
void objcSendVoid(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
) =>
    _sendVoid0(target, selector);

/// `void` result, one word argument.
void objcSendVoid1(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
) =>
    _sendVoid1(target, selector, a0);

/// `void` result, two word arguments.
void objcSendVoid2(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
) =>
    _sendVoid2(target, selector, a0, a1);

/// `void` result, three word arguments.
void objcSendVoid3(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
  int a2,
) =>
    _sendVoid3(target, selector, a0, a1, a2);

/// `void` result, four word arguments.
void objcSendVoid4(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
  int a2,
  int a3,
) =>
    _sendVoid4(target, selector, a0, a1, a2, a3);

/// `void` result, five word arguments.
void objcSendVoid5(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
  int a1,
  int a2,
  int a3,
  int a4,
) =>
    _sendVoid5(target, selector, a0, a1, a2, a3, a4);

/// `BOOL` result, no declared arguments.
bool objcSendBool(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
) =>
    _sendBool0(target, selector) != 0;

/// `BOOL` result, one word argument.
bool objcSendBool1(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
) =>
    _sendBool1(target, selector, a0) != 0;

/// `NSUInteger` result, no declared arguments.
int objcSendUnsigned(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
) =>
    _sendUnsigned0(target, selector);

/// `NSUInteger` result, one word argument.
int objcSendUnsigned1(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  int a0,
) =>
    _sendUnsigned1(target, selector, a0);

/// The trampoline, for a caller that needs an aggregate-argument shape this
/// file does not declare.
///
/// Exposed rather than hidden because the alternative is a caller looking the
/// symbol up itself, with no comment attached. A caller that casts this **must
/// not** use it for a struct *return*: `objc_msgSend` is the wrong trampoline
/// for one on x86_64, and the right one does not exist on arm64.
Pointer<NativeFunction<Void Function()>> get objcSendTrampoline => _sendBase;

// ---------------------------------------------------------------------------
// Aggregate arguments
// ---------------------------------------------------------------------------

/// Two `double`s by value - `CGSize`, `CGPoint`, `NSSize`, `NSPoint`.
///
/// Named for its ABI shape rather than for any one of those, because the
/// register allocation is what this type exists to get right and all four are
/// the same to the calling convention. A call site says which one it means.
final class ObjCDouble2 extends Struct {
  @Double()
  external double a0;
  @Double()
  external double a1;
}

/// Four `double`s by value - `CGRect`, `NSRect`, `MTLClearColor`.
///
/// A homogeneous float aggregate on arm64 (`d0..d3`); class MEMORY under
/// System V on x86_64, so it goes on the stack there. Neither is a decision
/// this file makes: `dart:ffi` applies the platform rule to the [Struct], and
/// that is the entire reason the type is declared instead of flattened.
final class ObjCDouble4 extends Struct {
  @Double()
  external double a0;
  @Double()
  external double a1;
  @Double()
  external double a2;
  @Double()
  external double a3;
}

/// Six `double`s by value - `MTLViewport`.
final class ObjCDouble6 extends Struct {
  @Double()
  external double a0;
  @Double()
  external double a1;
  @Double()
  external double a2;
  @Double()
  external double a3;
  @Double()
  external double a4;
  @Double()
  external double a5;
}

/// Four `NSUInteger`s by value - `MTLScissorRect`.
///
/// The same 32 bytes as [ObjCDouble4] and a completely different journey: not
/// homogeneous-float, so arm64 passes it **indirectly** - the caller copies it
/// somewhere and passes the address (AAPCS64 stage B.3). Two structs of equal
/// size travelling differently is the single most convincing reason this file
/// refuses to let a call site describe an argument as "32 bytes".
final class ObjCWord4 extends Struct {
  @UintPtr()
  external int a0;
  @UintPtr()
  external int a1;
  @UintPtr()
  external int a2;
  @UintPtr()
  external int a3;
}

/// Six `NSUInteger`s by value - `MTLRegion`, which is an `MTLOrigin` (three)
/// followed by an `MTLSize` (three). Flat here because a nested struct of
/// three words and a flat six-word struct have the same layout and the same
/// classification, and the flat one can be filled without a second accessor.
final class ObjCWord6 extends Struct {
  @UintPtr()
  external int a0;
  @UintPtr()
  external int a1;
  @UintPtr()
  external int a2;
  @UintPtr()
  external int a3;
  @UintPtr()
  external int a4;
  @UintPtr()
  external int a5;
}

typedef _VD2N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble2);
typedef _VD2D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble2);
typedef _VD4N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble4);
typedef _VD4D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble4);
typedef _VD6N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble6);
typedef _VD6D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCDouble6);
typedef _VW4N = Void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCWord4);
typedef _VW4D = void Function(
    Pointer<ObjCObject>, Pointer<ObjCSelector>, ObjCWord4);
typedef _VRegionN = Void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
    ObjCWord6, UintPtr, Pointer<Void>, UintPtr);
typedef _VRegionD = void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
    ObjCWord6, int, Pointer<Void>, int);
typedef _VGetBytesN = Void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
    Pointer<Void>, UintPtr, ObjCWord6, UintPtr);
typedef _VGetBytesD = void Function(Pointer<ObjCObject>, Pointer<ObjCSelector>,
    Pointer<Void>, int, ObjCWord6, int);

final _VD2D _sendVoidDouble2 =
    _sendBase.cast<NativeFunction<_VD2N>>().asFunction<_VD2D>();
final _VD4D _sendVoidDouble4 =
    _sendBase.cast<NativeFunction<_VD4N>>().asFunction<_VD4D>();
final _VD6D _sendVoidDouble6 =
    _sendBase.cast<NativeFunction<_VD6N>>().asFunction<_VD6D>();
final _VW4D _sendVoidWord4 =
    _sendBase.cast<NativeFunction<_VW4N>>().asFunction<_VW4D>();
final _VRegionD _sendVoidRegion =
    _sendBase.cast<NativeFunction<_VRegionN>>().asFunction<_VRegionD>();
final _VGetBytesD _sendVoidGetBytes =
    _sendBase.cast<NativeFunction<_VGetBytesN>>().asFunction<_VGetBytesD>();

/// `void` result, one [ObjCDouble2] by value.
void objcSendVoidDouble2(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  ObjCDouble2 value,
) =>
    _sendVoidDouble2(target, selector, value);

/// `void` result, one [ObjCDouble4] by value.
void objcSendVoidDouble4(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  ObjCDouble4 value,
) =>
    _sendVoidDouble4(target, selector, value);

/// `void` result, one [ObjCDouble6] by value.
void objcSendVoidDouble6(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  ObjCDouble6 value,
) =>
    _sendVoidDouble6(target, selector, value);

/// `void` result, one [ObjCWord4] by value.
void objcSendVoidWord4(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  ObjCWord4 value,
) =>
    _sendVoidWord4(target, selector, value);

/// `void` result, an [ObjCWord6] followed by three words - exactly
/// `-[MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:]`.
void objcSendVoidRegion(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  ObjCWord6 region,
  int mipmapLevel,
  Pointer<Void> bytes,
  int bytesPerRow,
) =>
    _sendVoidRegion(target, selector, region, mipmapLevel, bytes, bytesPerRow);

/// `void` result, a destination pointer and a stride followed by an
/// [ObjCWord6] and a level - exactly `-[MTLTexture
/// getBytes:bytesPerRow:fromRegion:mipmapLevel:]`.
void objcSendVoidGetBytes(
  Pointer<ObjCObject> target,
  Pointer<ObjCSelector> selector,
  Pointer<Void> bytes,
  int bytesPerRow,
  ObjCWord6 region,
  int mipmapLevel,
) =>
    _sendVoidGetBytes(
        target, selector, bytes, bytesPerRow, region, mipmapLevel);

/// Builds an [ObjCDouble2] without a heap allocation.
///
/// `Struct.create` gives a struct instance backed by memory `dart:ffi` owns for
/// the duration of the call, which is what an argument passed *by value* needs.
/// The alternative - allocating, filling, passing `.ref` and freeing - is three
/// extra operations per `setDrawableSize:` and one more chance to leak on a
/// throw.
ObjCDouble2 objcDouble2(double a0, double a1) {
  final ObjCDouble2 value = Struct.create<ObjCDouble2>();
  value
    ..a0 = a0
    ..a1 = a1;
  return value;
}

/// Builds an [ObjCDouble4]. See [objcDouble2].
ObjCDouble4 objcDouble4(double a0, double a1, double a2, double a3) {
  final ObjCDouble4 value = Struct.create<ObjCDouble4>();
  value
    ..a0 = a0
    ..a1 = a1
    ..a2 = a2
    ..a3 = a3;
  return value;
}

/// Builds an [ObjCDouble6]. See [objcDouble2].
ObjCDouble6 objcDouble6(
  double a0,
  double a1,
  double a2,
  double a3,
  double a4,
  double a5,
) {
  final ObjCDouble6 value = Struct.create<ObjCDouble6>();
  value
    ..a0 = a0
    ..a1 = a1
    ..a2 = a2
    ..a3 = a3
    ..a4 = a4
    ..a5 = a5;
  return value;
}

/// Builds an [ObjCWord4]. See [objcDouble2].
ObjCWord4 objcWord4(int a0, int a1, int a2, int a3) {
  final ObjCWord4 value = Struct.create<ObjCWord4>();
  value
    ..a0 = a0
    ..a1 = a1
    ..a2 = a2
    ..a3 = a3;
  return value;
}

/// Builds an [ObjCWord6]. See [objcDouble2].
ObjCWord6 objcWord6(int a0, int a1, int a2, int a3, int a4, int a5) {
  final ObjCWord6 value = Struct.create<ObjCWord6>();
  value
    ..a0 = a0
    ..a1 = a1
    ..a2 = a2
    ..a3 = a3
    ..a4 = a4
    ..a5 = a5;
  return value;
}

// ---------------------------------------------------------------------------
// Ownership - section 20.6
// ---------------------------------------------------------------------------

/// Whether a selector returns an object the caller owns.
///
/// The rule is Objective-C's, not a convention this file invents: a method
/// whose name begins with `alloc`, `new`, `copy`, `mutableCopy` or `init`
/// returns a **+1** reference, and everything else returns a borrowed or
/// autoreleased one. Getting it backwards leaks in one direction and
/// over-releases in the other, and over-releasing a Metal object crashes
/// several frames later inside the driver.
///
/// The prefix must end at a word boundary. `newCommandQueue` is owned;
/// `newer` is not, and neither is `copyright`. This is why the check is a
/// function with a test rather than five `startsWith` calls at the call sites.
bool objcSelectorReturnsOwned(String selector) {
  const List<String> owningPrefixes = <String>[
    'alloc',
    'copy',
    'mutableCopy',
    'new',
    'init',
  ];
  for (final String prefix in owningPrefixes) {
    if (!selector.startsWith(prefix)) continue;
    if (selector.length == prefix.length) return true;
    final String next = selector[prefix.length];
    // A word boundary: the next character is not a lowercase letter. `_` is
    // treated as a boundary too, which matches the runtime's own
    // implementation of the naming convention.
    if (next.toLowerCase() != next || next == '_') return true;
  }
  return false;
}

/// `objc_retain`. Returns [object] so it can be used in an initialiser.
Pointer<ObjCObject> objcRetain(Pointer<ObjCObject> object) {
  if (object == nullptr) return object;
  return _retain(object);
}

/// `objc_release`. A no-op on `nullptr`, so a teardown after a failed
/// construction does not have to test every field.
void objcRelease(Pointer<ObjCObject> object) {
  if (object == nullptr) return;
  _release(object);
}

/// `objc_autorelease`.
Pointer<ObjCObject> objcAutorelease(Pointer<ObjCObject> object) {
  if (object == nullptr) return object;
  return _autorelease(object);
}

/// One `@autoreleasepool { }`, as an object with a lifetime.
///
/// Section 20.6 asks for a pool per frame or per iteration, and this is it.
/// The pop **must** happen on the same thread as the push and in the reverse
/// order of nesting; the runtime detects a mismatch and aborts the process, so
/// getting it wrong is loud rather than subtle - the one place in this file
/// where that is true.
final class ObjCAutoreleasePool with DisposableMixin {
  ObjCAutoreleasePool() : _token = _autoreleasePoolPush();

  final Pointer<Void> _token;

  /// Runs [body] inside a pool, draining it afterwards even if [body] throws.
  static T run<T>(T Function() body) {
    final ObjCAutoreleasePool pool = ObjCAutoreleasePool();
    try {
      return body();
    } finally {
      pool.dispose();
    }
  }

  @override
  void onDispose() => _autoreleasePoolPop(_token);
}

/// An owned Objective-C reference whose release is registered with a
/// [DisposableBag].
///
/// The bag is what makes the order right: `lifecycle.dart` releases in reverse
/// acquisition order, which is exactly the order Metal objects want - an
/// encoder before its command buffer, a pipeline state before the library it
/// was built from, a texture before the device.
///
/// [adopt] takes a +1 reference and does not retain again; [borrow] retains
/// first. Which one a call site wants is decided by
/// [objcSelectorReturnsOwned], and the two-constructor shape exists so the
/// decision has to be written down at the point where it is made.
final class ObjCOwned {
  ObjCOwned.adopt(this.pointer);

  ObjCOwned.borrow(Pointer<ObjCObject> pointer) : pointer = objcRetain(pointer);

  final Pointer<ObjCObject> pointer;

  bool get isNull => pointer == nullptr;

  /// Registers the release with [bag] and returns this, so an acquisition and
  /// its teardown are one expression.
  ObjCOwned trackedBy(DisposableBag bag) {
    bag.add(this, () => objcRelease(pointer));
    return this;
  }
}

// ---------------------------------------------------------------------------
// Dynamic class registration - section 20.4
// ---------------------------------------------------------------------------

/// Builds and registers a class at runtime.
///
/// Needed for anything AppKit or Metal calls *back* into: a view that wants
/// `NSTextInputClient`, a delegate, a completion target. The methods are
/// `NativeCallable` function pointers, and the encoding string is the same one
/// [parseObjCTypeEncoding] reads - so a method added here can be checked
/// against the shape its implementation actually has.
///
/// ## The thread rule, stated because it is not enforceable here
///
/// An implementation reached from a `NativeCallable.isolateLocal` must run on
/// the isolate that created it. AppKit and Metal both call back on threads
/// they own, so anything registered here that a framework may invoke off the
/// isolate needs `NativeCallable.listener`, whose delivery is asynchronous.
/// This class cannot check which one it was handed, so the choice belongs to
/// the caller and is recorded at every call site.
final class ObjCClassBuilder {
  ObjCClassBuilder(this.name, this.superclassName)
      : _cls = _createPair(name, superclassName);

  static Pointer<ObjCObject> _createPair(String name, String superclassName) {
    final Pointer<ObjCObject> superclass = objcClass(superclassName);
    if (superclass == nullptr) {
      throw StateError(
        'cannot subclass "$superclassName": no such class is loaded. The '
        'framework declaring it has to be opened first',
      );
    }
    final Pointer<Uint8> text = objcAllocateCString(name);
    try {
      final Pointer<ObjCObject> created =
          _allocateClassPair(superclass, text, 0);
      if (created == nullptr) {
        throw StateError(
          'objc_allocateClassPair refused "$name"; a class with that name is '
          'already registered in this process',
        );
      }
      return created;
    } finally {
      objcFreeCString(text);
    }
  }

  final String name;
  final String superclassName;
  final Pointer<ObjCObject> _cls;

  bool _registered = false;

  /// The class, usable only after [register].
  Pointer<ObjCObject> get cls => _cls;

  /// Adds `-[name selector]`, implemented by [implementation].
  ///
  /// [typeEncoding] is the runtime's own spelling of the signature - `v@:@`
  /// for a one-object method returning nothing. It is parsed before being
  /// handed over, so a typo is an [ObjCTypeEncodingError] here instead of a
  /// wrong register read later.
  ///
  /// ## The type parameter, and what it does and does not buy
  ///
  /// The first draft declared this `Pointer<NativeFunction<NativeFunction>>`,
  /// which does not compile: `NativeFunction`'s type argument is bounded by
  /// `Function` and `NativeFunction` is not one. The fix is not to widen it to
  /// `Pointer<Void>` but to make it generic, so that a caller passes its
  /// `NativeCallable<T>.nativeFunction` **unchanged**, with no `.cast()` at the
  /// call site. That matters because a `.cast()` is exactly where a mismatched
  /// IMP signature would have been laundered past the compiler.
  ///
  /// What it does *not* buy: [T] and [typeEncoding] are still checked against
  /// each other only by the human who wrote them. Dart cannot reflect a
  /// [NativeFunction] type back into an ABI shape, so the encoding is parsed
  /// for well-formedness and for [ObjCSignature.explicitArgumentCount], and the
  /// caller is expected to assert the rest in a test.
  void addMethod<T extends Function>({
    required String selector,
    required String typeEncoding,
    required Pointer<NativeFunction<T>> implementation,
  }) {
    if (_registered) {
      throw StateError(
        'methods must be added before objc_registerClassPair; "$name" is '
        'already registered',
      );
    }
    // Parsed for its side effect: a malformed encoding throws here, where the
    // stack trace names the selector, rather than corrupting a call frame.
    parseObjCTypeEncoding(typeEncoding);
    final Pointer<Uint8> types = objcAllocateCString(typeEncoding);
    try {
      final int added = _classAddMethod(
        _cls,
        objcSelector(selector),
        implementation.cast<Void>(),
        types,
      );
      if (added == 0) {
        throw StateError(
          'class_addMethod refused $name.$selector; the superclass already '
          'declares it, which class_addMethod does not override',
        );
      }
    } finally {
      objcFreeCString(types);
    }
  }

  /// Makes the class usable. Irreversible: a registered pair cannot be
  /// disposed, which is why nothing here implements [Disposable].
  Pointer<ObjCObject> register() {
    if (_registered) return _cls;
    _registered = true;
    _registerClassPair(_cls);
    return _cls;
  }
}

// ---------------------------------------------------------------------------
// Blocks
// ---------------------------------------------------------------------------

/// The ABI layout of a block with no captured variables.
///
/// This is `struct Block_literal_1` from libclosure's `Block_private.h`, and it
/// is a **published ABI**, not an implementation detail: the compiler emits
/// this layout and every framework that takes a block reads it. Transcribed
/// here because `-[MTLCommandBuffer addCompletedHandler:]` takes a block and
/// there is no other way to hand it one from Dart.
///
/// ```c
/// struct Block_literal_1 {
///   void *isa;                      // offset  0
///   volatile int32_t flags;         // offset  8
///   int32_t reserved;               // offset 12
///   void (*invoke)(void *, ...);    // offset 16
///   struct Block_descriptor_1 *d;   // offset 24
/// };                                // size   32
/// ```
///
/// Every one of those offsets is checkable without a Mac - `sizeOf` and the
/// field arithmetic are `dart:ffi`'s, and the LP64 layout of
/// `{pointer, int32, int32, pointer, pointer}` is the same on Windows x64. A
/// test asserts the size, which is the number that would be wrong if somebody
/// "tidied" `reserved` away.
final class ObjCBlockLiteral extends Struct {
  external Pointer<Void> isa;

  @Int32()
  external int flags;

  @Int32()
  external int reserved;

  external Pointer<Void> invoke;

  external Pointer<ObjCBlockDescriptor> descriptor;
}

/// `struct Block_descriptor_1` plus the `signature` field that
/// [kObjCBlockHasSignature] promises.
///
/// The descriptor is a family of structs, each suffix present only when the
/// matching flag is set:
///
/// ```c
/// struct Block_descriptor_1 { unsigned long reserved; unsigned long size; };
/// struct Block_descriptor_2 { copy; dispose; };  // iff BLOCK_HAS_COPY_DISPOSE
/// struct Block_descriptor_3 { const char *signature; ... };
///                                                // iff BLOCK_HAS_SIGNATURE
/// ```
///
/// The blocks this file builds capture nothing, so `_2` is absent and `_3`
/// follows `_1` directly. Getting that wrong would put the signature pointer
/// where a copy helper is expected and the runtime would call it.
final class ObjCBlockDescriptor extends Struct {
  @UintPtr()
  external int reserved;

  /// `sizeof(struct Block_literal_1)` - the size of the **literal**, not of
  /// this descriptor. Named `size` in the ABI and worth restating, because a
  /// descriptor holding its own size is the obvious wrong guess and produces
  /// a block the runtime copies 24 bytes of.
  @UintPtr()
  external int size;

  external Pointer<Uint8> signature;
}

/// `BLOCK_IS_GLOBAL`. See [ObjCBlock] for why every block here sets it.
const int kObjCBlockIsGlobal = 1 << 28;

/// `BLOCK_HAS_SIGNATURE` - the descriptor carries a type encoding.
const int kObjCBlockHasSignature = 1 << 30;

/// `BLOCK_HAS_COPY_DISPOSE`. Never set here; named so that a reader can see
/// that its absence is a decision.
const int kObjCBlockHasCopyDispose = 1 << 25;

Pointer<Void>? _globalBlockIsa;
bool _globalBlockIsaAttempted = false;

/// `_NSConcreteGlobalBlock`, the class every global block points at.
///
/// A *data* symbol, so the address of the symbol is the value we want, and
/// looked up lazily: `DynamicLibrary.process()` is unsupported on Windows and
/// this file has to stay importable there.
Pointer<Void> _lookUpGlobalBlockIsa() {
  if (_globalBlockIsaAttempted) {
    final Pointer<Void>? found = _globalBlockIsa;
    if (found != null) return found;
    throw StateError(
      'the block runtime symbol _NSConcreteGlobalBlock is not present in this '
      'process, so no block can be built. This is expected off macOS',
    );
  }
  _globalBlockIsaAttempted = true;
  try {
    _globalBlockIsa =
        DynamicLibrary.process().lookup<Void>('_NSConcreteGlobalBlock');
  } on Object {
    _globalBlockIsa = null;
  }
  return _lookUpGlobalBlockIsa();
}

/// Whether a block can be built in this process.
bool get isObjCBlockRuntimeAvailable {
  try {
    _lookUpGlobalBlockIsa();
    return true;
  } on Object {
    return false;
  }
}

/// One Objective-C block wrapping a Dart function pointer.
///
/// ## Why it is marked global when it is plainly on the heap
///
/// A block that a framework holds gets `Block_copy`d. For a *stack* block that
/// means a `malloc` and a memcpy, and for a heap block it means a retain count
/// this file would then have to track through `Block_release`. Setting
/// [kObjCBlockIsGlobal] makes both no-ops: `_Block_copy` returns the same
/// pointer and `_Block_release` does nothing. So the block never moves, the
/// [invoke] pointer stays valid, and **this object owns the lifetime outright**.
///
/// The cost is the rule that comes with it, stated because nothing enforces it:
/// **[dispose] must not run until the framework can no longer call the block.**
/// For `addCompletedHandler:` that means after the handler has fired or after
/// `waitUntilCompleted`. Disposing earlier is a use-after-free inside Metal's
/// completion thread, which is the least debuggable place in the process.
///
/// ## The thread rule
///
/// Metal invokes a completion handler on a thread it owns, never the isolate's.
/// So the [NativeCallable] behind [invoke] **must** be
/// `NativeCallable.listener`, whose delivery is asynchronous and whose return
/// type must be `void` - which is exactly the shape of a completion handler.
/// An `isolateLocal` callable invoked from Metal's thread is undefined
/// behaviour. This class cannot check which kind it was handed, so the choice
/// is the caller's and every call site records it, the same rule
/// [ObjCClassBuilder] states for method implementations.
final class ObjCBlock with DisposableMixin {
  /// Wraps [invoke], whose first parameter is the block itself.
  ///
  /// [signature] is the block's Objective-C type encoding, with `@?` for the
  /// block parameter: a completion handler taking one object is `v@?@`. It is
  /// parsed before being stored, so a typo throws here.
  factory ObjCBlock(
    Pointer<NativeFunction<Void Function(Pointer<Void>, Pointer<ObjCObject>)>>
        invoke, {
    String signature = kObjCCompletionHandlerSignature,
  }) {
    final ObjCSignature parsed = parseObjCTypeEncoding(signature);
    if (parsed.returnClass != ObjCAbiClass.none) {
      throw ArgumentError.value(
        signature,
        'signature',
        'a block reached from a framework thread must return void, because '
            'the NativeCallable behind it has to be a listener and a listener '
            'cannot return a value',
      );
    }
    final Pointer<Void> isa = _lookUpGlobalBlockIsa();
    final NativeAllocator allocator = NativeAllocator.instance;
    final Pointer<Uint8> encoded = objcAllocateCString(signature);
    final Pointer<ObjCBlockDescriptor> descriptor =
        allocator.allocate<ObjCBlockDescriptor>(sizeOf<ObjCBlockDescriptor>());
    final Pointer<ObjCBlockLiteral> literal =
        allocator.allocate<ObjCBlockLiteral>(sizeOf<ObjCBlockLiteral>());
    descriptor.ref
      ..reserved = 0
      ..size = sizeOf<ObjCBlockLiteral>()
      ..signature = encoded;
    literal.ref
      ..isa = isa
      ..flags = kObjCBlockIsGlobal | kObjCBlockHasSignature
      ..reserved = 0
      ..invoke = invoke.cast<Void>()
      ..descriptor = descriptor;
    return ObjCBlock._(literal, descriptor, encoded);
  }

  ObjCBlock._(this._literal, this._descriptor, this._signature);

  final Pointer<ObjCBlockLiteral> _literal;
  final Pointer<ObjCBlockDescriptor> _descriptor;
  final Pointer<Uint8> _signature;

  /// The block, as the `id` an Objective-C method takes.
  ///
  /// A block *is* an object as far as `objc_msgSend` is concerned, so this
  /// goes through [objcSendVoid1] like any other pointer argument.
  Pointer<ObjCObject> get pointer => _literal.cast<ObjCObject>();

  /// Registers the teardown with [bag], so a block is released in the same
  /// reverse order as everything else the frame acquired.
  ObjCBlock trackedBy(DisposableBag bag) {
    bag.addDisposable(this);
    return this;
  }

  @override
  void onDispose() {
    final NativeAllocator allocator = NativeAllocator.instance;
    // Reverse of construction: the literal first, because it is the only one
    // holding a pointer to the descriptor.
    allocator.free(_literal);
    allocator.free(_descriptor);
    objcFreeCString(_signature);
  }
}

/// `void (^)(id)` - the encoding of every completion handler this framework
/// installs, `-[MTLCommandBuffer addCompletedHandler:]` included.
///
/// `@?` is the block's own first parameter. Reading it as two arguments is the
/// parser bug [_EncodingReader.readType] documents.
const String kObjCCompletionHandlerSignature = 'v@?@';
