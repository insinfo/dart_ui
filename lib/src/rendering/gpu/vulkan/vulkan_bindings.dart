/// The instance-level and device-level Vulkan command tables.
///
/// ## Why the commands are not generated
///
/// `vulkan_ffi.g.dart` is produced by `ffigen` and this file is not, which is
/// a deliberate exception recorded in `tool/ffigen_vulkan.yaml`. `ffigen`
/// binds a C function by `DynamicLibrary.lookup`, and that is the wrong door
/// for Vulkan. The specification says a command is reached through one of
/// three dispatch levels:
///
///   * **Global** commands take no dispatchable handle -
///     `vkEnumerateInstanceLayerProperties`, `vkCreateInstance`. They are
///     resolved through `vkGetInstanceProcAddr(VK_NULL_HANDLE, name)`, in
///     `vulkan_library.dart`.
///   * **Instance** commands take a `VkInstance` or a `VkPhysicalDevice` and
///     are resolved through `vkGetInstanceProcAddr(instance, name)`.
///   * **Device** commands take a `VkDevice`, `VkQueue` or `VkCommandBuffer`
///     and are resolved through `vkGetDeviceProcAddr(device, name)`.
///
/// That last one is not pedantry. A pointer from `vkGetInstanceProcAddr` for a
/// device command points at the loader's *trampoline*, which reads the
/// dispatch table out of the handle and jumps; a pointer from
/// `vkGetDeviceProcAddr` points straight at the driver. On a machine with two
/// ICDs - the development machine has an Intel driver and Microsoft's Direct3D
/// 12 emulation layer both answering - the trampoline is the only thing that
/// keeps `vkCmdDraw` on device A out of driver B. Pulling `vkCmdDraw` out of
/// `vulkan-1.dll`'s export table, which is what a generated binding would do,
/// gets the trampoline for *every* command and works right up until it does
/// not.
///
/// ## Why the signatures are generic type aliases
///
/// Vulkan's command set is extremely regular: nearly every object is created
/// by `vkCreateX(device, const VkXCreateInfo*, const VkAllocationCallbacks*,
/// VkX*)` and destroyed by `vkDestroyX(device, VkX, const
/// VkAllocationCallbacks*)`. Writing two `typedef`s per command would be a
/// hundred and thirty lines whose only content is which two types appear in
/// them, and a hundred and thirty chances to pair the wrong create-info with
/// the wrong handle.
///
/// So the shapes are declared once, parameterised: [VkCreateNative]
/// instantiated at `<VkBufferCreateInfo, VkBuffer_T>` is `vkCreateBuffer`'s
/// exact signature, and it cannot be handed a `VkImageCreateInfo` or asked to
/// write a `VkImage` out, because the type arguments are checked like any
/// other generic. The seventeen destroy commands differ only in their handle
/// type and share one alias.
///
/// ## `VkAllocationCallbacks*` is always null and is still in every signature
///
/// This backend supplies no host allocator. The parameter stays as an explicit
/// `Pointer<Void>` in every signature rather than being dropped, because the C
/// ABI counts arguments: a binding that omits it would leave the *next* stack
/// slot holding the previous argument's value, and on the create commands that
/// next slot is the out-pointer the driver writes a handle through.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_library.dart';

// ---------------------------------------------------------------------------
// The shapes, declared once each
// ---------------------------------------------------------------------------

typedef VkCreateNative<I extends NativeType, H extends NativeType>
    = Int32 Function(
        Pointer<VkDevice_T>, Pointer<I>, Pointer<Void>, Pointer<Pointer<H>>);
typedef VkCreateDart<I extends NativeType, H extends NativeType> = int Function(
    Pointer<VkDevice_T>, Pointer<I>, Pointer<Void>, Pointer<Pointer<H>>);

typedef VkDestroyNative<H extends NativeType> = Void Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<Void>);
typedef VkDestroyDart<H extends NativeType> = void Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<Void>);

typedef VkRequirementsNative<H extends NativeType> = Void Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<VkMemoryRequirements>);
typedef VkRequirementsDart<H extends NativeType> = void Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<VkMemoryRequirements>);

typedef VkBindMemoryNative<H extends NativeType> = Int32 Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<VkDeviceMemory_T>, Uint64);
typedef VkBindMemoryDart<H extends NativeType> = int Function(
    Pointer<VkDevice_T>, Pointer<H>, Pointer<VkDeviceMemory_T>, int);

// ---------------------------------------------------------------------------
// Instance level
// ---------------------------------------------------------------------------

typedef VkDestroyInstanceNative = Void Function(
    Pointer<VkInstance_T>, Pointer<Void>);
typedef VkDestroyInstanceDart = void Function(
    Pointer<VkInstance_T>, Pointer<Void>);

typedef VkEnumeratePhysicalDevicesNative = Int32 Function(Pointer<VkInstance_T>,
    Pointer<Uint32>, Pointer<Pointer<VkPhysicalDevice_T>>);
typedef VkEnumeratePhysicalDevicesDart = int Function(Pointer<VkInstance_T>,
    Pointer<Uint32>, Pointer<Pointer<VkPhysicalDevice_T>>);

typedef VkGetPhysicalDevicePropertiesNative<T extends NativeType> = Void
    Function(Pointer<VkPhysicalDevice_T>, Pointer<T>);
typedef VkGetPhysicalDevicePropertiesDart<T extends NativeType> = void Function(
    Pointer<VkPhysicalDevice_T>, Pointer<T>);

typedef VkGetQueueFamilyPropertiesNative = Void Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<Uint32>,
    Pointer<VkQueueFamilyProperties>);
typedef VkGetQueueFamilyPropertiesDart = void Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<Uint32>,
    Pointer<VkQueueFamilyProperties>);

typedef VkGetFormatPropertiesNative = Void Function(
    Pointer<VkPhysicalDevice_T>, Uint32, Pointer<VkFormatProperties>);
typedef VkGetFormatPropertiesDart = void Function(
    Pointer<VkPhysicalDevice_T>, int, Pointer<VkFormatProperties>);

typedef VkEnumerateDeviceExtensionPropertiesNative = Int32 Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<Char>,
    Pointer<Uint32>,
    Pointer<VkExtensionProperties>);
typedef VkEnumerateDeviceExtensionPropertiesDart = int Function(
    Pointer<VkPhysicalDevice_T>,
    Pointer<Char>,
    Pointer<Uint32>,
    Pointer<VkExtensionProperties>);

typedef VkCreateDeviceNative = Int32 Function(Pointer<VkPhysicalDevice_T>,
    Pointer<VkDeviceCreateInfo>, Pointer<Void>, Pointer<Pointer<VkDevice_T>>);
typedef VkCreateDeviceDart = int Function(Pointer<VkPhysicalDevice_T>,
    Pointer<VkDeviceCreateInfo>, Pointer<Void>, Pointer<Pointer<VkDevice_T>>);

