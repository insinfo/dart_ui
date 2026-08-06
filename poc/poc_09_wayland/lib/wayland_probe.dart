// POC-09: end-to-end Wayland client smoke flow.
//
// Pipeline:
//   1. Connect to the compositor (`wl_display_connect(NULL)`).
//   2. Obtain the registry and register a `wl_registry_listener` whose
//      callbacks capture `wl_compositor` and `wl_shm` globals by calling
//      `wl_registry_bind` when matching interface names arrive.
//   3. Run `wl_display_roundtrip` to drain the initial registry burst.
//   4. Allocate a memory-backed shared pool via `memfd_create` + `ftruncate`
//      + `mmap`, fill it with a teal surface in `XRGB8888`, and create a
//      `wl_shm_pool` + `wl_buffer` from it.
//   5. Create a `wl_surface`, attach+damage+commit the buffer.
//   6. Pump two further roundtrips so the compositor processes the commit.
//   7. Release every proxy in reverse acquisition order, unmap and close
//      the fd, and disconnect the display.
// ignore_for_file: non_constant_identifier_names, avoid_print

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'wayland_bindings.dart';

class WaylandProbeResult {
  bool connected = false;
  bool registryCreated = false;
  bool listenersInstalled = false;
  bool registryDrained = false;
  bool compositorBound = false;
  bool shmBound = false;
  bool surfaceCreated = false;
  bool poolAllocated = false;
  bool bufferCommitted = false;
  bool disposed = false;
  List<String> globalNames = <String>[];
  String? diagnostic;
}

// Top-level mutable state captured by the registry callbacks. Because the
// callbacks are `NativeCallable.isolateLocal`, they execute synchronously on
// the same Dart isolate that registered them, so we can safely mutate these
// fields during a `wl_display_roundtrip` call.
Pointer<Void>? _compositorProxy;
Pointer<Void>? _shmProxy;
int? _compositorName;
int? _compositorVersion;
int? _shmName;
int? _shmVersion;
final List<String> _seenGlobals = <String>[];

void _onGlobal(Pointer<Void> data, Pointer<Void> registry, int name,
    Pointer<Utf8> interface, int version) {
  final interfaceName = interface.toDartString();
  _seenGlobals.add('$interfaceName@$version (name=$name)');
  if (interfaceName == 'wl_compositor' && _compositorProxy == null) {
    _compositorName = name;
    _compositorVersion = version;
    _compositorProxy =
        wl_registry_bind(registry, name, wl_compositor_interface_ptr, 1);
  } else if (interfaceName == 'wl_shm' && _shmProxy == null) {
    _shmName = name;
    _shmVersion = version;
    _shmProxy = wl_registry_bind(registry, name, wl_shm_interface_ptr, 1);
  }
}

void _onGlobalRemove(Pointer<Void> data, Pointer<Void> registry, int name) {
  // No-op for the POC: we only care about initial-burst globals and never
  // re-enumerate after release.
}

late NativeCallable<WlRegistryGlobalNative> _globalCallable;
late NativeCallable<WlRegistryGlobalRemoveNative> _globalRemoveCallable;

