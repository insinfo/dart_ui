import 'dart:io';

import 'package:poc_09_wayland/wayland_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('libwayland-client exports the symbols required by the POC', () {
    if (!Platform.isLinux) {
      print('Skipping binding test on non-Linux platform.');
      return;
    }

    // Touching each late final field forces the lookupFunction call to occur.
    // Missing symbols raise ArgumentError, which fails the test.
    expect(() => wl_display_connect, returnsNormally,
        reason: 'wl_display_connect must resolve');
    expect(() => wl_display_get_registry, returnsNormally,
        reason: 'wl_display_get_registry must resolve');
    expect(() => wl_display_roundtrip, returnsNormally,
        reason: 'wl_display_roundtrip must resolve');
    expect(() => wl_registry_add_listener, returnsNormally,
        reason: 'wl_registry_add_listener must resolve');
    expect(() => wl_registry_bind, returnsNormally,
        reason: 'wl_registry_bind must resolve');
    expect(() => wl_compositor_create_surface, returnsNormally,
        reason: 'wl_compositor_create_surface must resolve');
    expect(() => wl_shm_create_pool, returnsNormally,
        reason: 'wl_shm_create_pool must resolve');
    expect(() => wl_shm_pool_create_buffer, returnsNormally,
        reason: 'wl_shm_pool_create_buffer must resolve');
    expect(() => wl_surface_commit, returnsNormally,
        reason: 'wl_surface_commit must resolve');

    // The opaque `wl_interface` struct pointers must be exported too.
    expect(wl_compositor_interface_ptr.address, isNot(0),
        reason: 'wl_compositor_interface must be exported');
    expect(wl_shm_interface_ptr.address, isNot(0),
        reason: 'wl_shm_interface must be exported');
  }, skip: !Platform.isLinux ? 'Wayland is Linux-only' : false);

  test('libc exports the system-call symbols required for the SHM pool', () {
    if (!Platform.isLinux) {
      print('Skipping libc test on non-Linux platform.');
      return;
    }

    expect(() => memfd_create, returnsNormally,
        reason: 'memfd_create must resolve');
    expect(() => ftruncate, returnsNormally,
        reason: 'ftruncate must resolve');
    expect(() => mmap, returnsNormally, reason: 'mmap must resolve');
    expect(() => munmap, returnsNormally, reason: 'munmap must resolve');
    expect(() => close_fd, returnsNormally, reason: 'close must resolve');
  }, skip: !Platform.isLinux ? 'libc is Linux-only' : false);
}