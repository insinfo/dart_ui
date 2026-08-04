import 'dart:io';
import 'package:test/test.dart';
import 'package:poc_03_appkit_window/objc_runtime.dart';

void main() {
  test('macOS Objective-C Runtime bindings smoke test', () {
    if (!Platform.isMacOS) {
      print('Skipping test on non-macOS platform.');
      return;
    }

    final nsObjectClass = getClass('NSObject');
    expect(nsObjectClass.address, isNot(0), reason: 'Should get NSObject class pointer');

    final nsStringClass = getClass('NSString');
    expect(nsStringClass.address, isNot(0), reason: 'Should get NSString class pointer');

    final selAlloc = sel('alloc');
    expect(selAlloc.address, isNot(0), reason: 'Should register alloc selector');
  });
}
