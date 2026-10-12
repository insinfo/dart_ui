/// The keysym-to-VK rule both Linux backends use for [KeyEvent.logicalKey].
///
/// `focus.dart` fixes the contract - the widgets compare against Windows
/// virtual-key codes - and until this rule existed the X11 and Wayland
/// backends handed them keysyms: Tab was `0xff09`, the arrows `0xff51`-`0xff54`
/// and Ctrl+C `0x63`, so a text field on Linux took text and nothing else.
library;

import 'package:dart_ui/src/platform/input_events.dart';
import 'package:dart_ui/src/platform/keysyms.dart';
import 'package:dart_ui/src/widgets/focus.dart';
import 'package:test/test.dart';

/// X keycodes are evdev + 8 under xkb, on both backends.
int _x(int evdev) => evdev + 8;

void main() {
  test('the keys the widgets name by constant', () {
    expect(keysymToVirtualKey(keysymTab), logicalKeyTab);
    expect(keysymToVirtualKey(0xfe20), logicalKeyTab,
        reason: 'ISO_Left_Tab is what Shift+Tab produces, and it is still Tab');
    expect(keysymToVirtualKey(keysymReturn), logicalKeyEnter);
    expect(keysymToVirtualKey(0xff8d), logicalKeyEnter, reason: 'KP_Enter');
    expect(keysymToVirtualKey(keysymEscape), logicalKeyEscape);
    expect(keysymToVirtualKey(keysymBackSpace), logicalKeyBackspace);
    expect(keysymToVirtualKey(keysymDelete), logicalKeyDelete);
    expect(keysymToVirtualKey(keysymLeft), logicalKeyArrowLeft);
    expect(keysymToVirtualKey(keysymUp), logicalKeyArrowUp);
    expect(keysymToVirtualKey(keysymRight), logicalKeyArrowRight);
    expect(keysymToVirtualKey(keysymDown), logicalKeyArrowDown);
    expect(keysymToVirtualKey(keysymHome), logicalKeyHome);
    expect(keysymToVirtualKey(keysymEnd), logicalKeyEnd);
    expect(keysymToVirtualKey(keysymPrior), logicalKeyPageUp);
    expect(keysymToVirtualKey(keysymNext), logicalKeyPageDown);
    expect(keysymToVirtualKey(0x20), logicalKeySpace);
  });

  test('a letter is its upper-case VK at every shift level', () {
    expect(keysymToVirtualKey(0x63), 0x43, reason: 'c: Ctrl+C');
    expect(keysymToVirtualKey(0x43), 0x43, reason: 'C: Ctrl+Shift+C');
    expect(keysymToVirtualKey(0x37), 0x37, reason: '7');
  });

  test('a keysym with no VK takes the US key in the same position', () {
    // Cyrillic_es is on the C key of a Russian layout: Ctrl+C must copy.
    expect(keysymToVirtualKey(0x6d3, xkbKeycode: _x(46)), 0x43);
    // ccedilla is where the US ; is on ABNT2.
    expect(keysymToVirtualKey(0xe7, xkbKeycode: _x(39)), 0xBA);
    // A key with no keysym at all still has a position.
    expect(keysymToVirtualKey(keysymNoSymbol, xkbKeycode: _x(30)), 0x41);
  });

  test('a key with neither a VK nor a known position is 0', () {
    expect(keysymToVirtualKey(0x6d3), 0);
    expect(keysymToVirtualKey(keysymNoSymbol, xkbKeycode: _x(200)), 0);
  });

  test('punctuation is its US OEM VK, shifted or not', () {
    expect(keysymToVirtualKey(0x2C), 0xBC, reason: ',');
    expect(keysymToVirtualKey(0x3C), 0xBC, reason: '<, Shift+comma on US');
    expect(keysymToVirtualKey(0x2F), 0xBF, reason: '/');
    expect(keysymToVirtualKey(0x3F), 0xBF, reason: '?');
  });

  test('the function row and the keypad', () {
    expect(keysymToVirtualKey(keysymF1), 0x70);
    expect(keysymToVirtualKey(keysymF1 + 9), 0x79, reason: 'F10');
    expect(keysymToVirtualKey(keysymF1 + 23), 0x87, reason: 'F24');
    expect(keysymToVirtualKey(0xffb1), 0x61, reason: 'KP_1 is VK_NUMPAD1');
    expect(keysymToVirtualKey(0xff96), logicalKeyArrowLeft,
        reason: 'KP_Left, NumLock off, is a left arrow');
  });

  test('the side a modifier keysym named travels in the location', () {
    expect(keysymToVirtualKey(keysymShiftL), 0x10);
    expect(keysymToVirtualKey(keysymShiftR), 0x10);
    expect(keysymLocation(keysymShiftL), KeyLocation.left);
    expect(keysymLocation(keysymShiftR), KeyLocation.right);
    expect(keysymLocation(keysymControlR), KeyLocation.right);
    expect(keysymLocation(keysymIsoLevel3Shift), KeyLocation.right,
        reason: 'AltGr is the right Alt');
    expect(keysymToVirtualKey(keysymSuperL), 0x5B);
    expect(keysymLocation(0xffb1), KeyLocation.numpad);
    expect(keysymLocation(0x61), KeyLocation.standard);
  });
}
