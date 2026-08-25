import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../../ffi/native_memory.dart';
import 'pkcs11_types.dart';

const int _ckrOk = 0;
const int _ckrUserAlreadyLoggedIn = 0x00000100;
const int _ckrUserNotLoggedIn = 0x00000101;
const int _ckrCryptokiNotInitialized = 0x00000190;
const int _ckrCryptokiAlreadyInitialized = 0x00000191;
const int _ckfSerialSession = 0x00000004;
const int _ckuUser = 1;
const int _ckoCertificate = 1;
const int _ckoPrivateKey = 3;
const int _ckaClass = 0;
const int _ckaLabel = 3;
const int _ckaValue = 0x11;
const int _ckaId = 0x102;

@Packed(1)
final class _CkAttribute extends Struct {
  @UnsignedLong()
  external int type;
  external Pointer<Void> value;
  @UnsignedLong()
  external int valueLength;
}

@Packed(1)
final class _CkTokenInfo extends Struct {
  @Array(32)
  external Array<Uint8> label;
  @Array(32)
  external Array<Uint8> manufacturerId;
  @Array(16)
  external Array<Uint8> model;
  @Array(16)
  external Array<Uint8> serialNumber;
  @UnsignedLong()
  external int flags;
  @UnsignedLong()
  external int maxSessionCount;
  @UnsignedLong()
  external int sessionCount;
  @UnsignedLong()
  external int maxRwSessionCount;
  @UnsignedLong()
  external int rwSessionCount;
  @UnsignedLong()
  external int maxPinLength;
  @UnsignedLong()
  external int minPinLength;
  @UnsignedLong()
  external int totalPublicMemory;
  @UnsignedLong()
  external int freePublicMemory;
  @UnsignedLong()
  external int totalPrivateMemory;
  @UnsignedLong()
  external int freePrivateMemory;
  @Array(2)
  external Array<Uint8> hardwareVersion;
  @Array(2)
  external Array<Uint8> firmwareVersion;
  @Array(16)
  external Array<Uint8> utcTime;
}

@Packed(1)
final class _CkMechanism extends Struct {
  @UnsignedLong()
  external int mechanism;
  external Pointer<Void> parameter;
  @UnsignedLong()
  external int parameterLength;
}

typedef _InitializeNative = UnsignedLong Function(Pointer<Void>);
typedef _InitializeDart = int Function(Pointer<Void>);
typedef _FinalizeNative = UnsignedLong Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _GetSlotListNative = UnsignedLong Function(
  Uint8,
  Pointer<UnsignedLong>,
  Pointer<UnsignedLong>,
);
typedef _GetSlotListDart = int Function(
  int,
  Pointer<UnsignedLong>,
  Pointer<UnsignedLong>,
);
typedef _GetTokenInfoNative = UnsignedLong Function(
  UnsignedLong,
  Pointer<_CkTokenInfo>,
);
typedef _GetTokenInfoDart = int Function(int, Pointer<_CkTokenInfo>);
typedef _OpenSessionNative = UnsignedLong Function(
  UnsignedLong,
  UnsignedLong,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<UnsignedLong>,
);
typedef _OpenSessionDart = int Function(
  int,
  int,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<UnsignedLong>,
);
typedef _SessionNative = UnsignedLong Function(UnsignedLong);
typedef _SessionDart = int Function(int);
typedef _LoginNative = UnsignedLong Function(
  UnsignedLong,
  UnsignedLong,
  Pointer<Uint8>,
  UnsignedLong,
);
typedef _LoginDart = int Function(int, int, Pointer<Uint8>, int);
typedef _FindInitNative = UnsignedLong Function(
  UnsignedLong,
  Pointer<_CkAttribute>,
  UnsignedLong,
);
typedef _FindInitDart = int Function(int, Pointer<_CkAttribute>, int);
typedef _FindNative = UnsignedLong Function(
  UnsignedLong,
  Pointer<UnsignedLong>,
  UnsignedLong,
  Pointer<UnsignedLong>,
);
typedef _FindDart = int Function(
  int,
  Pointer<UnsignedLong>,
  int,
  Pointer<UnsignedLong>,
);
typedef _GetAttributeNative = UnsignedLong Function(
  UnsignedLong,
  UnsignedLong,
  Pointer<_CkAttribute>,
  UnsignedLong,
);
typedef _GetAttributeDart = int Function(
  int,
  int,
  Pointer<_CkAttribute>,
  int,
);
typedef _SignInitNative = UnsignedLong Function(
  UnsignedLong,
  Pointer<_CkMechanism>,
  UnsignedLong,
);
typedef _SignInitDart = int Function(int, Pointer<_CkMechanism>, int);
typedef _SignNative = UnsignedLong Function(
  UnsignedLong,
  Pointer<Uint8>,
  UnsignedLong,
  Pointer<Uint8>,
  Pointer<UnsignedLong>,
);
typedef _SignDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<UnsignedLong>,
);

