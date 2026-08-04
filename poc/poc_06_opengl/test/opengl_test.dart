import 'dart:io';

import 'package:poc_06_opengl/egl_bindings.dart';
import 'package:poc_06_opengl/gl_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('Linux EGL and OpenGL FFI bindings smoke test', () {
    if (!Platform.isLinux) {
      print('Skipping test on non-Linux platform.');
      return;
    }

    expect(eglGetDisplay, isNotNull, reason: 'eglGetDisplay should be bound');
    expect(eglInitialize, isNotNull, reason: 'eglInitialize should be bound');
    expect(glClear, isNotNull, reason: 'glClear should be bound');
    expect(glGetString, isNotNull, reason: 'glGetString should be bound');
  });
}
