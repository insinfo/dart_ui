/// The symbol test section 11.4 asks of every binding package.
///
/// Every Vulkan command this backend resolves is looked up here against a real
/// loader, at the dispatch level it is actually used from, and proved to
/// resolve. The failure this prevents is specific: `vkGetInstanceProcAddr` and
/// `vkGetDeviceProcAddr` answer a name they do not know with **null**, not
/// with an error. A binding that stores that null and calls it later crashes
/// in the middle of a frame, and the stack trace points at the call, not at
/// the typo three hundred lines away in the table.
///
/// The other half is the *level*. A device command resolved through
/// `vkGetInstanceProcAddr` comes back non-null - the loader has a trampoline
/// for it - so a table that asked the wrong function would pass a naive
/// existence check and still be wrong on a machine with two drivers. So each
/// list is checked through the entry point its own table uses.
library;

import 'dart:ffi';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_library.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

void main() {
  group('the symbol lists themselves', () {
    test('name every command, with no duplicates and no empty strings', () {
      // Checkable with no driver, and worth checking: a list with a duplicate
      // in it would make the counts below agree while a command was missing.
      for (final List<String> list in <List<String>>[
        VulkanLibrary.requiredSymbols,
        VulkanInstanceApi.requiredSymbols,
        VulkanInstanceApi.optionalSymbols,
        VulkanDeviceApi.requiredSymbols,
      ]) {
        expect(list, isNotEmpty);
        expect(list.toSet().length, list.length, reason: 'duplicate in $list');
        for (final String symbol in list) {
          expect(symbol, startsWith('vk'));
          expect(symbol.length, greaterThan(2));
        }
      }
      // The three levels must be disjoint. A command listed at two levels is
      // one resolved through the wrong entry point somewhere.
      final Set<String> global = VulkanLibrary.requiredSymbols.toSet();
      final Set<String> instance = VulkanInstanceApi.requiredSymbols.toSet();
      final Set<String> device = VulkanDeviceApi.requiredSymbols.toSet();
      expect(global.intersection(instance), isEmpty);
      expect(instance.intersection(device), isEmpty);
      expect(global.intersection(device), isEmpty);
    });

    test('VulkanSymbolError names the symbol and the level', () {
      // The refusal a missing symbol has to produce. Section 6.6: a failure
      // that does not say what was missing is a failure nobody can act on.
      final VulkanSymbolError error =
          VulkanSymbolError('vkCmdDrawIndexed', 'device');
      expect('$error', contains('vkCmdDrawIndexed'));
      expect('$error', contains('device'));
    });
  });

  group('against a real loader', () {
    final VulkanSession session = VulkanSession.open();
    tearDownAll(session.close);

    test('every global command resolves', () {
      final VulkanLibrary library = session.library!;
      for (final String symbol in VulkanLibrary.requiredSymbols) {
        if (symbol == 'vkGetInstanceProcAddr') {
          // The one that cannot be resolved through itself: it is the door.
          // That it worked is proved by the library having been built at all.
          continue;
        }
        expect(library.instanceProc(nullptr, symbol), isNot(nullptr),
            reason: 'global $symbol did not resolve through '
                'vkGetInstanceProcAddr(VK_NULL_HANDLE, ...)');
      }
    }, skip: session.skipReason);

    test('a command that does not exist resolves to null', () {
      // The non-vacuity check for every assertion in this file. If the loader
      // answered every name with a pointer, the tests above would prove
      // nothing at all.
      expect(
        session.library!.instanceProc(nullptr, 'vkThisCommandDoesNotExist'),
        nullptr,
      );
    }, skip: session.skipReason);

    test('every instance command resolves through vkGetInstanceProcAddr', () {
      final VulkanLibrary library = session.library!;
      final instance = session.instance!;
      for (final String symbol in VulkanInstanceApi.requiredSymbols) {
        expect(library.instanceProc(instance.handle, symbol), isNot(nullptr),
            reason: 'instance $symbol did not resolve');
      }
    }, skip: session.skipReason);

    test('every device command resolves through vkGetDeviceProcAddr', () {
      // Through `vkGetDeviceProcAddr` and not through the instance one. On a
      // machine with two ICDs - this development machine has the Intel driver
      // and Microsoft's Direct3D 12 emulation - the difference is which
      // driver's function you get.
      final instance = session.instance!;
      final device = session.device!;
      using((NativeArena arena) {
        for (final String symbol in VulkanDeviceApi.requiredSymbols) {
          final Pointer<Void> address = instance.api.getDeviceProcAddr(
              device.handle, arena.allocateAscii(symbol).cast<Char>());
          expect(address, isNot(nullptr),
              reason: 'device $symbol did not resolve through '
                  'vkGetDeviceProcAddr');
        }
      });
    }, skip: session.skipReason);

    test('the device table resolved exactly the commands it lists', () {
      // Ties the list to the code. `bind` counts every symbol it asked for; if
      // `_resolveAll` grew a command that the list did not, or the reverse,
      // the test above would be checking a list that no longer describes the
      // table.
      expect(session.device!.api.resolvedCount,
          VulkanDeviceApi.requiredSymbols.length);
    }, skip: session.skipReason);

    test('the optional debug-utils pair is present or absent together', () {
      // Half a pair is a messenger that can be created and never destroyed.
      final instance = session.instance!;
      expect(instance.api.createDebugUtilsMessenger == null,
          instance.api.destroyDebugUtilsMessenger == null);
    }, skip: session.skipReason);
  });
}
