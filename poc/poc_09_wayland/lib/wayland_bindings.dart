// libwayland-client.so.0 + libc bindings for POC-09.
//
// We declare only the symbols exercised by the smoke flow:
//   - wl_display_connect / disconnect / get_registry / roundtrip / dispatch
//   - wl_registry_add_listener / bind / destroy
//   - wl_compositor_create_surface / destroy
//   - wl_shm_create_pool / destroy
//   - wl_shm_pool_create_buffer / destroy
//   - wl_surface_attach / damage / commit / destroy
//   - wl_buffer_destroy
//   - libc: memfd_create, ftruncate, mmap, munmap, close
//
// Interface struct pointers (`wl_compositor_interface`, `wl_shm_interface`)
// are obtained as opaque `Pointer<Void>` because we do not call into their
// fields from Dart — they are passed unchanged to `wl_registry_bind` which
// is the only consumer.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// --- libwayland-client -----------------------------------------------------

final DynamicLibrary libWayland = DynamicLibrary.open('libwayland-client.so.0');

// wl_display_connect(const char *name)
typedef WlDisplayConnectNative = Pointer<Void> Function(Pointer<Utf8> name);
typedef WlDisplayConnectDart = Pointer<Void> Function(Pointer<Utf8> name);
final WlDisplayConnectDart wl_display_connect =
    libWayland.lookupFunction<WlDisplayConnectNative, WlDisplayConnectDart>(
        'wl_display_connect');

// wl_display_disconnect(struct wl_display *display)
typedef WlDisplayDisconnectNative = Void Function(Pointer<Void> display);
typedef WlDisplayDisconnectDart = void Function(Pointer<Void> display);
final WlDisplayDisconnectDart wl_display_disconnect =
    libWayland.lookupFunction<WlDisplayDisconnectNative, WlDisplayDisconnectDart>(
        'wl_display_disconnect');

// wl_display_get_registry(struct wl_display *display)
typedef WlDisplayGetRegistryNative = Pointer<Void> Function(Pointer<Void> display);
typedef WlDisplayGetRegistryDart = Pointer<Void> Function(Pointer<Void> display);
final WlDisplayGetRegistryDart wl_display_get_registry =
    libWayland.lookupFunction<WlDisplayGetRegistryNative, WlDisplayGetRegistryDart>(
        'wl_display_get_registry');

// int wl_display_roundtrip(struct wl_display *display)
typedef WlDisplayRoundtripNative = Int32 Function(Pointer<Void> display);
typedef WlDisplayRoundtripDart = int Function(Pointer<Void> display);
final WlDisplayRoundtripDart wl_display_roundtrip =
    libWayland.lookupFunction<WlDisplayRoundtripNative, WlDisplayRoundtripDart>(
        'wl_display_roundtrip');

// int wl_display_dispatch(struct wl_display *display)
typedef WlDisplayDispatchNative = Int32 Function(Pointer<Void> display);
typedef WlDisplayDispatchDart = int Function(Pointer<Void> display);
final WlDisplayDispatchDart wl_display_dispatch =
    libWayland.lookupFunction<WlDisplayDispatchNative, WlDisplayDispatchDart>(
        'wl_display_dispatch');

// struct wl_registry *wl_display_get_registry already declared above.
// void *wl_registry_bind(struct wl_registry *wl_registry, uint32_t name,
//                        const struct wl_interface *interface, uint32_t version);
typedef WlRegistryBindNative = Pointer<Void> Function(
    Pointer<Void> registry, Uint32 name, Pointer<Void> interface, Uint32 version);
typedef WlRegistryBindDart = Pointer<Void> Function(
    Pointer<Void> registry, int name, Pointer<Void> interface, int version);
final WlRegistryBindDart wl_registry_bind =
    libWayland.lookupFunction<WlRegistryBindNative, WlRegistryBindDart>(
        'wl_registry_bind');

// wl_registry_destroy(struct wl_registry *wl_registry)
typedef WlRegistryDestroyNative = Void Function(Pointer<Void> registry);
typedef WlRegistryDestroyDart = void Function(Pointer<Void> registry);
final WlRegistryDestroyDart wl_registry_destroy =
    libWayland.lookupFunction<WlRegistryDestroyNative, WlRegistryDestroyDart>(
        'wl_registry_destroy');

// int wl_registry_add_listener(struct wl_registry *wl_registry,
//                              const struct wl_registry_listener *listener,
//                              void *data);
typedef WlRegistryAddListenerNative = Int32 Function(
    Pointer<Void> registry, Pointer<Void> listener, Pointer<Void> data);
typedef WlRegistryAddListenerDart = int Function(
    Pointer<Void> registry, Pointer<Void> listener, Pointer<Void> data);
