/// `VkInstance`, the validation policy, and choosing a physical device.
///
/// ## The validation policy, stated
///
/// **The validation layer is enabled when, and only when, the caller passes
/// `validation: true`.** It is never inferred - not from `assert`s being on,
/// not from an environment variable, not from `kDebugMode`. Three reasons, in
/// order of how much they cost when ignored:
///
///   1. **The layer changes what the program does.** It serialises calls it
///      would otherwise let through, allocates its own shadow objects, and can
///      turn a race that reproduces into one that does not. A renderer that is
///      quietly validated in development and unvalidated in production is a
///      renderer whose two configurations are different programs.
///   2. **It is not always installed**, and the machine this was written on is
///      an example: `vulkan-1.dll` is present, the Intel driver answers, and
///      `vkEnumerateInstanceLayerProperties` returns *nothing*. Inferring
///      "developer machine, therefore validation" would mean silently getting
///      no validation on exactly the machine that inferred it.
///   3. **Asking is one word.** `VulkanInstanceOptions(validation: true)` at
///      the one place a test or a tool builds an instance.
///
/// When validation is asked for and the layer is not installed, the instance
/// is still created and a [BackendDiagnostic] says so by name. Refusing would
/// mean a test that asks for validation cannot run at all on a machine without
/// the SDK, which is most machines; pretending would be worse. The caller can
/// read [VulkanInstance.validationEnabled] and skip the assertions that need
/// it - `vulkan_barrier_test.dart` does exactly that.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import 'vulkan_bindings.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_library.dart';
import 'vulkan_surface_descriptor.dart';
import 'vulkan_wsi_bindings.dart';

/// What the caller wants of an instance.
final class VulkanInstanceOptions {
  const VulkanInstanceOptions({
    this.validation = false,
    this.applicationName = 'dart_ui',
    this.surfaces = const <VulkanSurfacePlatform>{},
  });

  /// Whether to enable `VK_LAYER_KHRONOS_validation` and the debug messenger
  /// that reports what it finds. See the library comment for the policy.
  final bool validation;

  final String applicationName;

  /// Window-system platforms this instance must be able to create a surface
  /// for.
  ///
  /// Empty - the default - means an offscreen instance: no `VK_KHR_surface`,
  /// no platform extension, and [VulkanInstance.surfaceApi] is null. That is
  /// not a limitation being tolerated, it is the same policy the validation
  /// layer has and for the same reason: **an extension is enabled when, and
  /// only when, the caller asks for it.** Enabling `VK_KHR_surface`
  /// speculatively would make every offscreen test on every runner depend on a
  /// loader that has it, to buy nothing.
  ///
  /// A platform whose extension the loader does not report is a diagnostic and
  /// not a failure: the instance is still created, and
  /// [VulkanSurfaceApi.supports] answers false for it, so the caller falls back
  /// to offscreen rather than losing Vulkan entirely.
  final Set<VulkanSurfacePlatform> surfaces;
}

/// An instance, or the diagnostics explaining why there is none.
final class VulkanInstanceAttempt {
  const VulkanInstanceAttempt(this.instance, this.diagnostics);

  final VulkanInstance? instance;
  final List<BackendDiagnostic> diagnostics;

  String get failureText => diagnostics
      .where((BackendDiagnostic d) => d.isFailure)
      .map((BackendDiagnostic d) => d.toString())
      .join('; ');
}

/// One `VkInstance` and everything reachable from it without a device.
final class VulkanInstance {
  VulkanInstance._({
    required this.library,
    required this.handle,
    required this.api,
    required this.validationEnabled,
    required this.messages,
    required NativeCallable<_DebugCallbackNative>? callback,
    required Pointer<VkDebugUtilsMessengerEXT_T> messenger,
    this.surfaceApi,
    this.enabledExtensions = const <String>[],
  })  : _callback = callback,
        _messenger = messenger;

  final VulkanLibrary library;
  final Pointer<VkInstance_T> handle;
  final VulkanInstanceApi api;

