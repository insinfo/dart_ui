/// Finding the Vulkan loader, and the entry points that exist before there is
/// an instance.
///
/// ## Three levels of dispatch, and why they are three objects here
///
/// Vulkan does not have one function table. It has three, and mixing them up
/// is the first mistake a hand-written binding makes:
///
///   * **Global** commands take no dispatchable handle -
///     `vkEnumerateInstanceLayerProperties`, `vkCreateInstance`. They are
///     resolved through `vkGetInstanceProcAddr(VK_NULL_HANDLE, name)`.
///   * **Instance** commands take a `VkInstance` or a `VkPhysicalDevice` and
///     are resolved through `vkGetInstanceProcAddr(instance, name)`.
///   * **Device** commands take a `VkDevice`, `VkQueue` or `VkCommandBuffer`
///     and *should* be resolved through `vkGetDeviceProcAddr(device, name)`.
///
/// The last one is not pedantry. A pointer from `vkGetInstanceProcAddr` for a
/// device command points at the loader's *trampoline*, which reads the
/// dispatch table out of the handle and jumps; a pointer from
/// `vkGetDeviceProcAddr` points straight at the driver. On a machine with two
/// ICDs - this repository's development machine has an Intel driver and
/// Microsoft's Direct3D 12 emulation layer both answering - the trampoline is
/// the only thing that keeps `vkCmdDraw` on device A from entering driver B.
/// Skipping it costs one indirection per call and is correct; skipping
/// `vkGetInstanceProcAddr` and pulling symbols out of the DLL export table
/// instead is *not* correct, and is exactly the bug `gl_bindings.dart` records
/// for `opengl32.dll`.
///
/// So this file resolves globals, `vulkan_bindings.dart` resolves the other
/// two, and none of them ever calls `DynamicLibrary.lookup` for a Vulkan
/// command.
///
/// ## Why a 32-bit process is refused by name
///
/// Vulkan has two kinds of handle. Dispatchable ones - `VkInstance`,
/// `VkDevice`, `VkQueue`, `VkCommandBuffer`, `VkPhysicalDevice` - are always
/// pointers. Non-dispatchable ones are pointers **only on a 64-bit build**:
/// `VK_DEFINE_NON_DISPATCHABLE_HANDLE` expands to `uint64_t` when the target
/// is 32-bit. The generated bindings spell both as `Pointer<X_T>`, which is
/// the 64-bit answer, so a 32-bit process would pass four bytes where the
/// driver reads eight. Refusing with a sentence beats corrupting a stack.
library;

import 'dart:ffi';
import 'dart:io';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';

// ---------------------------------------------------------------------------
// Native signatures for the global level
// ---------------------------------------------------------------------------

typedef VkGetInstanceProcAddrNative = Pointer<Void> Function(
    Pointer<VkInstance_T>, Pointer<Char>);
typedef VkGetInstanceProcAddrDart = Pointer<Void> Function(
    Pointer<VkInstance_T>, Pointer<Char>);

typedef VkEnumerateInstanceVersionNative = Int32 Function(Pointer<Uint32>);
typedef VkEnumerateInstanceVersionDart = int Function(Pointer<Uint32>);

typedef VkEnumerateInstanceLayerPropertiesNative = Int32 Function(
    Pointer<Uint32>, Pointer<VkLayerProperties>);
typedef VkEnumerateInstanceLayerPropertiesDart = int Function(
    Pointer<Uint32>, Pointer<VkLayerProperties>);

typedef VkEnumerateInstanceExtensionPropertiesNative = Int32 Function(
    Pointer<Char>, Pointer<Uint32>, Pointer<VkExtensionProperties>);
typedef VkEnumerateInstanceExtensionPropertiesDart = int Function(
    Pointer<Char>, Pointer<Uint32>, Pointer<VkExtensionProperties>);

typedef VkCreateInstanceNative = Int32 Function(Pointer<VkInstanceCreateInfo>,
    Pointer<Void>, Pointer<Pointer<VkInstance_T>>);
typedef VkCreateInstanceDart = int Function(Pointer<VkInstanceCreateInfo>,
    Pointer<Void>, Pointer<Pointer<VkInstance_T>>);

