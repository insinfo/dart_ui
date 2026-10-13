import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  late CommandRegistry registry;
  late List<String> log;
  var selected = false;
  var rulers = false;

  setUp(() {
    log = <String>[];
    selected = false;
    rulers = false;
    registry = CommandRegistry()
      ..registerAll(<CommandSpec>[
        CommandSpec(
          id: 'shape.rectangle',
          label: 'Rectangle',
          params: const <CommandParam>[
            CommandParam('x', CommandParamType.number, required: true),
            CommandParam('y', CommandParamType.number, required: true),
            CommandParam('width', CommandParamType.number, required: true),
            CommandParam('height', CommandParamType.number, required: true),
            CommandParam('name', CommandParamType.string),
          ],
          run: (CommandArgs args) {
            log.add('rect ${args.number('width')}x${args.number('height')}');
            return <String, Object?>{'id': 7};
          },
        ),
        CommandSpec(
          id: 'edit.delete',
          label: 'Delete',
          shortcut: const KeyGesture(0x2E),
          alsoShortcuts: const <KeyGesture>[KeyGesture(0x08)],
          enabled: (_) => selected,
          disabledReason: (_) => 'nothing is selected',
          run: (_) => log.add('delete'),
        ),
        CommandSpec(
          id: 'view.rulers',
          label: 'Rulers',
          checked: (_) => rulers,
          run: (_) => rulers = !rulers,
        ),
        CommandSpec(
          id: 'edit.fail',
          label: 'Fail',
          run: (_) => throw StateError('broken'),
        ),
        CommandSpec(
          id: 'edit.refuse',
          label: 'Refuse',
          run: (_) => throw const CommandError('cannot do that here'),
        ),
      ]);
  });

  test('a command runs with its parameters and returns its result', () {
    final outcome = registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': 50.5});
    expect(outcome.ok, isTrue);
    expect(outcome.result, <String, Object?>{'id': 7});
    expect(log, <String>['rect 100.0x50.5']);
  });

  test('an unknown parameter is refused before anything runs, with a hint', () {
    final outcome = registry.execute('shape.rectangle',
        <String, Object?>{'x': 0, 'y': 0, 'widht': 100, 'height': 50});
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('`widht`'));
    expect(outcome.error, contains('did you mean `width`'));
    expect(log, isEmpty);
  });

  test('a missing or mistyped parameter is refused', () {
    expect(
        registry.execute('shape.rectangle',
            <String, Object?>{'x': 0, 'y': 0, 'width': 10}).error,
        contains('needs `height`'));
    expect(
        registry.execute('shape.rectangle', <String, Object?>{
          'x': 0,
          'y': 0,
          'width': 'wide',
          'height': 1,
        }).error,
        contains('`width` must be a number'));
    expect(log, isEmpty);
  });

  test('an unknown command names the nearest one', () {
    final outcome = registry.execute('edit.delet');
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('did you mean `edit.delete`'));
  });

  test('a disabled command says why and does not run', () {
    final outcome = registry.execute('edit.delete');
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('nothing is selected'));
    selected = true;
    expect(registry.execute('edit.delete').ok, isTrue);
    expect(log, <String>['delete']);
  });

  test('an exception is a failed outcome, never a crash', () {
    expect(registry.execute('edit.fail').error, contains('broken'));
    expect(registry.execute('edit.refuse').error, 'cannot do that here');
  });

  test('a batch runs in order inside one transaction and stops on failure', () {
    final transactions = <String>[];
    registry.transaction = (String label, Object? Function() body) {
      transactions.add(label);
      return body();
    };
    selected = true;
    final outcome =
        registry.batch(<({String command, Map<String, Object?> params})>[
      (
        command: 'shape.rectangle',
        params: <String, Object?>{'x': 0, 'y': 0, 'width': 1, 'height': 2},
      ),
      (command: 'edit.delete', params: const <String, Object?>{}),
      (command: 'edit.refuse', params: const <String, Object?>{}),
      (command: 'view.rulers', params: const <String, Object?>{}),
    ], label: 'Make and delete');
    expect(transactions, <String>['Make and delete']);
    expect(outcome.ok, isFalse);
    expect(outcome.error, contains('step 2'));
    expect(log, <String>['rect 1.0x2.0', 'delete']);
    expect(rulers, isFalse, reason: 'nothing runs after the failing step');
  });

  test('describe lists every command with its state', () {
    final described = {
      for (final command in registry.describe()) command['id']: command,
    };
    expect(described['edit.delete']!['enabled'], isFalse);
    expect(described['edit.delete']!['disabledReason'], 'nothing is selected');
    expect(described['view.rulers']!['checked'], isFalse);
    expect((described['shape.rectangle']!['params'] as List).length, 5);
  });

  test('key bindings run the command, and a disabled one swallows the key', () {
    var bindings = registry.keyBindings();
    expect(bindings.containsKey(const KeyGesture(0x2E)), isTrue);
    expect(bindings[const KeyGesture(0x2E)], isNull);
    selected = true;
    bindings = registry.keyBindings();
    bindings[const KeyGesture(0x08)]!();
    expect(log, <String>['delete']);
  });

  test('of two commands on one key, the one that can run gets it', () {
    final shared = CommandRegistry()
      ..register(CommandSpec(
        id: 'object.alignBottom',
        label: 'Align bottom',
        shortcut: const KeyGesture(0x42),
        enabled: (_) => selected,
        run: (_) => log.add('align'),
      ))
      ..register(CommandSpec(
        id: 'tool.pen',
        label: 'Pen',
        shortcut: const KeyGesture(0x42),
        run: (_) => log.add('pen'),
      ));
    shared.keyBindings()[const KeyGesture(0x42)]!();
    selected = true;
    shared.keyBindings()[const KeyGesture(0x42)]!();
    expect(log, <String>['pen', 'align']);
  });

  group('menus from command ids', () {
    const List<SubmenuSpec> menus = <SubmenuSpec>[
      SubmenuSpec('Edit', <MenuSpecEntry>[
        CommandItem('edit.delete'),
        MenuSeparator(),
        CommandItem('page.insert', label: 'Insert page...'),
      ]),
      SubmenuSpec('View', <MenuSpecEntry>[
        CommandItem('view.rulers'),
        SubmenuSpec('Zoom', <MenuSpecEntry>[CommandItem('view.zoomIn')]),
      ]),
    ];

    test('a planned command shows, disabled', () {
      final bar = MenuBuilder(registry).bar(menus);
      final insert = bar.first.children.last as PlatformMenuItem;
      expect(insert.label, 'Insert page...');
      expect(insert.onSelected, isNull);
    });

    test('a row runs its command through the registry', () {
      final bar = MenuBuilder(registry).bar(menus);
      final rulersItem = bar.last.children.first as PlatformMenuItem;
      expect(rulersItem.checked, isFalse);
      rulersItem.onSelected!();
      expect(rulers, isTrue);
    });

    test('flatten tells implemented rows from planned ones, with paths', () {
      final rows = MenuBuilder(registry).flatten(menus);
      expect(rows.map((r) => r.command),
          <String>['edit.delete', 'page.insert', 'view.rulers', 'view.zoomIn']);
      expect(rows.where((r) => r.registered).length, 2);
      expect(rows.last.path, <String>['View', 'Zoom']);
    });
  });
}