  /// The `VK_KHR_surface` command table, or null on an offscreen instance.
  ///
  /// Null is the answer for every instance created without
  /// [VulkanInstanceOptions.surfaces], which is most of them, and a caller that
  /// needs a window checks it rather than assuming.
  final VulkanSurfaceApi? surfaceApi;

  /// The instance extensions actually enabled, in the order they were asked
  /// for. Empty is normal.
  final List<String> enabledExtensions;

  /// Whether this instance can create a surface for [platform].
  ///
  /// Both halves have to be true - the extension enabled *and* its creator
  /// resolved - and asking them separately is how a caller ends up with a
  /// non-null table whose function pointer is null.
  bool supportsSurface(VulkanSurfacePlatform platform) =>
      surfaceApi != null && surfaceApi!.supports(platform);

  /// Whether `VK_LAYER_KHRONOS_validation` is actually loaded, as opposed to
  /// having been asked for. A test that means to assert "the layer said
  /// nothing" has to know the difference, or it asserts nothing at all.
  final bool validationEnabled;

  /// Everything the debug messenger reported, newest last.
  ///
  /// Collected rather than printed so a test can assert on it. Bounded at
  /// [_maxMessages]: a validation error inside a loop would otherwise turn a
  /// rendering bug into an out-of-memory one.
  final List<String> messages;

  final NativeCallable<_DebugCallbackNative>? _callback;
  Pointer<VkDebugUtilsMessengerEXT_T> _messenger;
  bool _disposed = false;

  static const int _maxMessages = 256;

  /// The messages whose severity was error or warning.
  ///
  /// The interesting half. `VK_EXT_debug_utils` also reports "info" and
  /// "verbose", and the loader emits several of those on every start-up on the
  /// development machine - a test that asserted [messages] was empty would
  /// fail for reasons that are not defects.
  static bool isProblem(String message) =>
      message.startsWith('ERROR') || message.startsWith('WARNING');

  List<String> get problems => messages.where(isProblem).toList();

  /// Creates an instance, reporting rather than throwing.
  static VulkanInstanceAttempt create(
    VulkanLibrary library, {
    VulkanInstanceOptions options = const VulkanInstanceOptions(),
  }) {
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];

    final List<String> availableLayers = library.layerNames();
    final List<String> availableExtensions = library.instanceExtensionNames();

    final List<String> layers = <String>[];
    final List<String> extensions = <String>[];
    var validation = false;