final WlRegistryAddListenerDart wl_registry_add_listener =
    libWayland.lookupFunction<WlRegistryAddListenerNative, WlRegistryAddListenerDart>(
        'wl_registry_add_listener');

// struct wl_surface *wl_compositor_create_surface(struct wl_compositor *compositor);
typedef WlCompositorCreateSurfaceNative = Pointer<Void> Function(
    Pointer<Void> compositor);
typedef WlCompositorCreateSurfaceDart = Pointer<Void> Function(
    Pointer<Void> compositor);
final WlCompositorCreateSurfaceDart wl_compositor_create_surface =
    libWayland.lookupFunction<WlCompositorCreateSurfaceNative,
        WlCompositorCreateSurfaceDart>('wl_compositor_create_surface');

// void wl_compositor_destroy(struct wl_compositor *wl_compositor);
typedef WlCompositorDestroyNative = Void Function(Pointer<Void> compositor);
typedef WlCompositorDestroyDart = void Function(Pointer<Void> compositor);
final WlCompositorDestroyDart wl_compositor_destroy =
    libWayland.lookupFunction<WlCompositorDestroyNative, WlCompositorDestroyDart>(
        'wl_compositor_destroy');

// struct wl_shm_pool *wl_shm_create_pool(struct wl_shm *wl_shm, int fd, int size);
typedef WlShmCreatePoolNative = Pointer<Void> Function(
    Pointer<Void> shm, Int32 fd, Int32 size);
typedef WlShmCreatePoolDart = Pointer<Void> Function(
    Pointer<Void> shm, int fd, int size);
final WlShmCreatePoolDart wl_shm_create_pool =
    libWayland.lookupFunction<WlShmCreatePoolNative, WlShmCreatePoolDart>(
        'wl_shm_create_pool');

// void wl_shm_destroy(struct wl_shm *wl_shm);
typedef WlShmDestroyNative = Void Function(Pointer<Void> shm);
typedef WlShmDestroyDart = void Function(Pointer<Void> shm);
final WlShmDestroyDart wl_shm_destroy =
    libWayland.lookupFunction<WlShmDestroyNative, WlShmDestroyDart>(
        'wl_shm_destroy');

// struct wl_buffer *wl_shm_pool_create_buffer(struct wl_shm_pool *pool,
//     int32_t offset, int32_t width, int32_t height, int32_t stride, uint32_t format);
typedef WlShmPoolCreateBufferNative = Pointer<Void> Function(
    Pointer<Void> pool, Int32 offset, Int32 width, Int32 height, Int32 stride, Uint32 format);
typedef WlShmPoolCreateBufferDart = Pointer<Void> Function(
    Pointer<Void> pool, int offset, int width, int height, int stride, int format);
final WlShmPoolCreateBufferDart wl_shm_pool_create_buffer =
    libWayland.lookupFunction<WlShmPoolCreateBufferNative,
        WlShmPoolCreateBufferDart>('wl_shm_pool_create_buffer');

// void wl_shm_pool_destroy(struct wl_shm_pool *wl_shm_pool);
typedef WlShmPoolDestroyNative = Void Function(Pointer<Void> pool);
typedef WlShmPoolDestroyDart = void Function(Pointer<Void> pool);
final WlShmPoolDestroyDart wl_shm_pool_destroy =
    libWayland.lookupFunction<WlShmPoolDestroyNative, WlShmPoolDestroyDart>(
        'wl_shm_pool_destroy');

// void wl_surface_attach(struct wl_surface *wl_surface, struct wl_buffer *buffer,
//                        int32_t x, int32_t y);
typedef WlSurfaceAttachNative = Void Function(
    Pointer<Void> surface, Pointer<Void> buffer, Int32 x, Int32 y);
typedef WlSurfaceAttachDart = void Function(
    Pointer<Void> surface, Pointer<Void> buffer, int x, int y);
final WlSurfaceAttachDart wl_surface_attach =
    libWayland.lookupFunction<WlSurfaceAttachNative, WlSurfaceAttachDart>(
        'wl_surface_attach');

// void wl_surface_damage(struct wl_surface *wl_surface, int32_t x, int32_t y,
//                        int32_t width, int32_t height);
typedef WlSurfaceDamageNative = Void Function(
    Pointer<Void> surface, Int32 x, Int32 y, Int32 width, Int32 height);
typedef WlSurfaceDamageDart = void Function(
    Pointer<Void> surface, int x, int y, int width, int height);
final WlSurfaceDamageDart wl_surface_damage =
    libWayland.lookupFunction<WlSurfaceDamageNative, WlSurfaceDamageDart>(
        'wl_surface_damage');