final class Pkcs11Module implements Pkcs11ModuleApi {
  Pkcs11Module(this.modulePath) : _library = DynamicLibrary.open(modulePath) {
    _initialize = _library.lookupFunction<_InitializeNative, _InitializeDart>(
      'C_Initialize',
    );
    _finalize = _library.lookupFunction<_FinalizeNative, _FinalizeDart>(
      'C_Finalize',
    );
    _getSlotList =
        _library.lookupFunction<_GetSlotListNative, _GetSlotListDart>(
      'C_GetSlotList',
    );
    _getTokenInfo =
        _library.lookupFunction<_GetTokenInfoNative, _GetTokenInfoDart>(
      'C_GetTokenInfo',
    );
    _openSession =
        _library.lookupFunction<_OpenSessionNative, _OpenSessionDart>(
      'C_OpenSession',
    );
    _closeSession = _library.lookupFunction<_SessionNative, _SessionDart>(
      'C_CloseSession',
    );
    _login = _library.lookupFunction<_LoginNative, _LoginDart>('C_Login');
    _logout = _library.lookupFunction<_SessionNative, _SessionDart>('C_Logout');
    _findObjectsInit = _library.lookupFunction<_FindInitNative, _FindInitDart>(
      'C_FindObjectsInit',
    );
    _cFindObjects = _library.lookupFunction<_FindNative, _FindDart>(
      'C_FindObjects',
    );
    _findObjectsFinal = _library.lookupFunction<_SessionNative, _SessionDart>(
      'C_FindObjectsFinal',
    );
    _getAttribute =
        _library.lookupFunction<_GetAttributeNative, _GetAttributeDart>(
      'C_GetAttributeValue',
    );
    _signInit = _library.lookupFunction<_SignInitNative, _SignInitDart>(
      'C_SignInit',
    );
    _sign = _library.lookupFunction<_SignNative, _SignDart>('C_Sign');
    final result = _initialize(nullptr);
    if (result != _ckrOk && result != _ckrCryptokiAlreadyInitialized) {
      _check(result, 'C_Initialize');
    }
    _moduleUsers.update(_moduleKey, (count) => count + 1, ifAbsent: () => 1);
    if (result == _ckrOk) _frameworkInitializedModules.add(_moduleKey);
    _initialized = true;
  }

  static final Map<String, int> _moduleUsers = <String, int>{};
  static final Set<String> _frameworkInitializedModules = <String>{};

  @override
  final String modulePath;
  final DynamicLibrary _library;
  late final _InitializeDart _initialize;
  late final _FinalizeDart _finalize;
  late final _GetSlotListDart _getSlotList;
  late final _GetTokenInfoDart _getTokenInfo;
  late final _OpenSessionDart _openSession;
  late final _SessionDart _closeSession;
  late final _LoginDart _login;
  late final _SessionDart _logout;
  late final _FindInitDart _findObjectsInit;
  late final _FindDart _cFindObjects;
  late final _SessionDart _findObjectsFinal;
  late final _GetAttributeDart _getAttribute;
  late final _SignInitDart _signInit;
  late final _SignDart _sign;
  bool _initialized = false;

  String get _moduleKey =>
      Platform.isWindows ? modulePath.toLowerCase() : modulePath;