    if (options.validation) {
      if (!availableLayers.contains(vkKhronosValidationLayer)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: 'validation was asked for and $vkKhronosValidationLayer is '
              'not installed; the instance is created without it',
          detail: availableLayers.isEmpty
              ? 'this loader reports no instance layers at all'
              : 'available: ${availableLayers.join(', ')}',
        ));
      } else {
        layers.add(vkKhronosValidationLayer);
        validation = true;
      }
    }

    // The messenger is worth having even without the layer: the loader itself
    // reports through it - a missing ICD, a manifest it could not parse - and
    // those are exactly the failures that otherwise arrive as a null pointer.
    final bool wantMessenger = options.validation &&
        availableExtensions.contains(vkExtDebugUtilsExtension);
    if (wantMessenger) extensions.add(vkExtDebugUtilsExtension);
    if (options.validation && !wantMessenger) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.missingLibrary,
        message: 'validation was asked for and $vkExtDebugUtilsExtension is '
            'not available; nothing will be reported',
      ));
    }

    // `VK_KHR_surface` is the base every platform extension sits on, so it
    // goes in exactly once and only when at least one platform survived.
    if (options.surfaces.isNotEmpty) {
      if (!availableExtensions.contains(vkKhrSurfaceExtension)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: 'a window surface was asked for and $vkKhrSurfaceExtension '
              'is not available; this instance can only render offscreen',
          detail: 'available: ${availableExtensions.join(', ')}',
        ));
      } else {
        final List<String> platformExtensions = <String>[];
        for (final VulkanSurfacePlatform platform in options.surfaces) {
          final String name = platform.instanceExtension;
          if (availableExtensions.contains(name)) {
            platformExtensions.add(name);
          } else {
            diagnostics.add(BackendDiagnostic(
              kind: DiagnosticKind.missingLibrary,
              message: '${platform.name} surfaces were asked for and $name is '
                  'not available on this loader',
            ));
          }
        }
        // Only if something can actually be created with it. `VK_KHR_surface`
        // alone creates no surface, and enabling it for nothing would make the
        // diagnostics say a window is possible when it is not.
        if (platformExtensions.isNotEmpty) {
          extensions
            ..add(vkKhrSurfaceExtension)
            ..addAll(platformExtensions);
        }
      }
    }

    final NativeArena arena = NativeArena();
    Pointer<VkInstance_T> handle = nullptr;
    try {
      final Pointer<VkApplicationInfo> application = arena<VkApplicationInfo>();
      application.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO
        ..pApplicationName =
            arena.allocateAscii(options.applicationName).cast<Char>()
        ..applicationVersion = vkMakeApiVersion(1, 0, 0)
        ..pEngineName = arena.allocateAscii('dart_ui').cast<Char>()
        ..engineVersion = vkMakeApiVersion(1, 0, 0)
        // Vulkan 1.0 on purpose. `apiVersion` is a promise about what the
        // application may call, not a request for the newest driver: asking
        // for 1.3 on a 1.1 driver is `VK_ERROR_INCOMPATIBLE_DRIVER` at
        // creation, and this backend uses no command that postdates 1.0.
        ..apiVersion = vkMakeApiVersion(1, 0, 0);

      final Pointer<VkInstanceCreateInfo> info = arena<VkInstanceCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        ..pApplicationInfo = application
        ..enabledLayerCount = layers.length
        ..ppEnabledLayerNames = _stringArray(arena, layers)
        ..enabledExtensionCount = extensions.length
        ..ppEnabledExtensionNames = _stringArray(arena, extensions);

      final Pointer<Pointer<VkInstance_T>> out = arena<Pointer<VkInstance_T>>();
      final int result = library.createInstance(info, nullptr, out);
      if (vkFailed(result)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateInstance refused',
          detail: '${vkResultName(result)}'
              '${layers.isEmpty ? '' : ', layers ${layers.join(', ')}'}'
              '${extensions.isEmpty ? '' : ', extensions '
                  '${extensions.join(', ')}'}',
        ));
        return VulkanInstanceAttempt(null, diagnostics);
      }
      handle = out.value;

      final VulkanInstanceApi api = VulkanInstanceApi.bind(library, handle);
      // Null when `VK_KHR_surface` was not enabled, and also when it was and
      // the loader still did not resolve all five - which happens with a
      // mismatched layer in the chain and is worth a diagnostic rather than a
      // crash at the first present.
      final VulkanSurfaceApi? surfaceApi =
          extensions.contains(vkKhrSurfaceExtension)
              ? VulkanSurfaceApi.bind(library, handle)
              : null;
      if (extensions.contains(vkKhrSurfaceExtension) && surfaceApi == null) {
        diagnostics.add(const BackendDiagnostic(
          kind: DiagnosticKind.missingSymbol,
          message: '$vkKhrSurfaceExtension was enabled and its commands did '
              'not all resolve; this instance can only render offscreen',
        ));
      }
      final List<String> messages = <String>[];
      NativeCallable<_DebugCallbackNative>? callback;
      Pointer<VkDebugUtilsMessengerEXT_T> messenger = nullptr;

      if (wantMessenger && api.hasDebugUtils) {
        callback = NativeCallable<_DebugCallbackNative>.isolateLocal(
          (int severity, int types, Pointer<Void> data, Pointer<Void> user) =>
              _record(messages, severity, data),
          exceptionalReturn: vkFalse,
        );
        final Pointer<VkDebugUtilsMessengerCreateInfoEXT> messengerInfo =
            arena<VkDebugUtilsMessengerCreateInfoEXT>();
        messengerInfo.ref
          ..sType = VkStructureType
              .VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
          ..messageSeverity = VkDebugUtilsMessageSeverityFlagBitsEXT
                  .VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
              VkDebugUtilsMessageSeverityFlagBitsEXT
                  .VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
          ..messageType = VkDebugUtilsMessageTypeFlagBitsEXT
                  .VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
              VkDebugUtilsMessageTypeFlagBitsEXT
                  .VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
          ..pfnUserCallback = callback.nativeFunction.cast();

        final Pointer<Pointer<VkDebugUtilsMessengerEXT_T>> messengerOut =
            arena<Pointer<VkDebugUtilsMessengerEXT_T>>();
        final int created = api.createDebugUtilsMessenger!(
            handle, messengerInfo, nullptr, messengerOut);
        if (vkFailed(created)) {
          diagnostics.add(BackendDiagnostic(
            kind: DiagnosticKind.missingSymbol,
            message: 'vkCreateDebugUtilsMessengerEXT refused; validation '
                'findings will not be reported',
            detail: vkResultName(created),
          ));
          callback.close();
          callback = null;
        } else {
          messenger = messengerOut.value;
        }
      }

      diagnostics.add(BackendDiagnostic.note(
        'Vulkan instance on ${library.path}, loader '
        '${vkVersionText(library.instanceVersion())}, validation '
        '${validation ? 'enabled' : 'off'}',
      ));

      return VulkanInstanceAttempt(
        VulkanInstance._(
          library: library,
          handle: handle,
          api: api,
          surfaceApi: surfaceApi,
          enabledExtensions: List<String>.unmodifiable(extensions),
          validationEnabled: validation,
          messages: messages,
          callback: callback,
          messenger: messenger,
        ),
        diagnostics,
      );
    } on VulkanSymbolError catch (error) {
      diagnostics.add(BackendDiagnostic.missingSymbol(error.symbol,
          detail: 'at ${error.level} level'));
      return VulkanInstanceAttempt(null, diagnostics);
    } finally {
      arena.dispose();
    }
  }

  /// Every physical device this instance can see, in the order the driver
  /// reported them.
  List<VulkanPhysicalDevice> physicalDevices() => using((NativeArena arena) {
        final Pointer<Uint32> count = arena<Uint32>();
        if (vkFailed(api.enumeratePhysicalDevices(handle, count, nullptr)) ||
            count.value == 0) {
          return const <VulkanPhysicalDevice>[];
        }
        final Pointer<Pointer<VkPhysicalDevice_T>> items =
            arena<Pointer<VkPhysicalDevice_T>>(count.value);
        if (vkFailed(api.enumeratePhysicalDevices(handle, count, items))) {
          return const <VulkanPhysicalDevice>[];
        }
        return <VulkanPhysicalDevice>[
          for (var i = 0; i < count.value; i++)
            VulkanPhysicalDevice._(this, items[i]),
        ];
      });

  /// The device this backend would choose, or null when none will do.
  ///
  /// The rule, in order: a discrete GPU beats an integrated one beats anything
  /// else, and within a tier the first the driver reported wins. A device with
  /// no graphics queue family is not a candidate at all.
  ///
  /// Deliberately *not* "the one with the most memory" or "the one the display
  /// is attached to": this backend renders offscreen, and the second question
  /// cannot be answered without a surface. When a swapchain arrives, presented
  /// support becomes a filter here and this comment is the record of why it
  /// was not one before.
  VulkanPhysicalDevice? chooseDevice() {
    VulkanPhysicalDevice? best;
    var bestRank = -1;
    for (final VulkanPhysicalDevice device in physicalDevices()) {
      if (device.graphicsQueueFamily == null) continue;
      final int rank = switch (device.deviceType) {
        VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
        VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
        VkPhysicalDeviceType.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
        _ => 0,
      };
      if (rank > bestRank) {
        best = device;
        bestRank = rank;
      }
    }
    return best;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_messenger != nullptr) {
      api.destroyDebugUtilsMessenger!(handle, _messenger, nullptr);
      _messenger = nullptr;
    }
    // After the messenger, never before: the driver may report during
    // vkDestroyInstance, and a callback whose Dart closure is gone is a jump
    // into freed memory.
    api.destroyInstance(handle, nullptr);
    _callback?.close();
  }

  static int _record(
    List<String> messages,
    int severity,
    Pointer<Void> data,
  ) {
    final Pointer<VkDebugUtilsMessengerCallbackDataEXT> typed =
        data.cast<VkDebugUtilsMessengerCallbackDataEXT>();
    final String level = (severity &
                VkDebugUtilsMessageSeverityFlagBitsEXT
                    .VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) !=
            0
        ? 'ERROR'
        : 'WARNING';
    final String text = data == nullptr
        ? '(no message)'
        : readNativeUtf8(typed.ref.pMessage.cast<Uint8>(), limit: 4096);
    if (messages.length >= _maxMessages) messages.removeAt(0);
    messages.add('$level: $text');
    // VK_FALSE: "do not abort the call that produced this message". Returning
    // VK_TRUE is only for layer development and turns every warning into a
    // failed API call.
    return vkFalse;
  }

  static Pointer<Pointer<Char>> _stringArray(
      NativeArena arena, List<String> values) {
    if (values.isEmpty) return nullptr;
    final Pointer<Pointer<Char>> array = arena<Pointer<Char>>(values.length);
    for (var i = 0; i < values.length; i++) {
      array[i] = arena.allocateAscii(values[i]).cast<Char>();
    }
    return array;
  }
}

