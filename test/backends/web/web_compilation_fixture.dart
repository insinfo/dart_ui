/// The entrypoint `web_compilation_test.dart` compiles, and nothing else.
///
/// Not a test. It is a *fixture*: a program that imports every library of the
/// web backend and touches enough of each one that a tree shaker cannot delete
/// it, so that compiling this file is a real check that the whole backend is
/// reachable from `dart2js` and `dart2wasm`.
///
/// ## Why the calls at the bottom are there
///
/// A `main` that imported these libraries and did nothing would compile even if
/// every one of them were unreachable, because both compilers drop code nothing
/// calls. The reference to each library below is therefore deliberate and must
/// stay: it is what turns "these files parse" into "these files compile, and
/// everything they transitively import compiles too".
///
/// The transitive part is the whole point. The failure this fixture is built to
/// catch is somebody adding an `import 'dart:ffi'` - or an import of a library
/// that itself imports it - somewhere under `lib/src/rendering/gpu/webgl` or
/// `lib/src/backends/web`. That change would pass `dart analyze`, pass every VM
/// test, and break the web build. Here it fails immediately, in both
/// compilers, with the offending import named by the compiler itself.
///
/// ## Why nothing here creates a canvas
///
/// This file is compiled, never run. Everything it names is either a pure
/// function or a constructor argument, and no DOM object is created, because a
/// compiler does not need one and a fixture that required a browser to compile
/// would be a fixture that could not run in CI.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/web/dom_input_translation.dart';
import 'package:dart_ui/src/backends/web/web_gl_presenter.dart';
import 'package:dart_ui/src/backends/web/web_gpu_presenter.dart';
import 'package:dart_ui/src/backends/web/web_window.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_canvas_target.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_framebuffer_pool.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_sparse_driver.dart';
import 'package:dart_ui/src/rendering/gpu/webgl/webgl_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_canvas_target.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_interop.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_sparse_driver.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_sparse_executor.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/wgsl_sparse_shaders.dart';

/// Referenced from [main] so neither compiler can drop the libraries above.
///
/// Returns a string rather than printing each fact, so the whole thing is one
/// value the compiler must keep alive.
String describeWebBackend() {
  final StringBuffer buffer = StringBuffer()
    // dom_input_translation.dart: the pure half of the input path.
    ..writeln(webPhysicalKeyFromCode('KeyA'))
    ..writeln(webKeyLocation(kDomKeyLocationNumpad).name)
    ..writeln(webPointerKind('touch').name)
    ..writeln(webPointerButton(2)?.name)
    ..writeln(webScrollDelta(deltaX: 0, deltaY: 1, deltaMode: kDomDeltaLine)
        .unit
        .name)
    ..writeln(webClickCount(0))
    ..writeln(webKeyboardTextFromKey(key: 'a', control: false, meta: false))
    ..writeln(webTextFromBeforeInput(inputType: 'insertText', data: 'x'))
    ..writeln(sanitiseWebTextInput('ok'))
    ..writeln(kWebTextInsertingInputTypes.length)
    ..writeln(kWebLinesPerPage)
    ..writeln(webKnownKeyCodes.length)
    // webgl_surface_descriptor.dart.
    ..writeln(kWebGl2ContextId)
    ..writeln(defaultWebGl2ContextAttributes().runtimeType)
    // webgl_framebuffer_pool.dart.
    ..writeln(webGlLayerBucket(30))
    ..writeln(WebGlObjectTable<Object>().nextId)
    // webgl_backend.dart.
    ..writeln(const WebGlRendererBackend().info)
    ..writeln(WebGlRendererBackend.backendName)
    ..writeln(WebGlFontResolver().resolveFont(0))
    // wgsl_shaders.dart and webgpu_interop.dart: the pure half and the
    // interop half of the WebGPU backend.
    ..writeln(kWgslShaderModuleSource.length)
    ..writeln(kWebGpuContextId)
    ..writeln(webGpuClearValue(0xFF000000).a)
    // wgsl_sparse_shaders.dart: the pure half of the experimental sparse
    // path, which reaches `gl_sparse_strips.dart` and through it the
    // backend-neutral plan. That chain is exactly the kind of shared library a
    // `dart:ffi` import could sneak into without any VM test noticing.
    ..writeln(kWgslSparseShaderModuleSource.length)
    ..writeln(kWebGpuSparseUniformSliceSize)
    ..writeln(wgslSparseFragmentEntryPoint(coverageMode: 0, paintMode: 0))
    // webgpu_backend.dart.
    ..writeln(const WebGpuRendererBackend().info)
    ..writeln(WebGpuRendererBackend.backendName)
    ..writeln(WebGpuFontResolver().resolveFont(0))
    ..writeln(WebGpuLayerTargetPool.bucket(30))
    // web_window.dart.
    ..writeln(WebWindowingBackend.backendName)
    ..writeln(kWebCursorNames[SystemCursor.hand])
    // The core, which must go on being reachable from web code: this is the
    // half the roadmap calls portable, and an accidental `dart:io` in it would
    // break here too.
    ..writeln(const Size(1, 1))
    ..writeln(const Rect.fromLTWH(0, 0, 1, 1));
  return buffer.toString();
}

/// Named so the two target types below cannot be tree-shaken either.
///
/// They are the classes a canvas actually presents through, and they are the
/// most likely place for a non-portable import to appear because they are the
/// ones that touch the most of the renderer. Referencing the *types* is enough
/// to force their libraries to be compiled.
List<Type> webBackendTypes() => <Type>[
      WebGlRenderDevice,
      WebGlOffscreenTarget,
      WebGlCanvasTarget,
      WebGlCanvasPresenter,
      WebGlCanvasSurfaceDescriptor,
      WebGlFramebufferPool,
      WebGlImageCache,
      // The experimental sparse-strip adapters, one per web backend. Both are
      // reachable only through an opt-in seam, which is precisely why their
      // libraries would otherwise never be compiled by anything.
      WebGlSparseDriver,
      WebGpuSparseDriver,
      WebGpuSparseExecutor,
      SparseWebGpuMaterial,
      WebGpuRenderDevice,
      WebGpuCanvasTarget,
      WebGpuCanvasPresenter,
      WebGpuCanvasSurfaceDescriptor,
      WebGpuImageCache,
      WebWindow,
      WebWindowingBackend,
    ];

void main() {
  // Printed rather than discarded: a compiler is entitled to delete a pure
  // computation whose result is thrown away, and this file exists to make the
  // computation unavoidable.
  print(describeWebBackend());
  print(webBackendTypes().length);
}
