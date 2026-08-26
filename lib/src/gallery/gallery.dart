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
import '../text/shaper.dart' show TextDirection;
import '../widgets/badge.dart';
import '../widgets/basic.dart';
import '../widgets/calendar.dart';
import '../widgets/combo_box.dart';
import '../widgets/controls.dart';
import '../widgets/data_grid.dart';
import '../widgets/directionality.dart';
import '../widgets/expander.dart';
import '../widgets/focus.dart';
import '../widgets/focus_scope.dart';
import '../widgets/icon.dart';
import '../widgets/icon_button.dart';
import '../widgets/info_bar.dart';
import '../widgets/list_box.dart';
import '../widgets/number_box.dart';
import '../widgets/phosphor_icons.dart';
import '../widgets/tabs.dart';
import '../widgets/theme.dart';
import '../widgets/toolbar.dart';
import '../widgets/tree_view.dart';
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
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Dart UI Gallery',
                    style: widget.theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: Spacing.md),
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
                      const SizedBox(width: Spacing.sm),
                      const Button(label: 'Disabled'),
                      const SizedBox(width: Spacing.sm),
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
                  const SizedBox(height: Spacing.sm),
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
                      const SizedBox(width: Spacing.md),
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
                  const SizedBox(height: Spacing.sm),
                  Row(
                    children: <Widget>[
                      for (final String option in <String>[
                        'Low',
                        'Medium',
                        'High'
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: Spacing.lg),
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
                  const SizedBox(height: Spacing.sm),
                  Slider(
                    value: model.sliderValue,
                    onChanged: (double value) {
                      model.sliderValue = value;
                      _refresh();
                    },
                  ),
                  const SizedBox(height: Spacing.xs),
                  ProgressBar(value: model.sliderValue),
                  const SizedBox(height: Spacing.sm),
                  TextField(controller: model.text, label: 'Name'),
                  const SizedBox(height: Spacing.xs),
                  PasswordField(controller: model.password, label: 'Secret'),
                  const SizedBox(height: Spacing.sm),
                  SizedBox(
                    // Whole rows: a list that ends mid-row looks like a bug in
                    // the scroll position rather than the edge of a box.
                    height: widget.theme.effectiveRowHeight * 4 + 2,
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
                  const SizedBox(height: Spacing.sm),
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
                        padding: const EdgeInsets.all(Spacing.sm),
                        child: Text(
                          model.lastContextCommand.isEmpty
                              ? 'Right-click here (or in a field)'
                              : 'Context command: ${model.lastContextCommand}',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
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

// ---------------------------------------------------------------------------
// The data gallery: the second page
// ---------------------------------------------------------------------------

/// State for the data-centric controls page: tree, grid, dates, numbers,
/// notifications and the small visual primitives.
///
/// A separate page rather than more rows in [Gallery], because that widget is
/// a golden-gate artifact: appending to it would reflow every reference
/// image for a change that has nothing to do with the controls already
/// pictured.
final class DataGalleryModel {
  DataGalleryModel();

  final Set<Object> expandedNodes = <Object>{'src'};
  Object? selectedNode;
  Set<int> selectedRows = <int>{0};
  DataGridSort? sort;
  DateTime? date;
  double amount = 10;
  bool infoBarVisible = true;
  String tags = 'alpha, beta';

  final ToastController toasts = ToastController();
  final ScrollPosition treeScroll = ScrollPosition();
  final ScrollPosition gridScroll = ScrollPosition();

  /// Deliberately large, for the same reason [GalleryModel.listItemCount] is.
  static const int gridRowCount = 10000;

  static const List<TreeNode> treeNodes = <TreeNode>[
    TreeNode(label: 'src', children: <TreeNode>[
      TreeNode(label: 'widgets', children: <TreeNode>[
        TreeNode(label: 'tree_view.dart'),
        TreeNode(label: 'data_grid.dart'),
      ]),
      TreeNode(label: 'rendering'),
    ]),
    TreeNode(label: 'test', hasChildren: true),
    TreeNode(label: 'pubspec.yaml'),
  ];
}

/// The data-controls page, parameterized only by its theme and model.
final class DataGallery extends StatefulWidget {
  const DataGallery({
    super.key,
    required this.model,
    this.theme = ThemeData.neutralLight,
    this.textDirection = TextDirection.leftToRight,
  });

  final DataGalleryModel model;
  final ThemeData theme;

  /// Published to the subtree: the tree and grid are direction-aware, and a
  /// page that did not state a direction would throw on the first
  /// `Directionality.of`.
  final TextDirection textDirection;

  @override
  State<DataGallery> createState() => DataGalleryState();
}

final class DataGalleryState extends State<DataGallery> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'data-gallery');

  /// Exposed for keyboard-only tests, exactly like [GalleryState.scope].
  FocusScopeNode get scope => _scope;

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DataGalleryModel model = widget.model;
    return Directionality(
      textDirection: widget.textDirection,
      child: Theme(
        data: widget.theme,
        child: FocusScope(
          node: _scope,
          child: ToastHost(
            controller: model.toasts,
            child: ColoredBox(
              color: widget.theme.surface,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Data controls',
                      style: widget.theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: Spacing.md),
                    SizedBox(
                      height: widget.theme.effectiveRowHeight * 4 + 2,
                      child: TreeView(
                        nodes: DataGalleryModel.treeNodes,
                        controller: model.treeScroll,
                        expandedIds: model.expandedNodes,
                        selectedId: model.selectedNode,
                        onToggle: (TreeNode node, bool expanded) {
                          if (expanded) {
                            model.expandedNodes.add(node.identity);
                          } else {
                            model.expandedNodes.remove(node.identity);
                          }
                          _refresh();
                        },
                        onSelected: (TreeNode node) {
                          model.selectedNode = node.identity;
                          _refresh();
                        },
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    SizedBox(
                      height: widget.theme.effectiveControlHeight +
                          widget.theme.effectiveRowHeight * 3 +
                          2,
                      child: DataGrid(
                        columns: const <DataGridColumn>[
                          DataGridColumn(title: 'Name', width: 140),
                          DataGridColumn(title: 'Size', width: 90),
                          DataGridColumn(
                            title: 'Kind',
                            width: 100,
                            sortable: false,
                          ),
                        ],
                        rowCount: DataGalleryModel.gridRowCount,
                        controller: model.gridScroll,
                        sort: model.sort,
                        onSortChanged: (DataGridSort sort) {
                          model.sort = sort;
                          _refresh();
                        },
                        selectionMode: DataGridSelectionMode.multiple,
                        selectedRows: model.selectedRows,
                        onSelectionChanged: (Set<int> rows) {
                          model.selectedRows = rows;
                          _refresh();
                        },
                        cellBuilder:
                            (BuildContext context, int row, int column) =>
                                Text(switch (column) {
                          0 => 'file_$row.dart',
                          1 => '${(row + 1) * 3} KB',
                          _ => 'Dart source',
                        }),
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        NumberBox(
                          value: model.amount,
                          min: 0,
                          max: 100,
                          onChanged: (double value) {
                            model.amount = value;
                            _refresh();
                          },
                        ),
                        const SizedBox(width: Spacing.sm),
                        DatePicker(
                          selectedDate: model.date,
                          onDateSelected: (DateTime date) {
                            model.date = date;
                            model.toasts.show(
                              'Date selected',
                              severity: InfoBarSeverity.success,
                              duration: null,
                            );
                            _refresh();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.sm),
                    if (model.infoBarVisible)
                      InfoBar(
                        title: 'Heads up',
                        message: 'The grid holds ten thousand rows.',
                        severity: InfoBarSeverity.warning,
                        onClose: () {
                          model.infoBarVisible = false;
                          _refresh();
                        },
                      ),
                    const SizedBox(height: Spacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        const Badge(label: '3'),
                        const SizedBox(width: Spacing.sm),
                        for (final String tag in model.tags.split(', '))
                          Padding(
                            padding: const EdgeInsets.only(right: Spacing.sm),
                            child: Chip(
                              label: tag,
                              onDeleted: () {
                                model.tags = model.tags
                                    .split(', ')
                                    .where((String t) => t != tag)
                                    .join(', ');
                                _refresh();
                              },
                            ),
                          ),
                        const Avatar(initials: 'DU'),
                      ],
                    ),
                    const SizedBox(height: Spacing.sm),
                    const Card(child: Text('Card content')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The chrome gallery: the third page
// ---------------------------------------------------------------------------

/// State for the application-chrome controls: bars, tabs, drop-downs,
/// disclosure and the date grid.
///
/// A third page for the same reason [DataGalleryModel] is a second one: these
/// controls were the ones no page pictured, which is exactly how a toolbar
/// ended up 60 px tall in a theme whose controls are 28, and how a combo box
/// kept a 1995 solid triangle for a chevron. A control with no picture has no
/// design review.
final class ChromeGalleryModel {
  ChromeGalleryModel();

  String unit = 'mm';
  int tab = 0;
  bool expanded = true;
  bool bold = true;
  bool italic = false;
  DateTime month = DateTime(2026, 3);
  DateTime? day = DateTime(2026, 3, 18);

  final ComboBoxOverlay overlay = ComboBoxOverlay();
}

/// The chrome page: a toolbar, a tab strip, a drop-down, an expander, a menu
/// and a calendar, at whatever theme and density the caller passes.
final class ChromeGallery extends StatefulWidget {
  const ChromeGallery({
    super.key,
    required this.model,
    this.theme = ThemeData.neutralLight,
  });

  final ChromeGalleryModel model;
  final ThemeData theme;

  @override
  State<ChromeGallery> createState() => ChromeGalleryState();
}

final class ChromeGalleryState extends State<ChromeGallery> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'chrome-gallery');

  /// Exposed for keyboard-only tests, exactly like [GalleryState.scope].
  FocusScopeNode get scope => _scope;

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChromeGalleryModel model = widget.model;
    final ThemeData theme = widget.theme;
    return Directionality(
      textDirection: TextDirection.leftToRight,
      child: Theme(
        data: theme,
        child: FocusScope(
          node: _scope,
          child: ComboBoxScope(
            overlay: model.overlay,
            child: ColoredBox(
              color: theme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Toolbar(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        ToolbarGroup(
                          children: <Widget>[
                            IconButton(
                              icon: const Icon(PhosphorIcons.filePlus),
                              tooltip: 'New',
                              onPressed: _refresh,
                            ),
                            IconButton(
                              icon: const Icon(PhosphorIcons.folderOpen),
                              tooltip: 'Open',
                              onPressed: _refresh,
                            ),
                            const IconButton(
                              icon: Icon(PhosphorIcons.floppyDisk),
                              tooltip: 'Save',
                              onPressed: null,
                            ),
                          ],
                        ),
                        const ToolbarDivider(),
                        ToolbarGroup(
                          children: <Widget>[
                            IconButton(
                              icon: const Icon(PhosphorIcons.textB),
                              tooltip: 'Bold',
                              isSelected: model.bold,
                              onPressed: () {
                                model.bold = !model.bold;
                                _refresh();
                              },
                            ),
                            IconButton(
                              icon: const Icon(PhosphorIcons.textItalic),
                              tooltip: 'Italic',
                              isSelected: model.italic,
                              onPressed: () {
                                model.italic = !model.italic;
                                _refresh();
                              },
                            ),
                          ],
                        ),
                        const ToolbarDivider(),
                        SizedBox(
                          width: 96,
                          child: ComboBox<String>(
                            label: 'Units',
                            items: const <ComboBoxItem<String>>[
                              ComboBoxItem<String>(value: 'mm', label: 'mm'),
                              ComboBoxItem<String>(value: 'cm', label: 'cm'),
                              ComboBoxItem<String>(value: 'in', label: 'in'),
                            ],
                            value: model.unit,
                            onChanged: (String value) {
                              model.unit = value;
                              _refresh();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: theme.effectiveControlHeight * 3,
                    child: Tabs(
                      selectedIndex: model.tab,
                      onSelected: (int index) {
                        model.tab = index;
                        _refresh();
                      },
                      tabs: const <TabItem>[
                        TabItem(
                            label: 'Document', content: _TabBody('Document')),
                        TabItem(label: 'Page', content: _TabBody('Page')),
                        TabItem(label: 'Export', content: _TabBody('Export')),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(Spacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expander(
                          header: 'Appearance',
                          expanded: model.expanded,
                          onExpandedChanged: (bool value) {
                            model.expanded = value;
                            _refresh();
                          },
                          content: const Padding(
                            padding: EdgeInsets.symmetric(
                              vertical: Spacing.sm,
                            ),
                            child: Text('Everything inside a disclosure.'),
                          ),
                        ),
                        const SizedBox(height: Spacing.md),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Menu(items: <MenuItem>[
                              MenuItem(
                                label: 'Undo',
                                shortcut: 'Ctrl+Z',
                                onSelected: _refresh,
                              ),
                              MenuItem(
                                label: 'Redo',
                                shortcut: 'Ctrl+Y',
                                onSelected: _refresh,
                              ),
                              const MenuItem.separator(),
                              const MenuItem(label: 'Paste', enabled: false),
                            ]),
                            const SizedBox(width: Spacing.lg),
                            Calendar(
                              initialMonth: model.month,
                              selectedDate: model.day,
                              today: DateTime(2026, 3, 23),
                              onDateSelected: (DateTime date) {
                                model.day = date;
                                _refresh();
                              },
                            ),
                          ],
                        ),
                      ],
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
}

/// The body of one chrome-gallery tab: enough to see that the strip switched.
final class _TabBody extends StatelessWidget {
  const _TabBody(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Text('$name settings'),
      );
}