typedef VkGetDeviceProcAddrNative = Pointer<Void> Function(
    Pointer<VkDevice_T>, Pointer<Char>);
typedef VkGetDeviceProcAddrDart = Pointer<Void> Function(
    Pointer<VkDevice_T>, Pointer<Char>);

typedef VkCreateDebugMessengerNative = Int32 Function(
    Pointer<VkInstance_T>,
    Pointer<VkDebugUtilsMessengerCreateInfoEXT>,
    Pointer<Void>,
    Pointer<Pointer<VkDebugUtilsMessengerEXT_T>>);
typedef VkCreateDebugMessengerDart = int Function(
    Pointer<VkInstance_T>,
    Pointer<VkDebugUtilsMessengerCreateInfoEXT>,
    Pointer<Void>,
    Pointer<Pointer<VkDebugUtilsMessengerEXT_T>>);

typedef VkDestroyDebugMessengerNative = Void Function(
    Pointer<VkInstance_T>, Pointer<VkDebugUtilsMessengerEXT_T>, Pointer<Void>);
typedef VkDestroyDebugMessengerDart = void Function(
    Pointer<VkInstance_T>, Pointer<VkDebugUtilsMessengerEXT_T>, Pointer<Void>);

/// The commands that take a `VkInstance` or a `VkPhysicalDevice`.
final class VulkanInstanceApi {
  VulkanInstanceApi._({
    required this.destroyInstance,
    required this.enumeratePhysicalDevices,
    required this.getPhysicalDeviceProperties,
    required this.getPhysicalDeviceQueueFamilyProperties,
    required this.getPhysicalDeviceMemoryProperties,
    required this.getPhysicalDeviceFormatProperties,
    required this.enumerateDeviceExtensionProperties,
    required this.createDevice,
    required this.getDeviceProcAddr,
    required this.createDebugUtilsMessenger,
    required this.destroyDebugUtilsMessenger,
  });

  /// Every instance-level command this table resolves, in the order [bind]
  /// asks for them.
  ///
  /// Public so `vulkan_symbol_test.dart` can prove each one resolves against a
  /// real loader, which is the symbol test section 11.4 asks for. A list that
  /// drifts out of step with [bind] would make that test vacuous, so
  /// `vulkan_symbol_test.dart` also checks that binding an instance succeeds -
  /// binding is what would throw on a name this list forgot.
  static const List<String> requiredSymbols = <String>[
    'vkDestroyInstance',
    'vkEnumeratePhysicalDevices',
    'vkGetPhysicalDeviceProperties',
    'vkGetPhysicalDeviceQueueFamilyProperties',
    'vkGetPhysicalDeviceMemoryProperties',
    'vkGetPhysicalDeviceFormatProperties',
    'vkEnumerateDeviceExtensionProperties',
    'vkCreateDevice',
    'vkGetDeviceProcAddr',
  ];

  /// Commands that exist only when `VK_EXT_debug_utils` was enabled.
  static const List<String> optionalSymbols = <String>[
    'vkCreateDebugUtilsMessengerEXT',
    'vkDestroyDebugUtilsMessengerEXT',
  ];

  final VkDestroyInstanceDart destroyInstance;
  final VkEnumeratePhysicalDevicesDart enumeratePhysicalDevices;
  final VkGetPhysicalDevicePropertiesDart<VkPhysicalDeviceProperties>
      getPhysicalDeviceProperties;
  final VkGetQueueFamilyPropertiesDart getPhysicalDeviceQueueFamilyProperties;
  final VkGetPhysicalDevicePropertiesDart<VkPhysicalDeviceMemoryProperties>
      getPhysicalDeviceMemoryProperties;
  final VkGetFormatPropertiesDart getPhysicalDeviceFormatProperties;
  final VkEnumerateDeviceExtensionPropertiesDart
      enumerateDeviceExtensionProperties;
  final VkCreateDeviceDart createDevice;
  final VkGetDeviceProcAddrDart getDeviceProcAddr;

  /// Null unless `VK_EXT_debug_utils` was enabled on the instance. The pair is
  /// nullable together: a messenger that can be created and not destroyed is a
  /// leak that outlives the instance.
  final VkCreateDebugMessengerDart? createDebugUtilsMessenger;
  final VkDestroyDebugMessengerDart? destroyDebugUtilsMessenger;

  bool get hasDebugUtils => createDebugUtilsMessenger != null;

  static VulkanInstanceApi bind(
    VulkanLibrary library,
    Pointer<VkInstance_T> instance,
  ) {
    // Two helpers rather than one, and both return a *pointer* rather than a
    // Dart function: `Pointer.asFunction` refuses a type argument that is a
    // type parameter - the native signature has to be a compile-time constant
    // at the call site - so the cast can be shared and the `asFunction` cannot.
    Pointer<NativeFunction<T>> proc<T extends Function>(String symbol) {
      final Pointer<Void> address = library.instanceProc(instance, symbol);
      if (address == nullptr) throw VulkanSymbolError(symbol, 'instance');
      return address.cast<NativeFunction<T>>();
    }

    Pointer<NativeFunction<T>> maybe<T extends Function>(String symbol) =>
        library.instanceProc(instance, symbol).cast<NativeFunction<T>>();

    final Pointer<NativeFunction<VkCreateDebugMessengerNative>> createAddress =
        maybe<VkCreateDebugMessengerNative>('vkCreateDebugUtilsMessengerEXT');
    final Pointer<NativeFunction<VkDestroyDebugMessengerNative>>
        destroyAddress = createAddress == nullptr
            ? nullptr
            : maybe<VkDestroyDebugMessengerNative>(
                'vkDestroyDebugUtilsMessengerEXT');
    final VkCreateDebugMessengerDart? createMessenger =
        createAddress == nullptr || destroyAddress == nullptr
            ? null
            : createAddress.asFunction<VkCreateDebugMessengerDart>();
    final VkDestroyDebugMessengerDart? destroyMessenger =
        createMessenger == null
            ? null
            : destroyAddress.asFunction<VkDestroyDebugMessengerDart>();

    return VulkanInstanceApi._(
      destroyInstance: proc<VkDestroyInstanceNative>('vkDestroyInstance')
          .asFunction<VkDestroyInstanceDart>(),
      enumeratePhysicalDevices:
          proc<VkEnumeratePhysicalDevicesNative>('vkEnumeratePhysicalDevices')
              .asFunction<VkEnumeratePhysicalDevicesDart>(),
      getPhysicalDeviceProperties:
          proc<VkGetPhysicalDevicePropertiesNative<VkPhysicalDeviceProperties>>(
                  'vkGetPhysicalDeviceProperties')
              .asFunction<
                  VkGetPhysicalDevicePropertiesDart<
                      VkPhysicalDeviceProperties>>(),
      getPhysicalDeviceQueueFamilyProperties:
          proc<VkGetQueueFamilyPropertiesNative>(
                  'vkGetPhysicalDeviceQueueFamilyProperties')
              .asFunction<VkGetQueueFamilyPropertiesDart>(),
      getPhysicalDeviceMemoryProperties: proc<
                  VkGetPhysicalDevicePropertiesNative<
                      VkPhysicalDeviceMemoryProperties>>(
              'vkGetPhysicalDeviceMemoryProperties')
          .asFunction<
              VkGetPhysicalDevicePropertiesDart<
                  VkPhysicalDeviceMemoryProperties>>(),
      getPhysicalDeviceFormatProperties: proc<VkGetFormatPropertiesNative>(
              'vkGetPhysicalDeviceFormatProperties')
          .asFunction<VkGetFormatPropertiesDart>(),
      enumerateDeviceExtensionProperties:
          proc<VkEnumerateDeviceExtensionPropertiesNative>(
                  'vkEnumerateDeviceExtensionProperties')
              .asFunction<VkEnumerateDeviceExtensionPropertiesDart>(),
      createDevice: proc<VkCreateDeviceNative>('vkCreateDevice')
          .asFunction<VkCreateDeviceDart>(),
      getDeviceProcAddr: proc<VkGetDeviceProcAddrNative>('vkGetDeviceProcAddr')
          .asFunction<VkGetDeviceProcAddrDart>(),
      createDebugUtilsMessenger: createMessenger,
      destroyDebugUtilsMessenger: destroyMessenger,
    );
  }
}