/// O terceiro parametro e `Pointer<Void>` e nao
/// `Pointer<VkDebugUtilsMessengerCallbackDataEXT>` de proposito.
///
/// Na ABI os dois sao a mesma coisa - um ponteiro -, mas nomear o
/// `Struct` aqui faz o compilador AOT tentar reter a *classe* dele no
/// snapshot, e ele recusa: `Unexpected object (Class with illegal cid,
/// full-aot)`. O sintoma nao aparece em JIT nem num programa que so
/// importa a biblioteca; aparece em `dart compile exe` de qualquer
/// aplicacao que alcance o seletor de apresentacao, porque e ele que
/// torna este arquivo alcancavel.
///
/// O cast para o tipo real acontece em [_VulkanInstanceBuilder._record],
/// do lado Dart, onde nao ha snapshot a gerar.
typedef _DebugCallbackNative = Uint32 Function(
    Uint32, Uint32, Pointer<Void>, Pointer<Void>);

/// One `VkPhysicalDevice`, with the properties read once.
///
/// Read once because `vkGetPhysicalDeviceProperties` copies 824 bytes and the
/// answers cannot change while the instance lives, and because the fields a
/// caller wants - the name, the limits - are then plain Dart values rather
/// than something that needs an arena at every use.
final class VulkanPhysicalDevice {
  VulkanPhysicalDevice._(this.instance, this.handle) {
    using((NativeArena arena) {
      final Pointer<VkPhysicalDeviceProperties> properties =
          arena<VkPhysicalDeviceProperties>();
      instance.api.getPhysicalDeviceProperties(handle, properties);
      name = readFixedAscii(
          properties.ref.deviceName, vkMaxPhysicalDeviceNameSize);
      apiVersion = properties.ref.apiVersion;
      driverVersion = properties.ref.driverVersion;
      vendorId = properties.ref.vendorID;
      deviceId = properties.ref.deviceID;
      deviceType = properties.ref.deviceType;
      maxImageDimension2D = properties.ref.limits.maxImageDimension2D;
      maxPushConstantsSize = properties.ref.limits.maxPushConstantsSize;
      minMemoryMapAlignment = properties.ref.limits.minMemoryMapAlignment;
      nonCoherentAtomSize = properties.ref.limits.nonCoherentAtomSize;
      optimalBufferCopyRowPitchAlignment =
          properties.ref.limits.optimalBufferCopyRowPitchAlignment;

      final Pointer<Uint32> count = arena<Uint32>();
      instance.api
          .getPhysicalDeviceQueueFamilyProperties(handle, count, nullptr);
      final Pointer<VkQueueFamilyProperties> families =
          arena<VkQueueFamilyProperties>(count.value);
      instance.api
          .getPhysicalDeviceQueueFamilyProperties(handle, count, families);
      queueFamilyFlags = List<int>.unmodifiable(<int>[
        for (var i = 0; i < count.value; i++) families[i].queueFlags,
      ]);
    });
  }