// void wl_surface_commit(struct wl_surface *wl_surface);
typedef WlSurfaceCommitNative = Void Function(Pointer<Void> surface);
typedef WlSurfaceCommitDart = void Function(Pointer<Void> surface);
final WlSurfaceCommitDart wl_surface_commit =
    libWayland.lookupFunction<WlSurfaceCommitNative, WlSurfaceCommitDart>(
        'wl_surface_commit');

// void wl_surface_destroy(struct wl_surface *wl_surface);
typedef WlSurfaceDestroyNative = Void Function(Pointer<Void> surface);
typedef WlSurfaceDestroyDart = void Function(Pointer<Void> surface);
final WlSurfaceDestroyDart wl_surface_destroy =
    libWayland.lookupFunction<WlSurfaceDestroyNative, WlSurfaceDestroyDart>(
        'wl_surface_destroy');

// void wl_buffer_destroy(struct wl_buffer *wl_buffer);
typedef WlBufferDestroyNative = Void Function(Pointer<Void> buffer);
typedef WlBufferDestroyDart = void Function(Pointer<Void> buffer);
final WlBufferDestroyDart wl_buffer_destroy =
    libWayland.lookupFunction<WlBufferDestroyNative, WlBufferDestroyDart>(
        'wl_buffer_destroy');

// Opaque `struct wl_interface` symbols exported from libwayland-client. We do
// not dereference them; they are passed straight into `wl_registry_bind`.
final Pointer<Void> wl_compositor_interface_ptr =
    libWayland.lookup<Void>('wl_compositor_interface');
final Pointer<Void> wl_shm_interface_ptr =
    libWayland.lookup<Void>('wl_shm_interface');

// --- Listener struct ------------------------------------------------------

// struct wl_registry_listener {
//     void (*global)(void *data, struct wl_registry *, uint32_t name,
//                    const char *interface, uint32_t version);
//     void (*global_remove)(void *data, struct wl_registry *, uint32_t name);
// };
typedef WlRegistryGlobalNative = Void Function(
    Pointer<Void> data,
    Pointer<Void> registry,
    Uint32 name,
    Pointer<Utf8> interface,
    Uint32 version);
typedef WlRegistryGlobalRemoveNative = Void Function(
    Pointer<Void> data,
    Pointer<Void> registry,
    Uint32 name);

final class WlRegistryListener extends Struct {
  external Pointer<NativeFunction<WlRegistryGlobalNative>> global;
  external Pointer<NativeFunction<WlRegistryGlobalRemoveNative>> global_remove;
}

// --- libc (Linux only) ------------------------------------------------------

final DynamicLibrary libc = DynamicLibrary.open('libc.so.6');

// int memfd_create(const char *name, unsigned int flags);
typedef MemfdCreateNative = Int32 Function(Pointer<Utf8> name, Uint32 flags);
typedef MemfdCreateDart = int Function(Pointer<Utf8> name, int flags);
final MemfdCreateDart memfd_create =
    libc.lookupFunction<MemfdCreateNative, MemfdCreateDart>('memfd_create');

// int ftruncate(int fd, off_t length);
typedef FtruncateNative = Int32 Function(Int32 fd, Long length);
typedef FtruncateDart = int Function(int fd, int length);
final FtruncateDart ftruncate =
    libc.lookupFunction<FtruncateNative, FtruncateDart>('ftruncate');

// void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
typedef MmapNative = Pointer<Void> Function(
    Pointer<Void> addr, IntPtr length, Int32 prot, Int32 flags, Int32 fd, Long offset);
typedef MmapDart = Pointer<Void> Function(
    Pointer<Void> addr, int length, int prot, int flags, int fd, int offset);
final MmapDart mmap =
    libc.lookupFunction<MmapNative, MmapDart>('mmap');

// int munmap(void *addr, size_t length);
typedef MunmapNative = Int32 Function(Pointer<Void> addr, IntPtr length);
typedef MunmapDart = int Function(Pointer<Void> addr, int length);
final MunmapDart munmap =
    libc.lookupFunction<MunmapNative, MunmapDart>('munmap');

// int close(int fd);
typedef CloseNative = Int32 Function(Int32 fd);
typedef CloseDart = int Function(int fd);
final CloseDart close_fd =
    libc.lookupFunction<CloseNative, CloseDart>('close');

// --- Constants -------------------------------------------------------------

// MFD_CLOEXEC = 1 (linux/memfd.h).
const int mfdCloexec = 1;

// PROT_* / MAP_* constants from <sys/mman.h>.
const int protRead = 1;
const int protWrite = 2;
const int mapShared = 1;

// Sentinel value used by mmap to indicate failure (`MAP_FAILED == (void*)-1`).
final Pointer<Void> mapFailed = Pointer.fromAddress(-1);

// Wayland wl_shm::format canonical values (see
// https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_shm-enum-format).
const int wlShmFormatArgb8888 = 0;
const int wlShmFormatXrgb8888 = 1;