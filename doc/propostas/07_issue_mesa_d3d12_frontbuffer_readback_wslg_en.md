# Mesa issue draft: D3D12 frontbuffer readback on WSL

## Title

`d3d12: drisw frontbuffer readback takes 100–350 ms per frame on WSL /dev/dxg`

## Description

### Summary

Mesa's Gallium D3D12 driver becomes readback-bound when presenting moderately
sized EGL window surfaces under WSL. Rendering uses the physical Intel GPU, but
`d3d12_flush_frontbuffer()` reads the D3D12 resource into a CPU display target
serially. The first CPU access performed by `util_copy_rect()` takes roughly
100–150 ms for a 640×480 BGRA surface and grows to more than 300 ms at
1280×720.

The issue reproduces with both the X11 and Wayland Mesa winsys paths. X11 without
DRI3 is not the primary bottleneck: X11 MIT-SHM publication takes approximately
1 ms and Wayland publication approximately 0.2 ms after the expensive readback.

I tested both Ubuntu Mesa 25.2.8 and current Mesa main. Mesa main fixes a black
frame observed with 25.2.8, but the readback performance issue remains.

### Environment

```text
Windows build:  10.0.26200.9168
WSL:            2.9.4.0
Kernel:         6.18.35.2-1
WSLg:           1.0.79
Distribution:   Ubuntu 24.04.1 LTS
GPU:            Intel UHD Graphics, PCI 8086:46B3
Windows driver: 32.0.101.7088
Mesa distro:    25.2.8-0ubuntu0.24.04.2
Mesa main:      26.3.0-devel
Mesa commit:    ebcfbe601daeb0eb2854e5a3da7f6f3b597b4976
GPU device:     /dev/dxg present; /dev/dri absent
Xwayland:       Present and MIT-SHM present; DRI3 absent
Renderer:       D3D12 (Intel(R) UHD Graphics)
```

The same result remained after updating the Intel Windows driver from
30.0.101.2079 to 32.0.101.7088.

### Reproduction

Build Mesa main with the D3D12 Gallium driver and EGL X11/Wayland platforms:

```bash
meson setup build mesa \
  --prefix=/opt/mesa-d3d12 \
  --buildtype=release \
  -Dgallium-drivers=d3d12 \
  -Dvulkan-drivers= \
  -Dllvm=disabled
meson compile -C build
meson install -C build
```

Select that Mesa build and the D3D12 Gallium driver:

```bash
export LD_LIBRARY_PATH=/opt/mesa-d3d12/lib/x86_64-linux-gnu:/usr/lib/wsl/lib
export LIBGL_DRIVERS_PATH=/opt/mesa-d3d12/lib/x86_64-linux-gnu/dri
export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/mesa-d3d12/share/glvnd/egl_vendor.d/50_mesa.json
export GALLIUM_DRIVER=d3d12
```

Run `eglgears_x11`, then resize the actual X window to 640×480:

```bash
eglgears_x11 &
pid=$!
window=$(xdotool search --sync --pid "$pid" --name eglgears | head -n 1)
xdotool windowsize --sync "$window" 640 480
wait "$pid"
```

The small initial window is relatively fast. Once the surface is really
640×480, frame time stays around 110 ms. A native Dart AOT EGL/XCB application
was used for repeatable frame counts, but Dart is not required to reproduce the
problem.

For Wayland I intercepted `wl_egl_window_create()` and
`wl_egl_window_resize()` with a small `LD_PRELOAD` shim to keep
`eglgears_wayland` at 640×480. It shows the same readback time.

### Instrumented timing

I added timing around the existing operations in
`src/gallium/drivers/d3d12/d3d12_screen.cpp`,
`d3d12_flush_frontbuffer()`:

```cpp
void *map = winsys->displaytarget_map(winsys, res->dt, 0);
void *res_map = pipe_texture_map(pctx, pres, level, layer,
                                 PIPE_MAP_READ, ...);
util_copy_rect(map, pres->format, res->dt_stride, ...,
               res_map, transfer->stride, ...);
pipe_texture_unmap(pctx, transfer);
winsys->displaytarget_display(...);
```

Typical 640×480 results:

| Stage | X11 | Wayland |
|---|---:|---:|
| `pipe_texture_map()` / GPU wait | 1–4 ms | 1–4 ms |
| first reads and copy in `util_copy_rect()` | 103–149 ms | 107–140 ms |
| unmap | ~0.01 ms | ~0.01 ms |
| winsys publication | 0.7–2.5 ms | ~0.16 ms |

The first reads from `res_map` dominate. This looks like serial page
materialization or transfer of the D3D12 readback allocation through
`/dev/dxg`/VMBus rather than normal RAM copy bandwidth.

### Size scaling

| Surface | Serial frontbuffer copy |
|---|---:|
| 300×300 | 2–8 ms per frame |
| 640×480 | 106–153 ms total; 7–9 FPS |
| 800×600 | 172–186 ms; about 5 FPS |
| 1280×720 | 327–359 ms; about 2.8 FPS |

This strong size dependence is visible with both X11 and Wayland.