// ---------------------------------------------------------------------------
// Device level
// ---------------------------------------------------------------------------

typedef VkDestroyDeviceNative = Void Function(
    Pointer<VkDevice_T>, Pointer<Void>);
typedef VkDestroyDeviceDart = void Function(Pointer<VkDevice_T>, Pointer<Void>);

typedef VkGetDeviceQueueNative = Void Function(
    Pointer<VkDevice_T>, Uint32, Uint32, Pointer<Pointer<VkQueue_T>>);
typedef VkGetDeviceQueueDart = void Function(
    Pointer<VkDevice_T>, int, int, Pointer<Pointer<VkQueue_T>>);

typedef VkDeviceWaitIdleNative = Int32 Function(Pointer<VkDevice_T>);
typedef VkDeviceWaitIdleDart = int Function(Pointer<VkDevice_T>);

typedef VkQueueWaitIdleNative = Int32 Function(Pointer<VkQueue_T>);
typedef VkQueueWaitIdleDart = int Function(Pointer<VkQueue_T>);

typedef VkQueueSubmitNative = Int32 Function(
    Pointer<VkQueue_T>, Uint32, Pointer<VkSubmitInfo>, Pointer<VkFence_T>);
typedef VkQueueSubmitDart = int Function(
    Pointer<VkQueue_T>, int, Pointer<VkSubmitInfo>, Pointer<VkFence_T>);

typedef VkResetCommandPoolNative = Int32 Function(
    Pointer<VkDevice_T>, Pointer<VkCommandPool_T>, Uint32);
typedef VkResetCommandPoolDart = int Function(
    Pointer<VkDevice_T>, Pointer<VkCommandPool_T>, int);

typedef VkAllocateCommandBuffersNative = Int32 Function(Pointer<VkDevice_T>,
    Pointer<VkCommandBufferAllocateInfo>, Pointer<Pointer<VkCommandBuffer_T>>);
typedef VkAllocateCommandBuffersDart = int Function(Pointer<VkDevice_T>,
    Pointer<VkCommandBufferAllocateInfo>, Pointer<Pointer<VkCommandBuffer_T>>);

typedef VkFreeCommandBuffersNative = Void Function(Pointer<VkDevice_T>,
    Pointer<VkCommandPool_T>, Uint32, Pointer<Pointer<VkCommandBuffer_T>>);
typedef VkFreeCommandBuffersDart = void Function(Pointer<VkDevice_T>,
    Pointer<VkCommandPool_T>, int, Pointer<Pointer<VkCommandBuffer_T>>);

typedef VkBeginCommandBufferNative = Int32 Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkCommandBufferBeginInfo>);
typedef VkBeginCommandBufferDart = int Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkCommandBufferBeginInfo>);

typedef VkEndCommandBufferNative = Int32 Function(Pointer<VkCommandBuffer_T>);
typedef VkEndCommandBufferDart = int Function(Pointer<VkCommandBuffer_T>);

typedef VkWaitForFencesNative = Int32 Function(
    Pointer<VkDevice_T>, Uint32, Pointer<Pointer<VkFence_T>>, Uint32, Uint64);
typedef VkWaitForFencesDart = int Function(
    Pointer<VkDevice_T>, int, Pointer<Pointer<VkFence_T>>, int, int);

typedef VkResetFencesNative = Int32 Function(
    Pointer<VkDevice_T>, Uint32, Pointer<Pointer<VkFence_T>>);
typedef VkResetFencesDart = int Function(
    Pointer<VkDevice_T>, int, Pointer<Pointer<VkFence_T>>);

typedef VkGetFenceStatusNative = Int32 Function(
    Pointer<VkDevice_T>, Pointer<VkFence_T>);
typedef VkGetFenceStatusDart = int Function(
    Pointer<VkDevice_T>, Pointer<VkFence_T>);

typedef VkEventCommandNative = Int32 Function(
    Pointer<VkDevice_T>, Pointer<VkEvent_T>);
typedef VkEventCommandDart = int Function(
    Pointer<VkDevice_T>, Pointer<VkEvent_T>);

typedef VkCmdWaitEventsNative = Void Function(
    Pointer<VkCommandBuffer_T>,
    Uint32,
    Pointer<Pointer<VkEvent_T>>,
    Uint32,
    Uint32,
    Uint32,
    Pointer<VkMemoryBarrier>,
    Uint32,
    Pointer<Void>,
    Uint32,
    Pointer<VkImageMemoryBarrier>);
typedef VkCmdWaitEventsDart = void Function(
    Pointer<VkCommandBuffer_T>,
    int,
    Pointer<Pointer<VkEvent_T>>,
    int,
    int,
    int,
    Pointer<VkMemoryBarrier>,
    int,
    Pointer<Void>,
    int,
    Pointer<VkImageMemoryBarrier>);

typedef VkMapMemoryNative = Int32 Function(Pointer<VkDevice_T>,
    Pointer<VkDeviceMemory_T>, Uint64, Uint64, Uint32, Pointer<Pointer<Void>>);
typedef VkMapMemoryDart = int Function(Pointer<VkDevice_T>,
    Pointer<VkDeviceMemory_T>, int, int, int, Pointer<Pointer<Void>>);

typedef VkUnmapMemoryNative = Void Function(
    Pointer<VkDevice_T>, Pointer<VkDeviceMemory_T>);
