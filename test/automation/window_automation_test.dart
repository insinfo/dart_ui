import 'dart:convert';

import 'package:dart_ui/automation.dart';
import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A window with one button, driven only through [WindowAutomation].
void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  test('commands, pointer, keys and a screenshot, without a mouse', () async {
    var pressed = 0;
    var counter = 0;
    final CommandRegistry registry = CommandRegistry()
      ..register(CommandSpec(
        id: 'counter.add',
        label: 'Add',
        shortcut: const KeyGesture(logicalKeyA, command: true),
        params: const <CommandParam>[
          CommandParam('by', CommandParamType.integer),
        ],
        run: (CommandArgs args) => counter += args.integer('by', 1),
      ));
    final Application app = await Application.start(
      rootWidget: Directionality(
        textDirection: TextDirection.leftToRight,
        child: CallbackShortcuts(
          bindings: registry.keyBindings(),
          child: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              behavior: GestureHitTestBehavior.opaque,
              onTap: () => pressed++,
              child: const SizedBox(
                width: 100,
                height: 40,
                child: ColoredBox(color: Color(0xFFCC2200)),
              ),
            ),
          ),
        ),
      ),
      backends: <WindowingBackendEntry>[
        const WindowingBackendEntry(
          name: 'headless',
          create: HeadlessWindowingBackend.new,
        ),
      ],
      presentations: <PresentationPathEntry>[
        PresentationPathEntry.cpuRenderer(
            backend: const CpuRendererBackend(), name: 'cpu'),
      ],
      options: const ApplicationOptions(
        title: 'automation test',
        size: Size(200, 120),
      ),
    );
    addTearDown(app.dispose);
    final ApplicationWindow window = app.primaryWindow;
    await window.drawFrame();

    final WindowAutomation automation = WindowAutomation(
      application: app,
      window: window,
      registry: registry,
      menus: () => const <SubmenuSpec>[
        SubmenuSpec('Edit', <MenuSpecEntry>[CommandItem('counter.add')]),
      ],
      inspect: () => <String, Object?>{'counter': counter},
    );

    expect(
      await automation.handle('engine.execute', <String, Object?>{
        'command': 'counter.add',
        'params': <String, Object?>{'by': 2},
      }),
      2,
    );
    await expectLater(
      () => automation.handle('engine.execute', <String, Object?>{
        'command': 'counter.add',
        'params': <String, Object?>{'bye': 2},
      }),
      throwsA(isA<CommandError>()),
    );

    final rows = await automation.handle('ui.menu.list', <String, Object?>{})
        as List<Object?>;
    expect((rows.single! as Map)['command'], 'counter.add');

    await automation.handle('ui.pointer', <String, Object?>{
      'events': <Object?>[
        <String, Object?>{'kind': 'click', 'x': 20, 'y': 20},
        <String, Object?>{'kind': 'click', 'x': 150, 'y': 100},
      ],
    });
    expect(pressed, 1, reason: 'only the click on the button presses it');

    await automation
        .handle('ui.key', <String, Object?>{'key': 'a', 'cmd': true});
    expect(counter, 3);

    final inspect = await automation.handle('ui.inspect', <String, Object?>{})
        as Map<String, Object?>;
    expect(inspect['width'], 200);
    expect(inspect['counter'], 3);

    final shot = await automation.handle('ui.screenshot', <String, Object?>{})
        as Map<String, Object?>;
    expect(shot['width'], 200);
    final decoded = decodePng(base64Decode(shot['pngBase64']! as String),
        order: ImageChannelOrder.rgba);
    // The button's red at its middle.
    const int i = (20 * 200 + 50) * 4;
    expect(decoded.pixels.sublist(i, i + 3), <int>[0xCC, 0x22, 0x00]);
  });
}