### Native GDB stack

I compiled the application to a Dart AOT ELF, caught the instrumented Gallium
library loading, and broke on the first frame. GDB confirmed this stack:

```text
#0 d3d12_flush_frontbuffer(...)
#1 drisw_swap_buffers()
#2 dri2_x11_swap_buffers()
#3 dri2_swap_buffers()
#4 eglSwapBuffers()
#5 Dart AOT FFI frame
```

The D3D12 and Intel worker threads were either waiting in `libd3d12core.so` or
executing the Intel UMD (`libigd12um64xel.so` / `libigc.so`). The complete
`thread apply all bt` trace is available.

### Parallel-copy mitigation prototype

As a diagnostic, I divided the destination into horizontal bands and dispatched
`util_copy_rect()` jobs through a persistent Mesa `util_queue`. The experiment
is opt-in through `D3D12_FRONTBUFFER_THREADS`; buffers below a configurable
512 KiB threshold remain serial, and block-compressed formats remain serial.

Results at 640×480:

| Implementation | Result |
|---|---:|
| upstream serial copy | about 7.7 FPS, 110–130 ms copy |
| 8 parallel bands | 29.6–33.8 FPS |
| 32 persistent workers | 38.7–40.8 FPS |

Five consecutive 640×480 create/render/destroy runs completed normally at
approximately 29.5–32.3 FPS with short 10-frame runs. A 300×300 run remained on
the serial path and reached about 172 FPS in the same AOT test. At 1920×1080,
32 workers still achieved only about 6–7 FPS, so this is a mitigation rather
than a complete solution.

The two-file prototype modifies:

```text
src/gallium/drivers/d3d12/d3d12_screen.cpp
src/gallium/drivers/d3d12/d3d12_screen.h
```

The exact tested diff is preserved as
[`mesa_d3d12_frontbuffer_parallel_copy.patch`](mesa_d3d12_frontbuffer_parallel_copy.patch).

I can submit the patch as a merge request after feedback on the preferred
configuration mechanism (`driconf`, environment option, or automatic selection
for the DXG winsys).

### Vulkan/Dozen cross-check

I also built `microsoft-experimental`/Dozen from the same Mesa commit. It
correctly selects the physical Intel GPU and exposes XCB, Wayland, and swapchain
support:

```text
deviceName = Microsoft Direct3D12 (Intel(R) UHD Graphics)
driverName = Dozen
VK_KHR_wayland_surface
VK_KHR_xcb_surface
VK_KHR_swapchain
```

However, 120 `vkcube` frames take about 15 seconds at 640×480 on both Wayland
and XCB (approximately 8 FPS). At 300×300 they take about 5 seconds
(approximately 24 FPS). Therefore Vulkan does not automatically bypass the
same WSLg system-memory presentation limitation.

### External-memory feasibility and separate Dozen finding

Two independent Linux processes successfully exported/imported a 640×480
`VK_FORMAT_B8G8R8A8_UNORM` D3D12-backed image using
`VK_KHR_external_memory_fd` and `SCM_RIGHTS`. The receiving process allocated
and bound the imported image without CPU readback. This proves that a client to
Linux-compositor external-image path is technically possible on `/dev/dxg`.

The matching external timeline semaphore import is currently rejected by Dozen
with `VK_ERROR_INVALID_EXTERNAL_HANDLE`. After that failed import,
`vkDestroySemaphore()` causes `Pure virtual function called!`, suggesting that
the failed import path leaves the sync object partially destroyed. I can file
this as a separate Dozen issue with the standalone C reproducer.

### WSLg boundary

Mesa cannot remove the whole WSLg copy by itself. WSLg currently presents a
Weston CPU buffer through a GFXREDIR SectionFs pool; the public PDU describes a
section name, pool, offset, stride, width, height, and pixel format, but not a
D3D12 resource handle or fence. The official WSLg README describes this as the
first-generation system-memory vGPU interoperability path.

The WSLg-side architectural report, including the external-image proposal, is:

https://github.com/microsoft/wslg/issues/1498

An additional experiment gave the Linux-created D3D12 resource a shared name
and attempted `ID3D12Device::OpenSharedHandleByName()` from a native Windows
process on the same Intel adapter. The name was not visible across the VM/host
boundary (`HRESULT 0x80070006`, invalid handle). This confirms that the current
public shared-handle namespace is sufficient between Linux processes but not a
replacement for a WSLg host protocol change.

### Questions

1. Would a persistent `util_queue` mitigation for large D3D12 frontbuffer
   readbacks be acceptable in Mesa while WSLg remains system-memory based?
2. Should it be controlled through `driconf`, an environment option, or selected
   automatically for the DXG/sw-winsys path?
3. Is there an existing batched/tiled readback mechanism in the D3D12 driver
   that should be used instead of parallel CPU page access?
4. Should the external semaphore failed-import teardown be filed separately
   against Dozen? A minimal standalone C reproducer is ready.

I can provide the complete Mesa diff, GDB trace, exact benchmark commands, and
the external-memory/semaphore reproducer.