typedef VkUnmapMemoryDart = void Function(
    Pointer<VkDevice_T>, Pointer<VkDeviceMemory_T>);

typedef VkMappedRangesNative = Int32 Function(
    Pointer<VkDevice_T>, Uint32, Pointer<VkMappedMemoryRange>);
typedef VkMappedRangesDart = int Function(
    Pointer<VkDevice_T>, int, Pointer<VkMappedMemoryRange>);

/// `vkCreateGraphicsPipelines`, whose second argument is a `VkPipelineCache`.
///
/// Spelled `Pointer<Void>` and always passed `nullptr`: this renderer builds
/// its handful of pipelines once at device creation, so a cache would save
/// nothing and would be one more object to serialise, version and invalidate.
/// `VkPipelineCache_T` is therefore not among the generated handle types.
typedef VkCreateGraphicsPipelinesNative = Int32 Function(
    Pointer<VkDevice_T>,
    Pointer<Void>,
    Uint32,
    Pointer<VkGraphicsPipelineCreateInfo>,
    Pointer<Void>,
    Pointer<Pointer<VkPipeline_T>>);
typedef VkCreateGraphicsPipelinesDart = int Function(
    Pointer<VkDevice_T>,
    Pointer<Void>,
    int,
    Pointer<VkGraphicsPipelineCreateInfo>,
    Pointer<Void>,
    Pointer<Pointer<VkPipeline_T>>);

typedef VkAllocateDescriptorSetsNative = Int32 Function(Pointer<VkDevice_T>,
    Pointer<VkDescriptorSetAllocateInfo>, Pointer<Pointer<VkDescriptorSet_T>>);
typedef VkAllocateDescriptorSetsDart = int Function(Pointer<VkDevice_T>,
    Pointer<VkDescriptorSetAllocateInfo>, Pointer<Pointer<VkDescriptorSet_T>>);

typedef VkUpdateDescriptorSetsNative = Void Function(Pointer<VkDevice_T>,
    Uint32, Pointer<VkWriteDescriptorSet>, Uint32, Pointer<Void>);
typedef VkUpdateDescriptorSetsDart = void Function(Pointer<VkDevice_T>, int,
    Pointer<VkWriteDescriptorSet>, int, Pointer<Void>);

typedef VkResetDescriptorPoolNative = Int32 Function(
    Pointer<VkDevice_T>, Pointer<VkDescriptorPool_T>, Uint32);
typedef VkResetDescriptorPoolDart = int Function(
    Pointer<VkDevice_T>, Pointer<VkDescriptorPool_T>, int);

typedef VkCmdPipelineBarrierNative = Void Function(
    Pointer<VkCommandBuffer_T>,
    Uint32,
    Uint32,
    Uint32,
    Uint32,
    Pointer<VkMemoryBarrier>,
    Uint32,
    Pointer<Void>,
    Uint32,
    Pointer<VkImageMemoryBarrier>);
typedef VkCmdPipelineBarrierDart = void Function(
    Pointer<VkCommandBuffer_T>,
    int,
    int,
    int,
    int,
    Pointer<VkMemoryBarrier>,
    int,
    Pointer<Void>,
    int,
    Pointer<VkImageMemoryBarrier>);

typedef VkCmdBeginRenderPassNative = Void Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkRenderPassBeginInfo>, Uint32);
typedef VkCmdBeginRenderPassDart = void Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkRenderPassBeginInfo>, int);

typedef VkCmdEndRenderPassNative = Void Function(Pointer<VkCommandBuffer_T>);
typedef VkCmdEndRenderPassDart = void Function(Pointer<VkCommandBuffer_T>);

typedef VkCmdBindPipelineNative = Void Function(
    Pointer<VkCommandBuffer_T>, Uint32, Pointer<VkPipeline_T>);
typedef VkCmdBindPipelineDart = void Function(
    Pointer<VkCommandBuffer_T>, int, Pointer<VkPipeline_T>);

typedef VkCmdBindVertexBuffersNative = Void Function(Pointer<VkCommandBuffer_T>,
    Uint32, Uint32, Pointer<Pointer<VkBuffer_T>>, Pointer<Uint64>);
typedef VkCmdBindVertexBuffersDart = void Function(Pointer<VkCommandBuffer_T>,
    int, int, Pointer<Pointer<VkBuffer_T>>, Pointer<Uint64>);

typedef VkCmdBindIndexBufferNative = Void Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkBuffer_T>, Uint64, Uint32);
typedef VkCmdBindIndexBufferDart = void Function(
    Pointer<VkCommandBuffer_T>, Pointer<VkBuffer_T>, int, int);

typedef VkCmdBindDescriptorSetsNative = Void Function(
    Pointer<VkCommandBuffer_T>,
    Uint32,
    Pointer<VkPipelineLayout_T>,
    Uint32,
    Uint32,
    Pointer<Pointer<VkDescriptorSet_T>>,
    Uint32,
    Pointer<Uint32>);
typedef VkCmdBindDescriptorSetsDart = void Function(
    Pointer<VkCommandBuffer_T>,
    int,
    Pointer<VkPipelineLayout_T>,
    int,
    int,
    Pointer<Pointer<VkDescriptorSet_T>>,
    int,
    Pointer<Uint32>);

typedef VkCmdSetViewportNative = Void Function(
    Pointer<VkCommandBuffer_T>, Uint32, Uint32, Pointer<VkViewport>);
typedef VkCmdSetViewportDart = void Function(
    Pointer<VkCommandBuffer_T>, int, int, Pointer<VkViewport>);

typedef VkCmdSetScissorNative = Void Function(
    Pointer<VkCommandBuffer_T>, Uint32, Uint32, Pointer<VkRect2D>);
typedef VkCmdSetScissorDart = void Function(
    Pointer<VkCommandBuffer_T>, int, int, Pointer<VkRect2D>);

typedef VkCmdDrawNative = Void Function(
    Pointer<VkCommandBuffer_T>, Uint32, Uint32, Uint32, Uint32);
typedef VkCmdDrawDart = void Function(
    Pointer<VkCommandBuffer_T>, int, int, int, int);

typedef VkCmdDrawIndexedNative = Void Function(
    Pointer<VkCommandBuffer_T>, Uint32, Uint32, Uint32, Int32, Uint32);
typedef VkCmdDrawIndexedDart = void Function(
    Pointer<VkCommandBuffer_T>, int, int, int, int, int);

typedef VkCmdPushConstantsNative = Void Function(Pointer<VkCommandBuffer_T>,
    Pointer<VkPipelineLayout_T>, Uint32, Uint32, Uint32, Pointer<Void>);
typedef VkCmdPushConstantsDart = void Function(Pointer<VkCommandBuffer_T>,
    Pointer<VkPipelineLayout_T>, int, int, int, Pointer<Void>);