  final VulkanInstance instance;
  final Pointer<VkPhysicalDevice_T> handle;

  late final String name;
  late final int apiVersion;
  late final int driverVersion;
  late final int vendorId;
  late final int deviceId;
  late final int deviceType;
  late final int maxImageDimension2D;
  late final int maxPushConstantsSize;
  late final int minMemoryMapAlignment;
  late final int nonCoherentAtomSize;
  late final int optimalBufferCopyRowPitchAlignment;

  /// `queueFlags` for each family, indexed by family.
  late final List<int> queueFamilyFlags;

  /// The family this backend submits everything to, or null when there is
  /// none.
  ///
  /// One queue, and it is the graphics one. Vulkan lets a driver expose a
  /// dedicated transfer family whose DMA engine can upload while the graphics
  /// engine draws, and this renderer would gain nothing from it: its uploads
  /// are a vertex buffer and two atlas regions that the very next draw call
  /// reads, so the transfer would have to be waited on immediately and the
  /// ownership transfer between families would cost two extra barriers to save
  /// nothing. A graphics family is required to support transfer operations, so
  /// one family covers every command this backend records.
  int? get graphicsQueueFamily {
    for (var i = 0; i < queueFamilyFlags.length; i++) {
      if ((queueFamilyFlags[i] & VkQueueFlagBits.VK_QUEUE_GRAPHICS_BIT) != 0) {
        return i;
      }
    }
    return null;
  }

