import 'dart:io';

import 'package:poc_09_wayland/wayland_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('libwayland-client exports the runtime primitives required by the POC',
      () {
    if (!Platform.isLinux) {
      print('Skipping binding test on non-Linux platform.');
      return;
    }

    // The POC reuses the exported runtime primitives and reimplements the
    // scanner-generated inline functions in Dart, so we only need to verify
    // that the primitives + the `wl_interface` struct pointers actually
    // resolve. The inline-generated protocol functions (e.g.
    // `wl_display_get_registry`) are NOT exported by the shared library and
    // are intentionally not looked up.
    expect(() => wl_display_connect, returnsNormally,
        reason: 'wl_display_connect must resolve');
    expect(() => wl_display_disconnect, returnsNormally,
        reason: 'wl_display_disconnect must resolve');
    expect(() => wl_display_roundtrip, returnsNormally,
        reason: 'wl_display_roundtrip must resolve');
    expect(() => wl_display_dispatch, returnsNormally,
        reason: 'wl_display_dispatch must resolve');
    expect(() => wl_registry_add_listener, returnsNormally,
        reason: 'wl_registry_add_listener must resolve');
    expect(() => wl_registry_bind, returnsNormally,
        reason: 'wl_registry_bind must resolve');
    expect(() => wl_proxy_destroy, returnsNormally,
        reason: 'wl_proxy_destroy must resolve');
    expect(() => wl_proxy_marshal_0, returnsNormally,
        reason: 'wl_proxy_marshal (0 args) must resolve');
    expect(() => wl_proxy_marshal_3, returnsNormally,
        reason: 'wl_proxy_marshal (3 args) must resolve');
    expect(() => wl_proxy_marshal_5, returnsNormally,
        reason: 'wl_proxy_marshal (5 args) must resolve');
    expect(() => wl_proxy_marshal_constructor_iface0, returnsNormally,
        reason:
            'wl_proxy_marshal_constructor (interface, 0 args) must resolve');
    expect(() => wl_proxy_marshal_constructor_iface2_int, returnsNormally,
        reason:
            'wl_proxy_marshal_constructor (interface, 2 ints) must resolve');
    expect(() => wl_proxy_marshal_constructor_iface5_int, returnsNormally,
        reason:
            'wl_proxy_marshal_constructor (interface, 5 ints) must resolve');

    // Opaque `wl_interface` struct pointers must be exported too.
    expect(wl_registry_interface_ptr.address, isNot(0),
        reason: 'wl_registry_interface must be exported');
    expect(wl_compositor_interface_ptr.address, isNot(0),
        reason: 'wl_compositor_interface must be exported');
    expect(wl_shm_interface_ptr.address, isNot(0),
        reason: 'wl_shm_interface must be exported');
    expect(wl_shm_pool_interface_ptr.address, isNot(0),
        reason: 'wl_shm_pool_interface must be exported');
    expect(wl_surface_interface_ptr.address, isNot(0),
        reason: 'wl_surface_interface must be exported');
    expect(wl_buffer_interface_ptr.address, isNot(0),
        reason: 'wl_buffer_interface must be exported');
  }, skip: !Platform.isLinux ? 'Wayland is Linux-only' : false);

  test('libc exports the system-call symbols required for the SHM pool', () {
    if (!Platform.isLinux) {
      print('Skipping libc test on non-Linux platform.');
      return;
    }

    expect(() => memfd_create, returnsNormally,
        reason: 'memfd_create must resolve');
    expect(() => ftruncate, returnsNormally, reason: 'ftruncate must resolve');
    expect(() => mmap, returnsNormally, reason: 'mmap must resolve');
    expect(() => munmap, returnsNormally, reason: 'munmap must resolve');
    expect(() => close_fd, returnsNormally, reason: 'close must resolve');
  }, skip: !Platform.isLinux ? 'libc is Linux-only' : false);
}
