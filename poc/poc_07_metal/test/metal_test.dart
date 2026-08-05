import 'dart:io';

import 'package:poc_07_metal/metal_bindings.dart';
import 'package:poc_07_metal/objc_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('macOS Metal and Objective-C Runtime bindings smoke test', () {
    if (!Platform.isMacOS) {
      print('Skipping test on non-macOS platform.');
      return;
    }

    // Core selectors and classes required by the clear-render flow.
    final nsObjectClass = getClass('NSObject');
    expect(nsObjectClass.address, isNot(0),
        reason: 'Should get NSObject class pointer');

    final cametalLayerClass = getClass('CAMetalLayer');
    expect(cametalLayerClass.address, isNot(0),
        reason: 'Should get CAMetalLayer class pointer');

    final mtlRenderPassDescriptorClass = getClass('MTLRenderPassDescriptor');
    expect(mtlRenderPassDescriptorClass.address, isNot(0),
        reason: 'Should get MTLRenderPassDescriptor class pointer');

    final selNextDrawable = sel('nextDrawable');
    expect(selNextDrawable.address, isNot(0),
        reason: 'Should register nextDrawable selector');

    final selRenderPassDescriptor = sel('renderPassDescriptor');
    expect(selRenderPassDescriptor.address, isNot(0),
        reason: 'Should register renderPassDescriptor selector');

    // The C entry point for the system default Metal device must resolve. The
    // lookup itself throws if the symbol is missing, so the assertion only
    // guards that the bound function is non-null.
    expect(mtlCreateSystemDefaultDevice, isNotNull,
        reason: 'MTLCreateSystemDefaultDevice should be bound');
    expect(sel_registerName, isNotNull,
        reason: 'sel_registerName should be bound');
    expect(objc_getClass, isNotNull, reason: 'objc_getClass should be bound');
  });
}