typedef VkCmdCopyBufferNative = Void Function(Pointer<VkCommandBuffer_T>,
    Pointer<VkBuffer_T>, Pointer<VkBuffer_T>, Uint32, Pointer<VkBufferCopy>);
typedef VkCmdCopyBufferDart = void Function(Pointer<VkCommandBuffer_T>,
    Pointer<VkBuffer_T>, Pointer<VkBuffer_T>, int, Pointer<VkBufferCopy>);

typedef VkCmdCopyBufferToImageNative = Void Function(
    Pointer<VkCommandBuffer_T>,
    Pointer<VkBuffer_T>,
    Pointer<VkImage_T>,
    Uint32,
    Uint32,
    Pointer<VkBufferImageCopy>);
typedef VkCmdCopyBufferToImageDart = void Function(
    Pointer<VkCommandBuffer_T>,
    Pointer<VkBuffer_T>,
    Pointer<VkImage_T>,
    int,
    int,
    Pointer<VkBufferImageCopy>);

typedef VkCmdCopyImageToBufferNative = Void Function(
    Pointer<VkCommandBuffer_T>,
    Pointer<VkImage_T>,
    Uint32,
    Pointer<VkBuffer_T>,
    Uint32,
    Pointer<VkBufferImageCopy>);
typedef VkCmdCopyImageToBufferDart = void Function(
    Pointer<VkCommandBuffer_T>,
    Pointer<VkImage_T>,
    int,
    Pointer<VkBuffer_T>,
    int,
    Pointer<VkBufferImageCopy>);

/// The commands that take a `VkDevice`, `VkQueue` or `VkCommandBuffer`.
///
/// Every field is non-null: unlike the instance table there is nothing
/// optional in it, and a driver missing one of these cannot render at all, so
/// [bind] throws a named [VulkanSymbolError] rather than handing back a table
/// with a hole in it.
final class VulkanDeviceApi {
  VulkanDeviceApi._(this._lookup);

  /// Every device-level command this table resolves.
  ///
  /// Kept in step with [_resolveAll] by `vulkan_symbol_test.dart`, which
  /// resolves each name against a real device *and* asserts that the count
  /// matches - a list that fell behind would let a missing symbol through the
  /// symbol test while still failing at device creation.
  static const List<String> requiredSymbols = <String>[
    'vkDestroyDevice',
    'vkGetDeviceQueue',
    'vkDeviceWaitIdle',
    'vkQueueWaitIdle',
    'vkQueueSubmit',
    'vkCreateCommandPool',
    'vkDestroyCommandPool',
    'vkResetCommandPool',
    'vkAllocateCommandBuffers',
    'vkFreeCommandBuffers',
    'vkBeginCommandBuffer',
    'vkEndCommandBuffer',
    'vkCreateFence',
    'vkDestroyFence',
    'vkWaitForFences',
    'vkResetFences',
    'vkGetFenceStatus',
    'vkCreateSemaphore',
    'vkDestroySemaphore',
    'vkCreateEvent',
    'vkDestroyEvent',
    'vkSetEvent',
    'vkResetEvent',
    'vkGetEventStatus',
    'vkCmdWaitEvents',
    'vkAllocateMemory',
    'vkFreeMemory',
    'vkMapMemory',
    'vkUnmapMemory',
    'vkFlushMappedMemoryRanges',
    'vkInvalidateMappedMemoryRanges',
    'vkCreateBuffer',
    'vkDestroyBuffer',
    'vkGetBufferMemoryRequirements',
    'vkBindBufferMemory',
    'vkCreateImage',
    'vkDestroyImage',
    'vkGetImageMemoryRequirements',
    'vkBindImageMemory',
    'vkCreateImageView',
    'vkDestroyImageView',
    'vkCreateSampler',
    'vkDestroySampler',
    'vkCreateRenderPass',
    'vkDestroyRenderPass',
    'vkCreateFramebuffer',
    'vkDestroyFramebuffer',
    'vkCreateShaderModule',
    'vkDestroyShaderModule',
    'vkCreatePipelineLayout',
    'vkDestroyPipelineLayout',
    'vkCreateGraphicsPipelines',
    'vkDestroyPipeline',
    'vkCreateDescriptorSetLayout',
    'vkDestroyDescriptorSetLayout',
    'vkCreateDescriptorPool',
    'vkDestroyDescriptorPool',
    'vkResetDescriptorPool',
    'vkAllocateDescriptorSets',
    'vkUpdateDescriptorSets',
    'vkCmdPipelineBarrier',
    'vkCmdBeginRenderPass',
    'vkCmdEndRenderPass',
    'vkCmdBindPipeline',
    'vkCmdBindVertexBuffers',
    'vkCmdBindIndexBuffer',
    'vkCmdBindDescriptorSets',
    'vkCmdSetViewport',
    'vkCmdSetScissor',
    'vkCmdDraw',
    'vkCmdDrawIndexed',
    'vkCmdPushConstants',
    'vkCmdCopyBuffer',
    'vkCmdCopyBufferToImage',
    'vkCmdCopyImageToBuffer',
  ];

  final Pointer<Void> Function(String) _lookup;

  /// How many symbols [_resolveAll] actually asked for. Compared against
  /// [requiredSymbols] by the symbol test.
  int get resolvedCount => _resolved;
  int _resolved = 0;

  /// The address of [symbol], typed but not yet callable.
  ///
  /// A pointer and not a Dart function because `Pointer.asFunction` refuses a
  /// type argument that is a type parameter: the native signature has to be a
  /// compile-time constant at the call site. So the lookup, the null check and
  /// the counter are shared here, and `.asFunction<...>()` is spelled once per
  /// command in [_resolveAll], next to the native type it belongs to.
  Pointer<NativeFunction<T>> _proc<T extends Function>(String symbol) {
    final Pointer<Void> address = _lookup(symbol);
    if (address == nullptr) throw VulkanSymbolError(symbol, 'device');
    _resolved++;
    return address.cast<NativeFunction<T>>();
  }

  /// Resolves every command, throwing on the first that is missing.
  static VulkanDeviceApi bind(
    VulkanInstanceApi instance,
    Pointer<VkDevice_T> device,
  ) {
    final VulkanDeviceApi api = VulkanDeviceApi._((String symbol) => using(
        (NativeArena arena) => instance.getDeviceProcAddr(
            device, arena.allocateAscii(symbol).cast<Char>())));
    api._resolveAll();
    return api;
  }

  late final VkDestroyDeviceDart destroyDevice;
  late final VkGetDeviceQueueDart getDeviceQueue;
  late final VkDeviceWaitIdleDart deviceWaitIdle;
  late final VkQueueWaitIdleDart queueWaitIdle;
  late final VkQueueSubmitDart queueSubmit;