  static List<String> discoverCommonModules() {
    final candidates = <String>{
      if (Platform.isWindows) ...<String>[
        r'C:\Windows\System32\aetpkss1.dll',
        r'C:\Windows\System32\aetpkssw.dll',
        r'C:\Windows\System32\eTPKCS11.dll',
        r'C:\Windows\System32\eps2003csp11.dll',
        r'C:\Windows\System32\wdpkcs.dll',
        r'C:\Windows\System32\gclib.dll',
        r'C:\Windows\System32\IDPrimePKCS11.dll',
        r'C:\SoftHSM2\lib\softhsm2-x64.dll',
        r'C:\SoftHSM2\lib\softhsm2.dll',
      ],
      if (Platform.isLinux) ...<String>[
        '/usr/lib/softhsm/libsofthsm2.so',
        '/usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so',
        '/usr/lib/libaetpkss.so',
        '/usr/lib/libaetpkss.so.3',
        '/usr/lib64/libaetpkss.so',
        '/usr/lib64/libaetpkss.so.3',
        '/usr/lib/x86_64-linux-gnu/libaetpkss.so',
        '/usr/lib/x86_64-linux-gnu/libaetpkss.so.3',
      ],
      if (Platform.isMacOS) ...<String>[
        '/usr/local/lib/softhsm/libsofthsm2.so',
        '/Library/Frameworks/eToken.framework/Versions/A/libeToken.dylib',
        '/Applications/tokenadmin.app/Contents/Frameworks/libaetpkss.dylib',
        '/Applications/TokenAdmin.app/Contents/Frameworks/libaetpkss.dylib',
        '/usr/local/lib/libaetpkss.dylib',
      ],
    };
    return candidates.where((path) => File(path).existsSync()).toList();
  }

  /// Tamanhos efetivos das estruturas sensíveis ao ABI Cryptoki.
  ///
  /// O header PKCS#11 usa `pack(1)`. No Windows x64, onde `CK_ULONG` continua
  /// com 32 bits, `CK_ATTRIBUTE` e `CK_MECHANISM` devem medir 16 bytes — não
  /// 24. Um tamanho incorreto desloca os ponteiros entregues ao middleware e
  /// pode causar uma access violation dentro da DLL.
  static ({int attribute, int mechanism, int tokenInfo}) get nativeAbiLayout =>
      (
        attribute: sizeOf<_CkAttribute>(),
        mechanism: sizeOf<_CkMechanism>(),
        tokenInfo: sizeOf<_CkTokenInfo>(),
      );

  @override
  List<Pkcs11Token> listTokens() => using((arena) {
        final slots = _slotIds(arena);
        return slots.map((slot) {
          final info = arena.allocate<_CkTokenInfo>(sizeOf<_CkTokenInfo>());
          _check(_getTokenInfo(slot, info), 'C_GetTokenInfo');
          return Pkcs11Token(
            slotId: slot,
            label: _fixedText(info.ref.label, 32),
            manufacturer: _fixedText(info.ref.manufacturerId, 32),
            model: _fixedText(info.ref.model, 16),
            serialNumber: _fixedText(info.ref.serialNumber, 16),
            flags: info.ref.flags,
          );
        }).toList(growable: false);
      });

