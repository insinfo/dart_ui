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
  Display *x_display = XOpenDisplay(NULL);
  if (x_display == NULL) {
    fprintf(stderr, "XOpenDisplay failed\n");
    return (void *)2;
  }

  const int screen = DefaultScreen(x_display);
  Window window = XCreateSimpleWindow(
      x_display, RootWindow(x_display, screen), 0, 0, 640, 360, 0,
      BlackPixel(x_display, screen), BlackPixel(x_display, screen));
  XStoreName(x_display, window, "WSLg EGL D3D12 TLS reproducer");
  XMapWindow(x_display, window);
  XSync(x_display, False);

  EGLDisplay egl_display = eglGetDisplay((EGLNativeDisplayType)x_display);
  if (egl_display == EGL_NO_DISPLAY) fail_egl("eglGetDisplay");
  if (!eglInitialize(egl_display, NULL, NULL)) fail_egl("eglInitialize");
  if (!eglBindAPI(EGL_OPENGL_API)) fail_egl("eglBindAPI");

  const EGLint config_attributes[] = {
      EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_RED_SIZE, 8,
      EGL_GREEN_SIZE, 8,
      EGL_BLUE_SIZE, 8,
      EGL_NONE,
  };
  EGLConfig config = NULL;
  EGLint config_count = 0;
  if (!eglChooseConfig(egl_display, config_attributes, &config, 1,
                       &config_count) ||
      config_count == 0) {
    fail_egl("eglChooseConfig");
  }

  EGLContext context =
      eglCreateContext(egl_display, config, EGL_NO_CONTEXT, NULL);
  if (context == EGL_NO_CONTEXT) fail_egl("eglCreateContext");
  EGLSurface surface = eglCreateWindowSurface(
      egl_display, config, (EGLNativeWindowType)window, NULL);
  if (surface == EGL_NO_SURFACE) fail_egl("eglCreateWindowSurface");
  if (!eglMakeCurrent(egl_display, surface, surface, context)) {
    fail_egl("eglMakeCurrent");
  }

  printf("renderer: %s\n", glGetString(GL_RENDERER));
  glClearColor(0.15f, 0.55f, 0.85f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  eglSwapBuffers(egl_display, surface);
  glFinish();

  puts("destroying EGL objects");
  eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(egl_display, context);
  eglDestroySurface(egl_display, surface);
  if (getenv("SKIP_EGL_TERMINATE") == NULL) {
    puts("calling eglTerminate");
    eglTerminate(egl_display);
    puts("eglTerminate returned; worker thread is about to exit");
  } else {
    puts("SKIP_EGL_TERMINATE is set; worker thread is about to exit");
  }

  XDestroyWindow(x_display, window);
  XCloseDisplay(x_display);
  return NULL;
}

int main(void) {
  if (!XInitThreads()) {
    fprintf(stderr, "XInitThreads failed\n");
    return 2;
  }
  pthread_t worker;
  if (pthread_create(&worker, NULL, render_and_terminate, NULL) != 0) {
    perror("pthread_create");
    return 2;
  }
  void *result = NULL;
  if (pthread_join(worker, &result) != 0) {
    perror("pthread_join");
    return 2;
  }
  printf("worker joined with result %ld\n", (long)result);
  return (int)(long)result;
}