/// Raised when a Vulkan command that must exist does not.
///
/// Its own type rather than a [StateError] so that a probe can catch exactly
/// this and turn it into a [BackendDiagnostic] without swallowing genuine
/// programming errors from the same block.
final class VulkanSymbolError extends Error {
  VulkanSymbolError(this.symbol, this.level);

  /// The command that was not resolved, spelled as the specification spells it.
  final String symbol;

  /// `global`, `instance` or `device` - which of the three dispatch levels was
  /// asked. Named because the same symbol missing at different levels means
  /// different things: `vkCmdDraw` missing at device level is a broken driver,
  /// and at instance level it is this binding asking the wrong table.
  final String level;

  @override
  String toString() =>
      'VulkanSymbolError: the Vulkan loader resolved no $level-level '
      '$symbol; this driver cannot run the renderer';
}

/// The result of trying to open the loader: a library, or the reason there is
/// none.
///
/// Never throws for "no Vulkan here", because a machine without a driver is
/// the ordinary case on a CI runner and section 6.6 wants that reported rather
/// than raised.
final class VulkanLoadResult {
  const VulkanLoadResult({
    required this.library,
    required this.attempted,
    required this.diagnostics,
  });

  final VulkanLibrary? library;

  /// Every file name that was tried, in order. A report that says only "no
  /// Vulkan" cannot be acted on; one that says `libvulkan.so.1, libvulkan.so`
  /// tells the reader which package to install.
  final List<String> attempted;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => library != null;

  /// The failures, joined, for a `skip:` reason or a log line.
  String get failureText =>
      diagnostics.where((BackendDiagnostic d) => d.isFailure).join('; ');
}

/// The Vulkan loader, plus the four commands that exist before an instance.
final class VulkanLibrary {
  VulkanLibrary._(
    this.path,
    this._getInstanceProcAddr,
    this.enumerateInstanceVersion,
    this.enumerateInstanceLayerProperties,
    this.enumerateInstanceExtensionProperties,
    this.createInstance,
  );

  /// The file that answered - `vulkan-1.dll`, `libvulkan.so.1`. Reported so a
  /// bug report says which loader, on a machine that may have several.
  final String path;

  final VkGetInstanceProcAddrDart _getInstanceProcAddr;

  /// `vkEnumerateInstanceVersion`, or null on a Vulkan 1.0 loader.
  ///
  /// Nullable because it is the one global command that genuinely may not be
  /// there: it was added in 1.1, and its absence *is* the answer - the loader
  /// supports 1.0 and nothing more. Treating that as a failure would refuse a
  /// working driver.
  final VkEnumerateInstanceVersionDart? enumerateInstanceVersion;

  final VkEnumerateInstanceLayerPropertiesDart enumerateInstanceLayerProperties;
  final VkEnumerateInstanceExtensionPropertiesDart
      enumerateInstanceExtensionProperties;
  final VkCreateInstanceDart createInstance;

  /// The loader file names this tries, per platform, in order.
  ///
  /// Windows has exactly one spelling and it lives in `System32`. Linux
  /// distributions ship the versioned SONAME and a development symlink, and
  /// only the first is guaranteed on a machine without `-dev` packages.
  /// macOS has no Vulkan of its own: `libvulkan.1.dylib` is the LunarG loader
  /// from the SDK and `libMoltenVK.dylib` is the ICD itself, which can be
  /// opened directly when there is no loader. Both are listed because on that
  /// platform either one may be the only thing present.
  static List<String> candidateNames() {
    if (Platform.isWindows) return const <String>['vulkan-1.dll'];
    if (Platform.isMacOS) {
      return const <String>[
        'libvulkan.1.dylib',
        'libvulkan.dylib',
        'libMoltenVK.dylib',
      ];
    }
    return const <String>['libvulkan.so.1', 'libvulkan.so'];
  }

  /// Opens the loader, or reports why not.
  ///
  /// [override] is for a test that wants a specific ICD - the software
  /// rasteriser under `referencias/`, say - and is tried first and alone.
  static VulkanLoadResult open({String? override}) {
    final List<String> attempted = <String>[];
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];

