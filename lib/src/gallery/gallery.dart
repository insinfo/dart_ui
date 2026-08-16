/// The control gallery.
///
/// This is a gate artifact, not a demo. Section 24's gate asks for the same
/// gallery to run headless and on the Win32 CPU backend, and that pairing is
/// the point: if one widget tree produces one display list, and that display
/// list rasterizes identically with no window and with a real one, then the
/// core is genuinely above the platform rather than merely compiling on it.
///
/// So the gallery is a library, not a `main`. A test mounts it, a benchmark
/// mounts it, and the Win32 example mounts it - all the same tree.
library;

import '../geometry/size.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart';
import '../layout/render_viewport.dart';
import '../widgets/basic.dart';
import '../widgets/controls.dart';
import '../widgets/focus.dart';
import '../widgets/focus_scope.dart';
import '../widgets/list_box.dart';
import '../widgets/theme.dart';
import '../widgets/widget.dart';

/// Everything the gallery lets the user change.
///
/// Held outside the widget so a test can drive the gallery without reaching
/// into private state: set a field, rebuild, assert on the frame.
final class GalleryModel {
  GalleryModel();

  bool checked = false;
  bool tristate = false;
  bool switched = false;
  String radioGroup = 'medium';
  double sliderValue = 0.35;
  int listSelection = 0;
  int pressCount = 0;
  bool dialogVisible = false;
  bool menuVisible = false;
  String lastMenuCommand = '';

  /// The last command chosen from a *context* menu, so the gallery has
  /// something to show for a right-click that a screenshot can also prove.
  String lastContextCommand = '';

  /// The controller the gallery's context menus share.
  ///
  /// Held on the model rather than inside the widget for the same reason every
  /// other piece of state is: a test opens the menu through this and asserts on
  /// the frame, with no pointer anywhere.
  final ContextMenuController contextMenu = ContextMenuController();

  final TextEditingController text = TextEditingController('Edit me');
  final TextEditingController password = TextEditingController('hunter2');
  final ScrollPosition scroll = ScrollPosition();
  final ScrollPosition listScroll = ScrollPosition();

  /// The list is deliberately enormous: virtualization that only works for a
  /// hundred items is not virtualization.
  static const int listItemCount = 10000;
}

/// The gallery, parameterized only by its theme and model.
final class Gallery extends StatefulWidget {
  const Gallery({
    super.key,
    required this.model,
    this.theme = ThemeData.neutralLight,
  });

  final GalleryModel model;
  final ThemeData theme;

  @override
  State<Gallery> createState() => GalleryState();
}