  late final VkCreateDart<VkCommandPoolCreateInfo, VkCommandPool_T>
      createCommandPool;
  late final VkDestroyDart<VkCommandPool_T> destroyCommandPool;
  late final VkResetCommandPoolDart resetCommandPool;
  late final VkAllocateCommandBuffersDart allocateCommandBuffers;
  late final VkFreeCommandBuffersDart freeCommandBuffers;
  late final VkBeginCommandBufferDart beginCommandBuffer;
  late final VkEndCommandBufferDart endCommandBuffer;

  late final VkCreateDart<VkFenceCreateInfo, VkFence_T> createFence;
  late final VkDestroyDart<VkFence_T> destroyFence;
  late final VkWaitForFencesDart waitForFences;
  late final VkResetFencesDart resetFences;
  late final VkGetFenceStatusDart getFenceStatus;
  late final VkCreateDart<VkSemaphoreCreateInfo, VkSemaphore_T> createSemaphore;
  late final VkDestroyDart<VkSemaphore_T> destroySemaphore;

  late final VkCreateDart<VkEventCreateInfo, VkEvent_T> createEvent;
  late final VkDestroyDart<VkEvent_T> destroyEvent;
  late final VkEventCommandDart setEvent;
  late final VkEventCommandDart resetEvent;
  late final VkEventCommandDart getEventStatus;
  late final VkCmdWaitEventsDart cmdWaitEvents;

  late final VkCreateDart<VkMemoryAllocateInfo, VkDeviceMemory_T>
      allocateMemory;
  late final VkDestroyDart<VkDeviceMemory_T> freeMemory;
  late final VkMapMemoryDart mapMemory;
  late final VkUnmapMemoryDart unmapMemory;
  late final VkMappedRangesDart flushMappedMemoryRanges;
  late final VkMappedRangesDart invalidateMappedMemoryRanges;

  late final VkCreateDart<VkBufferCreateInfo, VkBuffer_T> createBuffer;
  late final VkDestroyDart<VkBuffer_T> destroyBuffer;
  late final VkRequirementsDart<VkBuffer_T> getBufferMemoryRequirements;
  late final VkBindMemoryDart<VkBuffer_T> bindBufferMemory;

  late final VkCreateDart<VkImageCreateInfo, VkImage_T> createImage;
  late final VkDestroyDart<VkImage_T> destroyImage;
  late final VkRequirementsDart<VkImage_T> getImageMemoryRequirements;
  late final VkBindMemoryDart<VkImage_T> bindImageMemory;

  late final VkCreateDart<VkImageViewCreateInfo, VkImageView_T> createImageView;
  late final VkDestroyDart<VkImageView_T> destroyImageView;
  late final VkCreateDart<VkSamplerCreateInfo, VkSampler_T> createSampler;
  late final VkDestroyDart<VkSampler_T> destroySampler;

  late final VkCreateDart<VkRenderPassCreateInfo, VkRenderPass_T>
      createRenderPass;
  late final VkDestroyDart<VkRenderPass_T> destroyRenderPass;
  late final VkCreateDart<VkFramebufferCreateInfo, VkFramebuffer_T>
      createFramebuffer;
  late final VkDestroyDart<VkFramebuffer_T> destroyFramebuffer;

  late final VkCreateDart<VkShaderModuleCreateInfo, VkShaderModule_T>
      createShaderModule;
  late final VkDestroyDart<VkShaderModule_T> destroyShaderModule;
  late final VkCreateDart<VkPipelineLayoutCreateInfo, VkPipelineLayout_T>
      createPipelineLayout;
  late final VkDestroyDart<VkPipelineLayout_T> destroyPipelineLayout;
  late final VkCreateGraphicsPipelinesDart createGraphicsPipelines;
  late final VkDestroyDart<VkPipeline_T> destroyPipeline;

  late final VkCreateDart<VkDescriptorSetLayoutCreateInfo,
      VkDescriptorSetLayout_T> createDescriptorSetLayout;
  late final VkDestroyDart<VkDescriptorSetLayout_T> destroyDescriptorSetLayout;
  late final VkCreateDart<VkDescriptorPoolCreateInfo, VkDescriptorPool_T>
      createDescriptorPool;
  late final VkDestroyDart<VkDescriptorPool_T> destroyDescriptorPool;
  late final VkResetDescriptorPoolDart resetDescriptorPool;
  late final VkAllocateDescriptorSetsDart allocateDescriptorSets;
  late final VkUpdateDescriptorSetsDart updateDescriptorSets;

  late final VkCmdPipelineBarrierDart cmdPipelineBarrier;
  late final VkCmdBeginRenderPassDart cmdBeginRenderPass;
  late final VkCmdEndRenderPassDart cmdEndRenderPass;
  late final VkCmdBindPipelineDart cmdBindPipeline;
  late final VkCmdBindVertexBuffersDart cmdBindVertexBuffers;
  late final VkCmdBindIndexBufferDart cmdBindIndexBuffer;
  late final VkCmdBindDescriptorSetsDart cmdBindDescriptorSets;
  late final VkCmdSetViewportDart cmdSetViewport;
  late final VkCmdSetScissorDart cmdSetScissor;

  /// `vkCmdDraw`. Non-indexed, and the only draw the sparse-strip pipeline
  /// uses: its quad is four vertices built from `gl_VertexIndex`, so there is
  /// no index buffer to bind and `firstInstance` is what selects the command's
  /// slice of the instance array.
  late final VkCmdDrawDart cmdDraw;
  late final VkCmdDrawIndexedDart cmdDrawIndexed;
  late final VkCmdPushConstantsDart cmdPushConstants;
  late final VkCmdCopyBufferDart cmdCopyBuffer;
  late final VkCmdCopyBufferToImageDart cmdCopyBufferToImage;
  late final VkCmdCopyImageToBufferDart cmdCopyImageToBuffer;

