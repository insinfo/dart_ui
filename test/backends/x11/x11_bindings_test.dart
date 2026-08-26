import 'dart:ffi';

import 'package:dart_ui/src/backends/x11/x11_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('XCB setup ABI', () {
    test('fixed protocol structures match xproto.h', () {
      expect(sizeOf<XcbSetup>(), 40);
      expect(sizeOf<XcbScreen>(), 40);
      expect(sizeOf<XcbFormat>(), 8);
      expect(sizeOf<XcbDepth>(), 8);
      expect(sizeOf<XcbVisualType>(), 24);
      expect(sizeOf<XcbCookie>(), 4);
    });

    test('iterator ABI carries pointer, remaining count, and byte index', () {
      final expected = sizeOf<IntPtr>() + 8;
      expect(sizeOf<XcbScreenIterator>(), expected);
      expect(sizeOf<XcbFormatIterator>(), expected);
      expect(sizeOf<XcbDepthIterator>(), expected);
      expect(sizeOf<XcbVisualTypeIterator>(), expected);
    });

    test('all format traversal and checked GC symbols are preflighted', () {
      expect(
        XcbBindings.requiredSymbols,
        containsAll(<String>[
          'xcb_setup_pixmap_formats_iterator',
          'xcb_format_next',
          'xcb_screen_allowed_depths_iterator',
          'xcb_depth_next',
          'xcb_depth_visuals_iterator',
          'xcb_visualtype_next',
          'xcb_create_gc_checked',
        ]),
      );
    });

    test('the keyboard map requests are preflighted with everything else', () {
      // Preflight or nothing: a partially bound libxcb works until the first
      // call into the missing half, by which time a window is on screen and
      // the failure looks like a rendering bug rather than a packaging one.
      expect(
        XcbBindings.requiredSymbols,
        containsAll(<String>[
          'xcb_get_keyboard_mapping',
          'xcb_get_keyboard_mapping_reply',
          'xcb_get_modifier_mapping',
          'xcb_get_modifier_mapping_reply',
        ]),
      );
    });
  });
}