    if (sizeOf<Pointer<Void>>() != 8) {
      return VulkanLoadResult(
        library: null,
        attempted: attempted,
        diagnostics: <BackendDiagnostic>[
          const BackendDiagnostic(
            kind: DiagnosticKind.unsupportedPlatform,
            message: 'this Vulkan backend requires a 64-bit process',
            detail: 'a non-dispatchable Vulkan handle is 64 bits on every '
                'build and a dispatchable one is pointer-width, so on a '
                '32-bit process the two cannot share the Dart `int` spelling '
                'this binding uses for both',
          ),
        ],
      );
    }

    if (!NativeAllocator.isAvailable) {
      return VulkanLoadResult(
        library: null,
        attempted: attempted,
        diagnostics: <BackendDiagnostic>[
          const BackendDiagnostic(
            kind: DiagnosticKind.missingLibrary,
            message: 'no native allocator, so no Vulkan structure can be '
                'built to pass to the driver',
          ),
        ],
      );
    }

    final List<String> names =
        override == null ? candidateNames() : <String>[override];
    for (final String name in names) {
      attempted.add(name);
      final DynamicLibrary library;
      try {
        library = DynamicLibrary.open(name);
      } on Object catch (error) {
        diagnostics.add(BackendDiagnostic.missingLibrary(name,
            detail: '$error'.split('\n').first));
        continue;
      }
      try {
        return VulkanLoadResult(
          library: _bind(library, name),
          attempted: attempted,
          diagnostics: diagnostics,
        );
      } on VulkanSymbolError catch (error) {
        diagnostics.add(
            BackendDiagnostic.missingSymbol(error.symbol, detail: 'in $name'));
      } on Object catch (error) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.missingSymbol,
          message: 'binding $name threw',
          detail: '$error',
        ));
      }
    }

    return VulkanLoadResult(
      library: null,
      attempted: attempted,
      diagnostics: diagnostics,
    );
  }

  static VulkanLibrary _bind(DynamicLibrary library, String name) {
    // The one symbol that is genuinely looked up in the export table, because
    // it is the only way in. Everything else goes through it.
    final VkGetInstanceProcAddrDart getProc = library.lookupFunction<
        VkGetInstanceProcAddrNative,
        VkGetInstanceProcAddrDart>('vkGetInstanceProcAddr');

    Pointer<Void> resolve(String symbol) => using((NativeArena arena) =>
        getProc(nullptr, arena.allocateAscii(symbol).cast<Char>()));

    // A pointer and not a Dart function: `Pointer.asFunction` refuses a type
    // argument that is a type parameter, so the shared part of the work stops
    // at the cast and each `asFunction` is spelled at its call site.
    Pointer<NativeFunction<T>> required<T extends Function>(String symbol) {
      final Pointer<Void> address = resolve(symbol);
      if (address == nullptr) throw VulkanSymbolError(symbol, 'global');
      return address.cast<NativeFunction<T>>();
    }

    final Pointer<Void> versionAddress = resolve('vkEnumerateInstanceVersion');

    return VulkanLibrary._(
      name,
      getProc,
      versionAddress == nullptr
          ? null
          : versionAddress
              .cast<NativeFunction<VkEnumerateInstanceVersionNative>>()
              .asFunction<VkEnumerateInstanceVersionDart>(),
      required<VkEnumerateInstanceLayerPropertiesNative>(
              'vkEnumerateInstanceLayerProperties')
          .asFunction<VkEnumerateInstanceLayerPropertiesDart>(),
      required<VkEnumerateInstanceExtensionPropertiesNative>(
              'vkEnumerateInstanceExtensionProperties')
          .asFunction<VkEnumerateInstanceExtensionPropertiesDart>(),
      required<VkCreateInstanceNative>('vkCreateInstance')
          .asFunction<VkCreateInstanceDart>(),
    );
  }

  /// Every command this class resolves before there is an instance.
  ///
  /// `vkEnumerateInstanceVersion` is not in the list because its absence is an
  /// answer rather than a failure; see [enumerateInstanceVersion].
  static const List<String> requiredSymbols = <String>[
    'vkGetInstanceProcAddr',
    'vkEnumerateInstanceLayerProperties',
    'vkEnumerateInstanceExtensionProperties',
    'vkCreateInstance',
  ];

  /// An instance-level command, or null when the instance does not have it.
  ///
  /// Public because `vulkan_bindings.dart` builds the instance table out of
  /// it and because a caller that wants to know whether an extension's
  /// commands are really there asks this rather than parsing a string list:
  /// an extension that is enabled but whose entry points are absent is a
  /// broken layer, and the difference matters.
  Pointer<Void> instanceProc(Pointer<VkInstance_T> instance, String symbol) =>
      using((NativeArena arena) => _getInstanceProcAddr(
          instance, arena.allocateAscii(symbol).cast<Char>()));

  /// The API version the loader itself implements.
  ///
  /// `VK_API_VERSION_1_0` when [enumerateInstanceVersion] is absent, which is
  /// what the specification says a 1.0 loader means by not exporting it.
  int instanceVersion() {
    final VkEnumerateInstanceVersionDart? query = enumerateInstanceVersion;
    if (query == null) return vkMakeApiVersion(1, 0, 0);
    return using((NativeArena arena) {
      final Pointer<Uint32> out = arena.allocate<Uint32>(sizeOf<Uint32>());
      final int result = query(out);
      if (vkFailed(result)) return vkMakeApiVersion(1, 0, 0);
      return out.value;
    });
  }

  /// Every instance layer this machine offers, by name.
  List<String> layerNames() => using((NativeArena arena) {
        final Pointer<Uint32> count = arena.allocate<Uint32>(sizeOf<Uint32>());
        if (vkFailed(enumerateInstanceLayerProperties(count, nullptr))) {
          return const <String>[];
        }
        if (count.value == 0) return const <String>[];
        final Pointer<VkLayerProperties> items =
            arena.allocate<VkLayerProperties>(
                sizeOf<VkLayerProperties>() * count.value);
        if (vkFailed(enumerateInstanceLayerProperties(count, items))) {
          return const <String>[];
        }
        return <String>[
          for (var i = 0; i < count.value; i++)
            readFixedAscii(items[i].layerName, vkMaxExtensionNameSize),
        ];
      });

  /// Every instance extension the loader and its implicit layers offer.
  List<String> instanceExtensionNames() => using((NativeArena arena) {
        final Pointer<Uint32> count = arena.allocate<Uint32>(sizeOf<Uint32>());
        if (vkFailed(
            enumerateInstanceExtensionProperties(nullptr, count, nullptr))) {
          return const <String>[];
        }
        if (count.value == 0) return const <String>[];
        final Pointer<VkExtensionProperties> items =
            arena.allocate<VkExtensionProperties>(
                sizeOf<VkExtensionProperties>() * count.value);
        if (vkFailed(
            enumerateInstanceExtensionProperties(nullptr, count, items))) {
          return const <String>[];
        }
        return <String>[
          for (var i = 0; i < count.value; i++)
            readFixedAscii(items[i].extensionName, vkMaxExtensionNameSize),
        ];
      });

  @override
  String toString() =>
      'VulkanLibrary($path, instance ${vkVersionText(instanceVersion())})';
}

/// The characters of a fixed `char[]` field up to its first NUL.
///
/// Vulkan's name fields are `char[256]` inside a struct rather than pointers,
/// so [readNativeAscii] - which takes a [Pointer] - cannot read them. Reading
/// them by casting the struct's address and adding a hand-computed offset
/// would be exactly the mistake the generated bindings exist to prevent;
/// walking the [Array] the way `dart:ffi` exposes it costs one bounds check
/// per character of a string that is read once per device.
///
/// The element type is `Char`, which is **signed**, so a byte above 0x7F
/// arrives as a negative number. These fields are ASCII by specification, and
/// the mask below turns a driver that violated that into mojibake rather than
/// into a negative code unit that `String.fromCharCodes` would throw on.
String readFixedAscii(Array<Char> field, int limit) {
  final List<int> units = <int>[];
  for (var i = 0; i < limit; i++) {
    final int unit = field[i] & 0xFF;
    if (unit == 0) break;
    units.add(unit);
  }
  return String.fromCharCodes(units);
}
