import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// A window with a system menu bar, recording what it was given.
final class _MacWindow implements WindowController {
  @override
  HiddenTitleBarWindow? get hiddenTitleBar => null;

  _MacWindow({this.hasNativeMenuBar = true});

  @override
  final bool hasNativeMenuBar;

  List<NativeMenu>? menus;
  void Function(int id)? onSelected;
  int installs = 0;

  @override
  void setNativeMenuBar(
    List<NativeMenu>? menus,
    void Function(int id) onSelected,
  ) {
    installs++;
    this.menus = menus;
    this.onSelected = onSelected;
  }

  /// The item labelled [label], anywhere in the installed menus.
  NativeMenuItem item(String label) {
    NativeMenuItem? found;
    void walk(List<NativeMenuEntry> entries) {
      for (final NativeMenuEntry entry in entries) {
        if (entry is NativeMenuItem && entry.label == label) found = entry;
        if (entry is NativeMenu) walk(entry.children);
      }
    }

    walk(menus ?? const <NativeMenu>[]);
    return found ?? (throw StateError('no item $label'));
  }

  @override
  void close() {}

  @override
  void minimize() {}

  @override
  void setTitle(String title) {}

  @override
  void setCursor(SystemCursor cursor) {}

  @override
  Offset toScreen(Offset local) => local;

  @override
  Future<ChildWindow> openChildWindow({
    required Widget child,
    String? title,
    Size size = const Size(320, 480),
    Offset? position,
    void Function()? onClosed,
  }) =>
      throw UnimplementedError();
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  late BuildOwner owner;
  var saved = 0;
  var rulers = false;

  List<PlatformMenu> menus() => <PlatformMenu>[
        PlatformMenu(label: 'File', children: <PlatformMenuEntry>[
          PlatformMenuItem(
            label: 'Save',
            shortcut: const KeyGesture(0x53, command: true),
            onSelected: () => saved++,
          ),
          const PlatformMenuItem(label: 'Export', onSelected: null),
          const PlatformMenuDivider(),
          PlatformMenu(label: 'View', children: <PlatformMenuEntry>[
            PlatformMenuItem(
              label: 'Rulers',
              checked: rulers,
              onSelected: () => rulers = !rulers,
            ),
          ]),
        ]),
      ];

  void mount(WindowController window, {required bool native}) {
    owner.updateRoot(PopupScope(
      host: InTreePopupHost(),
      child: Theme(
        data: ThemeData.studioDark,
        child: Directionality(
          textDirection: TextDirection.leftToRight,
          child: WindowScope(
            controller: window,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                PlatformMenuBar(menus: menus(), native: native, height: 28),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      ),
    ));
    owner.buildScope();
    owner.pipelineOwner.drawFrame(DisplayList());
  }

  bool hasInWindowBar() {
    var found = false;
    void walk(RenderBox node) {
      if (node is RenderMenuPanel) found = true;
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  setUp(() {
    saved = 0;
    rulers = false;
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(400, 300)),
      ),
    );
  });
  tearDown(() => owner.dispose());

  test('on a Mac the menus go to the system bar and take no room', () {
    final _MacWindow window = _MacWindow();
    mount(window, native: true);

    expect(hasInWindowBar(), isFalse);
    expect(window.menus!.single.label, 'File');
    final NativeMenuItem save = window.item('Save');
    expect(save.key, 0x53);
    expect(save.modifiers, <KeyModifier>{KeyModifier.meta});
    expect(window.item('Export').enabled, isFalse);

    window.onSelected!(save.id);
    expect(saved, 1);
    window.onSelected!(window.item('Export').id);
    expect(saved, 1);
  });

  test('a rebuild sends what is checked now', () {
    final _MacWindow window = _MacWindow();
    mount(window, native: true);
    expect(window.item('Rulers').checked, isFalse);

    window.onSelected!(window.item('Rulers').id);
    mount(window, native: true);
    expect(rulers, isTrue);
    expect(window.item('Rulers').checked, isTrue);
  });

  test('turning the system bar off takes the menus out of it', () {
    final _MacWindow window = _MacWindow();
    mount(window, native: true);
    expect(window.menus, isNotNull);

    mount(window, native: false);
    expect(window.menus, isNull);
    expect(hasInWindowBar(), isTrue);
  });

  test('without a system bar the menus are drawn in the window', () {
    final _MacWindow window = _MacWindow(hasNativeMenuBar: false);
    mount(window, native: true);
    expect(window.installs, 0);
    expect(hasInWindowBar(), isTrue);
  });
}