final class GalleryState extends State<Gallery> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'gallery');

  /// The scope every control in the gallery attaches to. Exposed so a
  /// keyboard-only test can walk the tab ring without simulating a window.
  FocusScopeNode get scope => _scope;

  void _refresh() => setState(() {});

  void _runContextCommand(String name) {
    widget.model.lastContextCommand = name;
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final GalleryModel model = widget.model;
    return Theme(
      data: widget.theme,
      child: FocusScope(
        node: _scope,
        // Inside the focus scope, so the popup's own node joins the gallery's
        // traversal region rather than the owner's root; and around everything
        // else, because the area this wraps is exactly the rectangle a menu is
        // allowed to be placed in. A scope around half the window would flip a
        // menu against that half's edge.
        child: ContextMenuScope(
          controller: model.contextMenu,
          child: ColoredBox(
            color: widget.theme.surface,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Dart UI Gallery'),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Button(
                        label: 'Press ${model.pressCount}',
                        isDefault: true,
                        onPressed: () {
                          model.pressCount++;
                          _refresh();
                        },
                      ),
                      const SizedBox(width: 8),
                      const Button(label: 'Disabled'),
                      const SizedBox(width: 8),
                      ToggleButton(
                        label: 'Toggle',
                        value: model.switched,
                        onChanged: (bool value) {
                          model.switched = value;
                          _refresh();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      CheckBox(
                        label: 'Check',
                        value: model.tristate ? null : model.checked,
                        tristate: model.tristate,
                        onChanged: (bool value) {
                          model.checked = value;
                          _refresh();
                        },
                      ),
                      const SizedBox(width: 12),
                      Switch(
                        label: 'Switch',
                        value: model.switched,
                        onChanged: (bool value) {
                          model.switched = value;
                          _refresh();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      for (final String option in <String>[
                        'Low',
                        'Medium',
                        'High'
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Radio<String>(
                            label: option,
                            value: option.toLowerCase(),
                            groupValue: model.radioGroup,
                            onChanged: (String value) {
                              model.radioGroup = value;
                              _refresh();
                            },
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Slider(
                    value: model.sliderValue,
                    onChanged: (double value) {
                      model.sliderValue = value;
                      _refresh();
                    },
                  ),
                  const SizedBox(height: 4),
                  ProgressBar(value: model.sliderValue),
                  const SizedBox(height: 6),
                  TextField(controller: model.text, label: 'Name'),
                  const SizedBox(height: 4),
                  PasswordField(controller: model.password, label: 'Secret'),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 90,
                    child: ListBox(
                      itemCount: GalleryModel.listItemCount,
                      controller: model.listScroll,
                      selectedIndex: model.listSelection,
                      onSelected: (int index) {
                        model.listSelection = index;
                        _refresh();
                      },
                      itemBuilder: (BuildContext context, int index) =>
                          Text('Item $index'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // The context-menu demonstration: something to right-click that
                  // is not a text field, so the generic machinery is exercised by
                  // hand and not only through [TextField]'s own menu.
                  ContextMenuRegion(
                    itemsBuilder: () => <MenuItem>[
                      MenuItem(
                        label: 'Refresh',
                        shortcut: 'F5',
                        onSelected: () => _runContextCommand('Refresh'),
                      ),
                      MenuItem(
                        label: 'Duplicate',
                        onSelected: () => _runContextCommand('Duplicate'),
                      ),
                      const MenuItem.separator(),
                      const MenuItem(
                        label: 'Delete',
                        enabled: false,
                        disabledReason: 'nothing in this panel is selected',
                      ),
                    ],
                    child: ColoredBox(
                      color: widget.theme.surfaceAlternate,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          model.lastContextCommand.isEmpty
                              ? 'Right-click here (or in a field)'
                              : 'Context command: ${model.lastContextCommand}',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (model.menuVisible)
                    Menu(items: <MenuItem>[
                      MenuItem(
                        label: 'New',
                        onSelected: () {
                          model.lastMenuCommand = 'New';
                          _refresh();
                        },
                      ),
                      MenuItem(
                        label: 'Open',
                        onSelected: () {
                          model.lastMenuCommand = 'Open';
                          _refresh();
                        },
                      ),
                      const MenuItem.separator(),
                      const MenuItem(label: 'Locked', enabled: false),
                    ]),
                  if (model.dialogVisible)
                    Dialog(
                      title: 'Confirm',
                      onDismiss: () {
                        model.dialogVisible = false;
                        _refresh();
                      },
                      child: Button(
                        label: 'Close',
                        onPressed: () {
                          model.dialogVisible = false;
                          _refresh();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }
}

/// A scrolling gallery variant, used to exercise the viewport and scrollbar.
final class ScrollingGallery extends StatelessWidget {
  const ScrollingGallery({
    super.key,
    required this.model,
    this.theme = ThemeData.neutralLight,
  });

  final GalleryModel model;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Theme(
        data: theme,
        child: ScrollViewer(
          controller: model.scroll,
          child: Gallery(model: model, theme: theme),
        ),
      );
}

/// The size the gallery is designed for; goldens use it so an unrelated layout
/// change cannot quietly reflow every reference image.
const Size galleryDesignSize = Size(360, 460);