  List<int> _slotIds(NativeArena arena) {
    final count = arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>());
    _check(_getSlotList(1, nullptr, count), 'C_GetSlotList(count)');
    if (count.value == 0) return const <int>[];
    final slots = arena.allocate<UnsignedLong>(
      sizeOf<UnsignedLong>() * count.value,
    );
    _check(_getSlotList(1, slots, count), 'C_GetSlotList(values)');
    return List<int>.generate(count.value, (index) => slots[index]);
  }

  @override
  List<Pkcs11Certificate> listCertificates({
    required int slotId,
    String? pin,
  }) =>
      _withSession(slotId, pin, (session, arena) {
        final handles = _findObjects(
          session,
          arena,
          objectClass: _ckoCertificate,
        );
        return handles.map((handle) {
          final values = _attributes(
            session,
            handle,
            arena,
            const <int>[_ckaId, _ckaLabel, _ckaValue],
          );
          return Pkcs11Certificate(
            id: values[0],
            label: utf8.decode(values[1], allowMalformed: true).trim(),
            derBytes: values[2],
          );
        }).toList(growable: false);
      });

  @override
  Uint8List sign({
    required int slotId,
    required String pin,
    required Uint8List keyId,
    required Uint8List data,
    Pkcs11Mechanism mechanism = Pkcs11Mechanism.sha256RsaPkcs,
  }) =>
      _withSession(slotId, pin, (session, arena) {
        final keys = _findObjects(
          session,
          arena,
          objectClass: _ckoPrivateKey,
          id: keyId,
        );
        if (keys.isEmpty) {
          throw StateError(
              'PKCS#11 private key with matching CKA_ID not found');
        }
        final mechanismPointer =
            arena.allocate<_CkMechanism>(sizeOf<_CkMechanism>());
        mechanismPointer.ref
          ..mechanism = mechanism.value
          ..parameter = nullptr
          ..parameterLength = 0;
        _check(
          _signInit(session, mechanismPointer, keys.first),
          'C_SignInit',
        );
        final input = arena.allocate<Uint8>(data.length);
        input.asTypedList(data.length).setAll(0, data);
        final signatureLength =
            arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>());
        _check(
          _sign(session, input, data.length, nullptr, signatureLength),
          'C_Sign(length)',
        );
        if (signatureLength.value <= 0 || signatureLength.value > 1024 * 1024) {
          throw StateError('PKCS#11 returned an invalid signature length');
        }
        final signature = arena.allocate<Uint8>(signatureLength.value);
        _check(
          _sign(session, input, data.length, signature, signatureLength),
          'C_Sign',
        );
        return Uint8List.fromList(
          signature.asTypedList(signatureLength.value),
        );
      });

  R _withSession<R>(
    int slotId,
    String? pin,
    R Function(int session, NativeArena arena) action,
  ) =>
      using((arena) {
        final sessionPointer =
            arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>());
        _check(
          _openSession(
            slotId,
            _ckfSerialSession,
            nullptr,
            nullptr,
            sessionPointer,
          ),
          'C_OpenSession',
        );
        final session = sessionPointer.value;
        var loggedIn = false;
        Pointer<Uint8>? pinPointer;
        var pinLength = 0;
        try {
          if (pin != null) {
            final bytes = utf8.encode(pin);
            final pointer =
                arena.allocate<Uint8>(bytes.isEmpty ? 1 : bytes.length);
            if (bytes.isNotEmpty) {
              pointer.asTypedList(bytes.length).setAll(0, bytes);
            }
            pinPointer = pointer;
            pinLength = bytes.length;
            final result = _login(session, _ckuUser, pointer, bytes.length);
            if (result != _ckrOk && result != _ckrUserAlreadyLoggedIn) {
              _check(result, 'C_Login');
            }
            loggedIn = result == _ckrOk;
          }
          return action(session, arena);
        } finally {
          if (loggedIn) {
            final result = _logout(session);
            if (result != _ckrOk && result != _ckrUserNotLoggedIn) {
              // A falha principal, se houver, é mais útil que uma falha de logout.
            }
          }
          if (pinPointer != null && pinLength != 0) {
            pinPointer.asTypedList(pinLength).fillRange(0, pinLength, 0);
          }
          _check(_closeSession(session), 'C_CloseSession');
        }
      });

  List<int> _findObjects(
    int session,
    NativeArena arena, {
    required int objectClass,
    Uint8List? id,
  }) {
    final attributeCount = id == null ? 1 : 2;
    final attributes = arena.allocate<_CkAttribute>(
      sizeOf<_CkAttribute>() * attributeCount,
    );
    final classValue = arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>())
      ..value = objectClass;
    attributes[0]
      ..type = _ckaClass
      ..value = classValue.cast()
      ..valueLength = sizeOf<UnsignedLong>();
    if (id != null) {
      final idValue = arena.allocate<Uint8>(id.length);
      idValue.asTypedList(id.length).setAll(0, id);
      attributes[1]
        ..type = _ckaId
        ..value = idValue.cast()
        ..valueLength = id.length;
    }
    _check(
      _findObjectsInit(session, attributes, attributeCount),
      'C_FindObjectsInit',
    );
    final result = <int>[];
    final handle = arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>());
    final count = arena.allocate<UnsignedLong>(sizeOf<UnsignedLong>());
    try {
      while (true) {
        _check(_cFindObjects(session, handle, 1, count), 'C_FindObjects');
        if (count.value == 0) break;
        result.add(handle.value);
      }
    } finally {
      _check(_findObjectsFinal(session), 'C_FindObjectsFinal');
    }
    return result;
  }

  List<Uint8List> _attributes(
    int session,
    int object,
    NativeArena arena,
    List<int> types,
  ) {
    final attributes = arena.allocate<_CkAttribute>(
      sizeOf<_CkAttribute>() * types.length,
    );
    for (var i = 0; i < types.length; i++) {
      attributes[i]
        ..type = types[i]
        ..value = nullptr
        ..valueLength = 0;
    }
    _check(
      _getAttribute(session, object, attributes, types.length),
      'C_GetAttributeValue(lengths)',
    );
    final pointers = <Pointer<Uint8>>[];
    for (var i = 0; i < types.length; i++) {
      final length = attributes[i].valueLength;
      if (length < 0 || length > 64 * 1024 * 1024) {
        throw StateError('PKCS#11 returned an invalid attribute length');
      }
      final pointer = arena.allocate<Uint8>(length == 0 ? 1 : length);
      pointers.add(pointer);
      attributes[i].value = pointer.cast();
    }
    _check(
      _getAttribute(session, object, attributes, types.length),
      'C_GetAttributeValue(values)',
    );
    return List<Uint8List>.generate(types.length, (index) {
      return Uint8List.fromList(
        pointers[index].asTypedList(attributes[index].valueLength),
      );
    });
  }

  @override
  void close() {
    if (!_initialized) return;
    final users = _moduleUsers[_moduleKey] ?? 1;
    if (users > 1) {
      _moduleUsers[_moduleKey] = users - 1;
    } else {
      _moduleUsers.remove(_moduleKey);
      if (_frameworkInitializedModules.remove(_moduleKey)) {
        final result = _finalize(nullptr);
        if (result != _ckrOk && result != _ckrCryptokiNotInitialized) {
          _check(result, 'C_Finalize');
        }
      }
    }
    _initialized = false;
  }

  void _check(int result, String operation) {
    if (result == _ckrOk) return;
    throw Pkcs11Exception(
      operation: operation,
      code: result,
      codeName: _errorName(result),
    );
  }
}