  /// `optimalTilingFeatures` for [format].
  int optimalTilingFeatures(int format) => using((NativeArena arena) {
        final Pointer<VkFormatProperties> properties =
            arena<VkFormatProperties>();
        instance.api
            .getPhysicalDeviceFormatProperties(handle, format, properties);
        return properties.ref.optimalTilingFeatures;
      });

  /// Whether [format] can be a colour attachment that is also sampled and
  /// copied, which is what every image this renderer creates needs.
  bool supportsRenderTarget(int format) {
    const int needed = VkFormatFeatureFlagBits
            .VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        VkFormatFeatureFlagBits.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
        VkFormatFeatureFlagBits.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
    return optimalTilingFeatures(format) & needed == needed;
  }

  /// Whether [format] can be sampled, which is what an atlas needs.
  bool supportsSampling(int format) =>
      optimalTilingFeatures(format) &
          VkFormatFeatureFlagBits.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT !=
      0;

  /// Extension names this device offers.
  List<String> extensionNames() => using((NativeArena arena) {
        final Pointer<Uint32> count = arena<Uint32>();
        if (vkFailed(instance.api.enumerateDeviceExtensionProperties(
            handle, nullptr, count, nullptr))) {
          return const <String>[];
        }
        if (count.value == 0) return const <String>[];
        final Pointer<VkExtensionProperties> items =
            arena<VkExtensionProperties>(count.value);
        if (vkFailed(instance.api.enumerateDeviceExtensionProperties(
            handle, nullptr, count, items))) {
          return const <String>[];
        }
        return <String>[
          for (var i = 0; i < count.value; i++)
            readFixedAscii(items[i].extensionName, vkMaxExtensionNameSize),
        ];
      });

  @override
  String toString() => '$name (${vkPhysicalDeviceTypeName(deviceType)}, '
      'Vulkan ${vkVersionText(apiVersion)}, vendor '
      '0x${vendorId.toRadixString(16)})';
}