  /// Forces every `late final` above to resolve now.
  ///
  /// Eager on purpose. A table whose fields resolve on first use turns "this
  /// driver does not export `vkCmdCopyImageToBuffer`" into a crash in the
  /// middle of a frame, three seconds after the device reported itself
  /// healthy; resolving here turns it into a refusal at device creation, which
  /// is the only place the caller can still choose another backend.
  void _resolveAll() {
    destroyDevice = _proc<VkDestroyDeviceNative>('vkDestroyDevice')
        .asFunction<VkDestroyDeviceDart>();
    getDeviceQueue = _proc<VkGetDeviceQueueNative>('vkGetDeviceQueue')
        .asFunction<VkGetDeviceQueueDart>();
    deviceWaitIdle = _proc<VkDeviceWaitIdleNative>('vkDeviceWaitIdle')
        .asFunction<VkDeviceWaitIdleDart>();
    queueWaitIdle = _proc<VkQueueWaitIdleNative>('vkQueueWaitIdle')
        .asFunction<VkQueueWaitIdleDart>();
    queueSubmit = _proc<VkQueueSubmitNative>('vkQueueSubmit')
        .asFunction<VkQueueSubmitDart>();

    createCommandPool = _proc<
                VkCreateNative<VkCommandPoolCreateInfo, VkCommandPool_T>>(
            'vkCreateCommandPool')
        .asFunction<VkCreateDart<VkCommandPoolCreateInfo, VkCommandPool_T>>();
    destroyCommandPool =
        _proc<VkDestroyNative<VkCommandPool_T>>('vkDestroyCommandPool')
            .asFunction<VkDestroyDart<VkCommandPool_T>>();
    resetCommandPool = _proc<VkResetCommandPoolNative>('vkResetCommandPool')
        .asFunction<VkResetCommandPoolDart>();
    allocateCommandBuffers =
        _proc<VkAllocateCommandBuffersNative>('vkAllocateCommandBuffers')
            .asFunction<VkAllocateCommandBuffersDart>();
    freeCommandBuffers =
        _proc<VkFreeCommandBuffersNative>('vkFreeCommandBuffers')
            .asFunction<VkFreeCommandBuffersDart>();
    beginCommandBuffer =
        _proc<VkBeginCommandBufferNative>('vkBeginCommandBuffer')
            .asFunction<VkBeginCommandBufferDart>();
    endCommandBuffer = _proc<VkEndCommandBufferNative>('vkEndCommandBuffer')
        .asFunction<VkEndCommandBufferDart>();

    createFence =
        _proc<VkCreateNative<VkFenceCreateInfo, VkFence_T>>('vkCreateFence')
            .asFunction<VkCreateDart<VkFenceCreateInfo, VkFence_T>>();
    destroyFence = _proc<VkDestroyNative<VkFence_T>>('vkDestroyFence')
        .asFunction<VkDestroyDart<VkFence_T>>();
    waitForFences = _proc<VkWaitForFencesNative>('vkWaitForFences')
        .asFunction<VkWaitForFencesDart>();
    resetFences = _proc<VkResetFencesNative>('vkResetFences')
        .asFunction<VkResetFencesDart>();
    getFenceStatus = _proc<VkGetFenceStatusNative>('vkGetFenceStatus')
        .asFunction<VkGetFenceStatusDart>();
    createSemaphore =
        _proc<VkCreateNative<VkSemaphoreCreateInfo, VkSemaphore_T>>(
                'vkCreateSemaphore')
            .asFunction<VkCreateDart<VkSemaphoreCreateInfo, VkSemaphore_T>>();
    destroySemaphore =
        _proc<VkDestroyNative<VkSemaphore_T>>('vkDestroySemaphore')
            .asFunction<VkDestroyDart<VkSemaphore_T>>();

    createEvent =
        _proc<VkCreateNative<VkEventCreateInfo, VkEvent_T>>('vkCreateEvent')
            .asFunction<VkCreateDart<VkEventCreateInfo, VkEvent_T>>();
    destroyEvent = _proc<VkDestroyNative<VkEvent_T>>('vkDestroyEvent')
        .asFunction<VkDestroyDart<VkEvent_T>>();
    setEvent = _proc<VkEventCommandNative>('vkSetEvent')
        .asFunction<VkEventCommandDart>();
    resetEvent = _proc<VkEventCommandNative>('vkResetEvent')
        .asFunction<VkEventCommandDart>();
    getEventStatus = _proc<VkEventCommandNative>('vkGetEventStatus')
        .asFunction<VkEventCommandDart>();
    cmdWaitEvents = _proc<VkCmdWaitEventsNative>('vkCmdWaitEvents')
        .asFunction<VkCmdWaitEventsDart>();

    allocateMemory =
        _proc<VkCreateNative<VkMemoryAllocateInfo, VkDeviceMemory_T>>(
                'vkAllocateMemory')
            .asFunction<VkCreateDart<VkMemoryAllocateInfo, VkDeviceMemory_T>>();
    freeMemory = _proc<VkDestroyNative<VkDeviceMemory_T>>('vkFreeMemory')
        .asFunction<VkDestroyDart<VkDeviceMemory_T>>();
    mapMemory =
        _proc<VkMapMemoryNative>('vkMapMemory').asFunction<VkMapMemoryDart>();
    unmapMemory = _proc<VkUnmapMemoryNative>('vkUnmapMemory')
        .asFunction<VkUnmapMemoryDart>();
    flushMappedMemoryRanges =
        _proc<VkMappedRangesNative>('vkFlushMappedMemoryRanges')
            .asFunction<VkMappedRangesDart>();
    invalidateMappedMemoryRanges =
        _proc<VkMappedRangesNative>('vkInvalidateMappedMemoryRanges')
            .asFunction<VkMappedRangesDart>();

    createBuffer =
        _proc<VkCreateNative<VkBufferCreateInfo, VkBuffer_T>>('vkCreateBuffer')
            .asFunction<VkCreateDart<VkBufferCreateInfo, VkBuffer_T>>();
    destroyBuffer = _proc<VkDestroyNative<VkBuffer_T>>('vkDestroyBuffer')
        .asFunction<VkDestroyDart<VkBuffer_T>>();
    getBufferMemoryRequirements =
        _proc<VkRequirementsNative<VkBuffer_T>>('vkGetBufferMemoryRequirements')
            .asFunction<VkRequirementsDart<VkBuffer_T>>();
    bindBufferMemory =
        _proc<VkBindMemoryNative<VkBuffer_T>>('vkBindBufferMemory')
            .asFunction<VkBindMemoryDart<VkBuffer_T>>();

    createImage =
        _proc<VkCreateNative<VkImageCreateInfo, VkImage_T>>('vkCreateImage')
            .asFunction<VkCreateDart<VkImageCreateInfo, VkImage_T>>();
    destroyImage = _proc<VkDestroyNative<VkImage_T>>('vkDestroyImage')
        .asFunction<VkDestroyDart<VkImage_T>>();
    getImageMemoryRequirements =
        _proc<VkRequirementsNative<VkImage_T>>('vkGetImageMemoryRequirements')
            .asFunction<VkRequirementsDart<VkImage_T>>();
    bindImageMemory = _proc<VkBindMemoryNative<VkImage_T>>('vkBindImageMemory')
        .asFunction<VkBindMemoryDart<VkImage_T>>();

    createImageView =
        _proc<VkCreateNative<VkImageViewCreateInfo, VkImageView_T>>(
                'vkCreateImageView')
            .asFunction<VkCreateDart<VkImageViewCreateInfo, VkImageView_T>>();
    destroyImageView =
        _proc<VkDestroyNative<VkImageView_T>>('vkDestroyImageView')
            .asFunction<VkDestroyDart<VkImageView_T>>();
    createSampler = _proc<VkCreateNative<VkSamplerCreateInfo, VkSampler_T>>(
            'vkCreateSampler')
        .asFunction<VkCreateDart<VkSamplerCreateInfo, VkSampler_T>>();
    destroySampler = _proc<VkDestroyNative<VkSampler_T>>('vkDestroySampler')
        .asFunction<VkDestroyDart<VkSampler_T>>();

    createRenderPass =
        _proc<VkCreateNative<VkRenderPassCreateInfo, VkRenderPass_T>>(
                'vkCreateRenderPass')
            .asFunction<VkCreateDart<VkRenderPassCreateInfo, VkRenderPass_T>>();
    destroyRenderPass =
        _proc<VkDestroyNative<VkRenderPass_T>>('vkDestroyRenderPass')
            .asFunction<VkDestroyDart<VkRenderPass_T>>();
    createFramebuffer = _proc<
                VkCreateNative<VkFramebufferCreateInfo, VkFramebuffer_T>>(
            'vkCreateFramebuffer')
        .asFunction<VkCreateDart<VkFramebufferCreateInfo, VkFramebuffer_T>>();
    destroyFramebuffer =
        _proc<VkDestroyNative<VkFramebuffer_T>>('vkDestroyFramebuffer')
            .asFunction<VkDestroyDart<VkFramebuffer_T>>();

    createShaderModule = _proc<
                VkCreateNative<VkShaderModuleCreateInfo, VkShaderModule_T>>(
            'vkCreateShaderModule')
        .asFunction<VkCreateDart<VkShaderModuleCreateInfo, VkShaderModule_T>>();
    destroyShaderModule =
        _proc<VkDestroyNative<VkShaderModule_T>>('vkDestroyShaderModule')
            .asFunction<VkDestroyDart<VkShaderModule_T>>();
    createPipelineLayout =
        _proc<VkCreateNative<VkPipelineLayoutCreateInfo, VkPipelineLayout_T>>(
                'vkCreatePipelineLayout')
            .asFunction<
                VkCreateDart<VkPipelineLayoutCreateInfo, VkPipelineLayout_T>>();
    destroyPipelineLayout =
        _proc<VkDestroyNative<VkPipelineLayout_T>>('vkDestroyPipelineLayout')
            .asFunction<VkDestroyDart<VkPipelineLayout_T>>();
    createGraphicsPipelines =
        _proc<VkCreateGraphicsPipelinesNative>('vkCreateGraphicsPipelines')
            .asFunction<VkCreateGraphicsPipelinesDart>();
    destroyPipeline = _proc<VkDestroyNative<VkPipeline_T>>('vkDestroyPipeline')
        .asFunction<VkDestroyDart<VkPipeline_T>>();

    createDescriptorSetLayout = _proc<
            VkCreateNative<VkDescriptorSetLayoutCreateInfo,
                VkDescriptorSetLayout_T>>('vkCreateDescriptorSetLayout')
        .asFunction<
            VkCreateDart<VkDescriptorSetLayoutCreateInfo,
                VkDescriptorSetLayout_T>>();
    destroyDescriptorSetLayout =
        _proc<VkDestroyNative<VkDescriptorSetLayout_T>>(
                'vkDestroyDescriptorSetLayout')
            .asFunction<VkDestroyDart<VkDescriptorSetLayout_T>>();
    createDescriptorPool =
        _proc<VkCreateNative<VkDescriptorPoolCreateInfo, VkDescriptorPool_T>>(
                'vkCreateDescriptorPool')
            .asFunction<
                VkCreateDart<VkDescriptorPoolCreateInfo, VkDescriptorPool_T>>();
    destroyDescriptorPool =
        _proc<VkDestroyNative<VkDescriptorPool_T>>('vkDestroyDescriptorPool')
            .asFunction<VkDestroyDart<VkDescriptorPool_T>>();
    resetDescriptorPool =
        _proc<VkResetDescriptorPoolNative>('vkResetDescriptorPool')
            .asFunction<VkResetDescriptorPoolDart>();
    allocateDescriptorSets =
        _proc<VkAllocateDescriptorSetsNative>('vkAllocateDescriptorSets')
            .asFunction<VkAllocateDescriptorSetsDart>();
    updateDescriptorSets =
        _proc<VkUpdateDescriptorSetsNative>('vkUpdateDescriptorSets')
            .asFunction<VkUpdateDescriptorSetsDart>();

    cmdPipelineBarrier =
        _proc<VkCmdPipelineBarrierNative>('vkCmdPipelineBarrier')
            .asFunction<VkCmdPipelineBarrierDart>();
    cmdBeginRenderPass =
        _proc<VkCmdBeginRenderPassNative>('vkCmdBeginRenderPass')
            .asFunction<VkCmdBeginRenderPassDart>();
    cmdEndRenderPass = _proc<VkCmdEndRenderPassNative>('vkCmdEndRenderPass')
        .asFunction<VkCmdEndRenderPassDart>();
    cmdBindPipeline = _proc<VkCmdBindPipelineNative>('vkCmdBindPipeline')
        .asFunction<VkCmdBindPipelineDart>();
    cmdBindVertexBuffers =
        _proc<VkCmdBindVertexBuffersNative>('vkCmdBindVertexBuffers')
            .asFunction<VkCmdBindVertexBuffersDart>();
    cmdBindIndexBuffer =
        _proc<VkCmdBindIndexBufferNative>('vkCmdBindIndexBuffer')
            .asFunction<VkCmdBindIndexBufferDart>();
    cmdBindDescriptorSets =
        _proc<VkCmdBindDescriptorSetsNative>('vkCmdBindDescriptorSets')
            .asFunction<VkCmdBindDescriptorSetsDart>();
    cmdSetViewport = _proc<VkCmdSetViewportNative>('vkCmdSetViewport')
        .asFunction<VkCmdSetViewportDart>();
    cmdSetScissor = _proc<VkCmdSetScissorNative>('vkCmdSetScissor')
        .asFunction<VkCmdSetScissorDart>();
    cmdDraw = _proc<VkCmdDrawNative>('vkCmdDraw').asFunction<VkCmdDrawDart>();
    cmdDrawIndexed = _proc<VkCmdDrawIndexedNative>('vkCmdDrawIndexed')
        .asFunction<VkCmdDrawIndexedDart>();
    cmdPushConstants = _proc<VkCmdPushConstantsNative>('vkCmdPushConstants')
        .asFunction<VkCmdPushConstantsDart>();
    cmdCopyBuffer = _proc<VkCmdCopyBufferNative>('vkCmdCopyBuffer')
        .asFunction<VkCmdCopyBufferDart>();
    cmdCopyBufferToImage =
        _proc<VkCmdCopyBufferToImageNative>('vkCmdCopyBufferToImage')
            .asFunction<VkCmdCopyBufferToImageDart>();
    cmdCopyImageToBuffer =
        _proc<VkCmdCopyImageToBufferNative>('vkCmdCopyImageToBuffer')
            .asFunction<VkCmdCopyImageToBufferDart>();
  }
}