String _fixedText(Array<Uint8> value, int length) {
  final bytes = List<int>.generate(length, (index) => value[index]);
  while (bytes.isNotEmpty && (bytes.last == 0 || bytes.last == 0x20)) {
    bytes.removeLast();
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _errorName(int code) => switch (code) {
      0x00000005 => 'CKR_GENERAL_ERROR',
      0x00000006 => 'CKR_FUNCTION_FAILED',
      0x00000007 => 'CKR_ARGUMENTS_BAD',
      0x00000030 => 'CKR_DEVICE_ERROR',
      0x00000054 => 'CKR_FUNCTION_NOT_SUPPORTED',
      0x00000060 => 'CKR_KEY_HANDLE_INVALID',
      0x00000070 => 'CKR_MECHANISM_INVALID',
      0x00000082 => 'CKR_OBJECT_HANDLE_INVALID',
      0x000000a0 => 'CKR_PIN_INCORRECT',
      0x000000a1 => 'CKR_PIN_INVALID',
      0x000000a4 => 'CKR_PIN_LOCKED',
      0x000000b3 => 'CKR_SESSION_HANDLE_INVALID',
      0x000000e0 => 'CKR_TOKEN_NOT_PRESENT',
      0x000000e1 => 'CKR_TOKEN_NOT_RECOGNIZED',
      0x00000100 => 'CKR_USER_ALREADY_LOGGED_IN',
      0x00000101 => 'CKR_USER_NOT_LOGGED_IN',
      0x00000150 => 'CKR_BUFFER_TOO_SMALL',
      0x00000190 => 'CKR_CRYPTOKI_NOT_INITIALIZED',
      0x00000191 => 'CKR_CRYPTOKI_ALREADY_INITIALIZED',
      _ => 'CKR_UNKNOWN',
    };
