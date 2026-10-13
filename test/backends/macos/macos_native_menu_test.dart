import 'dart:convert';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/macos/macos_native_menu.dart';
import 'package:test/test.dart';

void main() {
  test('menus encode as the JSON the host builds NSMenus from', () {
    final String json = encodeMacosMenus(const <NativeMenu>[
      NativeMenu('File', <NativeMenuEntry>[
        NativeMenuItem(
          id: 1,
          label: 'Save',
          key: 0x53,
          modifiers: <KeyModifier>{KeyModifier.meta, KeyModifier.shift},
        ),
        NativeMenuSeparator(),
        NativeMenu('Recent', <NativeMenuEntry>[
          NativeMenuItem(id: 2, label: 'a.svg', enabled: false),
        ]),
        NativeMenuItem(id: 3, label: 'Rulers', checked: true),
      ]),
    ]);

    expect(jsonDecode(json), <Object?>[
      <String, Object?>{
        't': 'menu',
        'l': 'File',
        'c': <Object?>[
          <String, Object?>{
            't': 'item',
            'id': 1,
            'l': 'Save',
            'e': true,
            'x': false,
            'k': 's',
            'm': 9,
          },
          <String, Object?>{'t': 'sep'},
          <String, Object?>{
            't': 'menu',
            'l': 'Recent',
            'c': <Object?>[
              <String, Object?>{
                't': 'item',
                'id': 2,
                'l': 'a.svg',
                'e': false,
                'x': false,
              },
            ],
          },
          <String, Object?>{
            't': 'item',
            'id': 3,
            'l': 'Rulers',
            'e': true,
            'x': true,
          },
        ],
      },
    ]);
  });

  test('a menu shows chords and function keys, not bare typing keys', () {
    const Set<KeyModifier> command = <KeyModifier>{KeyModifier.meta};
    expect(macosKeyEquivalent(0x5A, command), 'z');
    expect(macosKeyEquivalent(0x31, command), '1');
    expect(macosKeyEquivalent(0x26, command), '\uF700');
    expect(macosKeyEquivalent(0xBB, command), '=');
    expect(macosKeyEquivalent(0x79, const <KeyModifier>{}), '\uF70D');
    // V alone picks a tool in the canvas but types a V in a text field.
    expect(macosKeyEquivalent(0x56, const <KeyModifier>{}), isNull);
    expect(macosKeyEquivalent(0x2E, const <KeyModifier>{}), isNull);
    expect(macosKeyEquivalent(null, command), isNull);
  });
}
