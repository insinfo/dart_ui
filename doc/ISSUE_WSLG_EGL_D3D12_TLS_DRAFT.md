## Windows build number

`10.0.26200.9168`

## Distribution version

Ubuntu 24.04.1 LTS, Mesa `25.2.8-0ubuntu0.24.04.2`.

## WSL versions

```text
WSL version: 2.7.12.0
Kernel version: 6.18.33.2-2
WSLg version: 1.0.73.2
MSRDC version: 1.2.7214
Direct3D version: 1.611.1-81528511
DXCore version: 10.0.26100.1-240331-1435.ge-release
Windows version: 10.0.26200.9168
```

WSL 2.7.12 is the latest release at the time of filing.

GPU: Intel(R) UHD Graphics, PCI ID `8086:46B3`.
Windows GPU driver: `30.0.101.2079`, dated 2022-05-25.

## Steps to reproduce

The bug reproduces without Dart, FFI, or sanitizers. An EGL context is created
and destroyed on a pthread. `eglTerminate` returns successfully, but the
process segfaults while the pthread is exiting.

Install build dependencies:

```bash
sudo apt install build-essential pkg-config libx11-dev libegl1-mesa-dev libgl-dev
```

Save the following as `repro_egl_d3d12_tls.c`:

```c
#include <EGL/egl.h>
#include <GL/gl.h>
#include <X11/Xlib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static void fail_egl(const char *operation) {
  fprintf(stderr, "%s failed: EGL error 0x%04x\n", operation, eglGetError());
  exit(2);
}

static void *render_and_terminate(void *unused) {
  (void)unused;
  Display *xdpy = XOpenDisplay(NULL);
  if (!xdpy) return (void *)2;
  int screen = DefaultScreen(xdpy);
  Window window = XCreateSimpleWindow(
      xdpy, RootWindow(xdpy, screen), 0, 0, 640, 360, 0,
      BlackPixel(xdpy, screen), BlackPixel(xdpy, screen));
  XMapWindow(xdpy, window);
  XSync(xdpy, False);

  EGLDisplay dpy = eglGetDisplay((EGLNativeDisplayType)xdpy);
  if (dpy == EGL_NO_DISPLAY) fail_egl("eglGetDisplay");
  if (!eglInitialize(dpy, NULL, NULL)) fail_egl("eglInitialize");
  if (!eglBindAPI(EGL_OPENGL_API)) fail_egl("eglBindAPI");
  EGLint attrs[] = {
      EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
      EGL_NONE,
  };
  EGLConfig config;
  EGLint count;
  if (!eglChooseConfig(dpy, attrs, &config, 1, &count) || !count)
    fail_egl("eglChooseConfig");
  EGLContext context = eglCreateContext(dpy, config, EGL_NO_CONTEXT, NULL);
  EGLSurface surface = eglCreateWindowSurface(
      dpy, config, (EGLNativeWindowType)window, NULL);
  if (context == EGL_NO_CONTEXT || surface == EGL_NO_SURFACE)
    fail_egl("create context/surface");
  if (!eglMakeCurrent(dpy, surface, surface, context))
    fail_egl("eglMakeCurrent");

  printf("renderer: %s\n", glGetString(GL_RENDERER));
  glClear(GL_COLOR_BUFFER_BIT);
  eglSwapBuffers(dpy, surface);
  glFinish();

  eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(dpy, context);
  eglDestroySurface(dpy, surface);
  if (!getenv("SKIP_EGL_TERMINATE")) {
    puts("calling eglTerminate");
    eglTerminate(dpy);
    puts("eglTerminate returned; pthread is about to exit");
  }
  XDestroyWindow(xdpy, window);
  XCloseDisplay(xdpy);
  return NULL;
}

int main(void) {
  XInitThreads();
  pthread_t worker;
  pthread_create(&worker, NULL, render_and_terminate, NULL);
  void *result = NULL;
  pthread_join(worker, &result);
  printf("worker joined: %ld\n", (long)result);
  return (int)(long)result;
}
```

Compile and run as a regular WSL user:

```bash
cc -g -O0 -Wall -Wextra repro_egl_d3d12_tls.c \
  -o repro_egl_d3d12_tls $(pkg-config --cflags --libs x11 egl gl) -pthread

DISPLAY=:0 GALLIUM_DRIVER=d3d12 ./repro_egl_d3d12_tls
echo $?
```

## Expected behavior

`eglTerminate` must not unload code that is still registered as a pthread TLS
destructor. The worker should exit and `pthread_join` should return normally.

## Actual behavior

```text
renderer: D3D12 (Intel(R) UHD Graphics)
calling eglTerminate
eglTerminate returned; pthread is about to exit
Segmentation fault (core dumped)
exit code: 139
```

Control matrix:

```text
GALLIUM_DRIVER=llvmpipe, eglTerminate called        -> exit 0
GALLIUM_DRIVER=d3d12, SKIP_EGL_TERMINATE=1         -> exit 0
GALLIUM_DRIVER=d3d12, eglTerminate called           -> exit 139
```

`glxinfo -B` confirms that the failing path is accelerated:

```text
Device: D3D12 (Intel(R) UHD Graphics)
Accelerated: yes
OpenGL renderer string: D3D12 (Intel(R) UHD Graphics)
```

## GDB findings

Breakpoints on `eglDestroyContext`, `eglDestroySurface`, `eglTerminate`, and
`dlclose` show that the crash happens after `eglTerminate` returns.

During `eglTerminate`, calls originating from Mesa Gallium unload the WSL
D3D12 stack and Intel UMD modules. A representative `dlclose` stack is:

```text
#0  __dlclose
#1  libd3d12core.so
#2  libd3d12core.so
#3  libd3d12.so
#4  libd3d12.so
#5  libd3d12core.so
#6  libgallium-25.2.8-0ubuntu0.24.04.2.so
```

The pthread then crashes while glibc is running TLS destructors:

```text
Thread received signal SIGSEGV
#0  0x00007fffd4c41b10 in ?? ()
#1  __GI___nptl_deallocate_tsd () at nptl_deallocate_tsd.c:73
#2  start_thread () at pthread_create.c:455
#3  clone3 ()
```

At the time of the crash, the program counter is unmapped. Before the
`dlclose` sequence, that address range belonged to `libd3d12core.so`. This is
consistent with a pthread TLS destructor pointing into an already unloaded
module.

The issue was originally found in a Dart AOT program. The standalone C
reproducer above demonstrates that Dart and FFI are not required.

## Library versions and hashes

```text
libegl-mesa0       25.2.8-0ubuntu0.24.04.2
libgl1-mesa-dri    25.2.8-0ubuntu0.24.04.2
mesa-libgallium    25.2.8-0ubuntu0.24.04.2

libd3d12.so:
b3d78d409a4dbbe8612551fc0c0d746d3e58d7997ee7eba78ce1064d77cfa8c3

libd3d12core.so:
a4104a2022932d8e6c714f103ebd89db1c5bdbf36fe92151c88d3d93d4e3894d
```

Potentially related, but different, reports:

- https://github.com/microsoft/wslg/issues/1214
- https://github.com/microsoft/wslg/issues/1431
- https://github.com/microsoft/WSL/issues/9244

No existing issue with the same `eglTerminate` / unloaded pthread TLS
destructor signature was found.

## WSL logs and dumps

The WSLg compositor does not crash and no Weston dump is generated. The client
process alone receives SIGSEGV. A complete GDB trace can be provided if needed.