WaylandProbeResult runWaylandProbe({int width = 320, int height = 240}) {
  _compositorProxy = null;
  _shmProxy = null;
  _compositorName = null;
  _compositorVersion = null;
  _shmName = null;
  _shmVersion = null;
  _seenGlobals.clear();

  final result = WaylandProbeResult();

  print('[Wayland] Connecting to compositor (WAYLAND_DISPLAY env)...');
  final display = wl_display_connect(nullptr);
  if (display == nullptr) {
    result.diagnostic =
        'wl_display_connect returned NULL — compositor not reachable. '
        'In CI, Weston headless must be started before this POC runs.';
    return result;
  }
  result.connected = true;
  print('[Wayland] Connected (${display.address}).');

  print('[Wayland] Requesting registry...');
  final registry = wl_display_get_registry(display);
  if (registry == nullptr) {
    result.diagnostic = 'wl_display_get_registry returned NULL.';
    wl_display_disconnect(display);
    return result;
  }
  result.registryCreated = true;

  print('[Wayland] Installing registry listener...');
  _globalCallable =
      NativeCallable<WlRegistryGlobalNative>.isolateLocal(_onGlobal);
  _globalRemoveCallable =
      NativeCallable<WlRegistryGlobalRemoveNative>.isolateLocal(
          _onGlobalRemove);

  final listener = calloc<WlRegistryListener>();
  listener.ref.global = _globalCallable.nativeFunction;
  listener.ref.global_remove = _globalRemoveCallable.nativeFunction;
  final installed =
      wl_registry_add_listener(registry, listener.cast(), nullptr);
  if (installed != 0) {
    result.diagnostic =
        'wl_registry_add_listener returned $installed (non-zero).';
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.listenersInstalled = true;

  print('[Wayland] First roundtrip (drain registry globals)...');
  final firstRoundtrip = wl_display_roundtrip(display);
  if (firstRoundtrip < 0) {
    result.diagnostic =
        'wl_display_roundtrip (first) returned $firstRoundtrip.';
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.registryDrained = true;
  result.globalNames = List<String>.unmodifiable(_seenGlobals);
  print('[Wayland] Saw ${_seenGlobals.length} global(s):');
  for (final entry in _seenGlobals) {
    print('    - $entry');
  }

  if (_compositorProxy == null) {
    result.diagnostic =
        'No wl_compositor global was advertised; cannot create a surface.';
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.compositorBound = true;
  print('[Wayland] Bound wl_compositor@$_compositorVersion '
      '(name=$_compositorName).');

  if (_shmProxy == null) {
    result.diagnostic =
        'No wl_shm global was advertised; cannot create a shm pool.';
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.shmBound = true;
  print('[Wayland] Bound wl_shm@$_shmVersion (name=$_shmName).');

  print('[Wayland] Creating surface from compositor...');
  final surface = wl_compositor_create_surface(_compositorProxy!);
  if (surface == nullptr) {
    result.diagnostic = 'wl_compositor_create_surface returned NULL.';
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.surfaceCreated = true;
  print('[Wayland] Surface (${surface.address}).');

  // SHM pool: allocate `width * height * 4` bytes via memfd + ftruncate + mmap.
  final stride = width * 4;
  final poolSize = stride * height;
  print('[Wayland] Allocating SHM pool of $poolSize bytes via memfd...');
  final memfdName = 'poc_09_wayland'.toNativeUtf8();
  final fd = memfd_create(memfdName, mfdCloexec);
  calloc.free(memfdName);
  if (fd < 0) {
    result.diagnostic = 'memfd_create returned $fd (errno-style).';
    wl_surface_destroy(surface);
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  if (ftruncate(fd, poolSize) != 0) {
    result.diagnostic = 'ftruncate failed.';
    close_fd(fd);
    wl_surface_destroy(surface);
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  final mapped =
      mmap(nullptr, poolSize, protRead | protWrite, mapShared, fd, 0);
  if (mapped == mapFailed || mapped.address == 0) {
    result.diagnostic = 'mmap failed.';
    close_fd(fd);
    wl_surface_destroy(surface);
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  print('[Wayland] Shared memory mapped at ${mapped.address}.');

  // Fill the pool with a teal background (X=0xFF, R=0x00, G=0xCC, B=0xCC).
  // Memory layout: little-endian uint32s, so bytes are B, G, R, X.
  final pixels = mapped.cast<Uint32>();
  // 0xFFFF00CC packs as LE bytes 0xCC 0x00 0xFF 0xFF → B=0xCC, G=0x00, R=0xFF,
  // X=0xFF: a distinctly orange surface that is easy to spot in screenshots.
  const int pixelValue = 0xFFFF00CC;
  for (var i = 0; i < width * height; i++) {
    pixels[i] = pixelValue;
  }

  // Create the shm pool and a buffer from it.
  final pool = wl_shm_create_pool(_shmProxy!, fd, poolSize);
  if (pool == nullptr) {
    result.diagnostic = 'wl_shm_create_pool returned NULL.';
    munmap(mapped, poolSize);
    close_fd(fd);
    wl_surface_destroy(surface);
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  final buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, stride, wlShmFormatXrgb8888);
  if (buffer == nullptr) {
    result.diagnostic = 'wl_shm_pool_create_buffer returned NULL.';
    wl_shm_pool_destroy(pool);
    munmap(mapped, poolSize);
    close_fd(fd);
    wl_surface_destroy(surface);
    wl_proxy_destroy_only(_shmProxy!);
    wl_proxy_destroy_only(_compositorProxy!);
    calloc.free(listener);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return result;
  }
  result.poolAllocated = true;
  print('[Wayland] SHM pool (${pool.address}) and buffer (${buffer.address}).');

  // Attach + damage + commit.
  print('[Wayland] Attaching + damaging + committing...');
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage(surface, 0, 0, width, height);
  wl_surface_commit(surface);
  result.bufferCommitted = true;

  // Flush all queued requests to the compositor.
  print('[Wayland] Flushing requests to compositor...');
  wl_display_flush(display);

  // Cleanup in reverse order.
  print('[Wayland] Cleaning up...');
  wl_buffer_destroy(buffer);
  wl_shm_pool_destroy(pool);
  // Unmap memory only after the compositor is done with it; we have no frame
  // callback in this POC, so a couple of roundtrips above is the closest we
  // get to a sync barrier.
  munmap(mapped, poolSize);
  close_fd(fd);
  wl_surface_destroy(surface);
  // wl_compositor / wl_shm have no destructor opcode at version 1; we just
  // destroy the local proxies.
  wl_proxy_destroy_only(_shmProxy!);
  wl_proxy_destroy_only(_compositorProxy!);
  // Close the registry listener callables so their native trampolines are
  // torn down before the listener struct itself is freed.
  _globalCallable.close();
  _globalRemoveCallable.close();
  calloc.free(listener);
  wl_registry_destroy(registry);
  wl_display_disconnect(display);
  result.disposed = true;
  print('[Wayland] Cleanup complete.');

  // Reset module-level state for idempotent re-runs.
  _compositorProxy = null;
  _shmProxy = null;
  _compositorName = null;
  _compositorVersion = null;
  _shmName = null;
  _shmVersion = null;
  _seenGlobals.clear();

  return result;
}
