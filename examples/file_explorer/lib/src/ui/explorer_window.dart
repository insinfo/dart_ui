/// The window, laid out as Files draws Windows 11's File Explorer: tabs on
/// the Mica strip where the title bar was; under them, on a lighter layer,
/// the address row with its pill; then the sidebar, and beside it the
/// command bar and the items, each a rounded card, over the status line.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_commands.dart';
import '../engine/explorer_host.dart';
import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/location.dart';
import 'bar_button.dart';
import 'command_icons.dart';
import 'details_pane.dart';
import 'folder_view.dart';
import 'home_page.dart';
import 'menus.dart';
import 'sidebar.dart';

/// The explorer window.
class ExplorerWindow extends StatefulWidget {
  const ExplorerWindow({
    super.key,
    required this.model,
    this.onReady,
    this.onClose,
  });

  final ExplorerModel model;

  /// Told when the commands are registered - where a test reaches them.
  final void Function(ExplorerWindowState window)? onReady;

  /// The last tab was closed.
  final void Function()? onClose;

  @override
  State<ExplorerWindow> createState() => ExplorerWindowState();
}

class ExplorerWindowState extends State<ExplorerWindow>
    implements ExplorerHost {
  final CommandRegistry registry = CommandRegistry();
  late final MenuBuilder menus = MenuBuilder(registry, iconOf: commandIcon);
  final BreadcrumbController address = BreadcrumbController();
  final TextEditingController search = TextEditingController('');
  final FocusNode searchFocus = FocusNode(debugLabel: 'Search');
  final TextEditingController rename = TextEditingController('');
  final FocusNode renameFocus = FocusNode(debugLabel: 'Rename');
  String? _renameSeeded;

  /// Subfolders of the address bar's steps, read when a chevron opens.
  final Map<String, List<FileEntry>> _subfolders = <String, List<FileEntry>>{};

  ExplorerModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    registerExplorerCommands(registry, model, this);
    model.addListener(_changed);
    renameFocus.addListener(_renameFocusChanged);
    unawaited(model.refresh());
    widget.onReady?.call(this);
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    renameFocus
      ..removeListener(_renameFocusChanged)
      ..dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // --- ExplorerHost -------------------------------------------------------------

  @override
  void focusAddress() => address.edit();

  /// Whether the address pill is a search box now - Files' omnibar.
  bool _searching = false;

  @override
  void focusSearch() {
    setState(() => _searching = true);
    search.selectAll();
    scheduleMicrotask(searchFocus.requestFocus);
  }

  void _endSearch() {
    if (!_searching) return;
    setState(() => _searching = false);
  }

  @override
  void showProperties(List<FileEntry> entries) {
    model.detailsPane = true;
    model.notify();
  }

  @override
  void copyText(String text) {
    unawaited(ClipboardScope.of(context).writeText(text).catchError((_) {}));
  }

  @override
  void closeWindow() => widget.onClose?.call();

  // --- rename in place ------------------------------------------------------

  /// Clicking away from the field commits the name, as in Explorer.
  void _renameFocusChanged(FocusNode node) {
    final String? path = model.tab.renaming;
    if (!node.hasPrimaryFocus && path != null && _renameSeeded == path) {
      unawaited(model.rename(path, rename.value));
    }
  }

  Widget _renameField(FileEntry entry) {
    if (_renameSeeded != entry.path) {
      _renameSeeded = entry.path;
      rename.value = entry.name;
      // The name without its extension, as Explorer selects it.
      rename.setSelection(
          0, entry.isDirectory ? entry.name.length : entry.stem.length);
      scheduleMicrotask(renameFocus.requestFocus);
    }
    return CallbackShortcuts(
      bindings: <KeyGesture, void Function()?>{
        const KeyGesture(logicalKeyEscape): () {
          _renameSeeded = null;
          model.cancelRename();
        },
      },
      child: SizedBox(
        height: 26,
        child: TextField(
          controller: rename,
          focusNode: renameFocus,
          onSubmitted: (String name) {
            _renameSeeded = null;
            unawaited(model.rename(entry.path, name));
          },
        ),
      ),
    );
  }

  // --- the address -------------------------------------------------------------

  /// The breadcrumb steps: from the nearest known folder - "Documents >
  /// Projects", as Windows writes it - or from This PC.
  List<(String, BreadcrumbItem)> _steps() {
    final Location at = model.tab.location;
    final String? folder = model.folderOf(at);
    if (at is HomeLocation) {
      return <(String, BreadcrumbItem)>[
        ('::home', BreadcrumbItem(label: model.strings.home)),
      ];
    }
    if (folder == null) {
      return <(String, BreadcrumbItem)>[
        ('::thispc', BreadcrumbItem(label: model.strings.thisPc)),
      ];
    }
    final List<String> chain = model.fs.ancestry(folder);
    var start = 0;
    for (var i = chain.length - 1; i >= 0; i--) {
      if (model.placeAt(chain[i]) != null &&
          chain[i] != model.places[Place.home]) {
        start = i;
        break;
      }
    }
    final List<(String, BreadcrumbItem)> steps = <(String, BreadcrumbItem)>[
      if (start == 0) ('::thispc', BreadcrumbItem(label: model.strings.thisPc)),
      for (var i = start; i < chain.length; i++)
        (
          chain[i],
          BreadcrumbItem(
            label: model.placeAt(chain[i]) != null &&
                    chain[i] != model.places[Place.home]
                ? model.placeName(model.placeAt(chain[i])!)
                : _volumeLabel(chain[i]) ?? model.fs.nameOf(chain[i]),
          ),
        ),
    ];
    if (at is SearchLocation) {
      steps.add((
        '::search',
        BreadcrumbItem(
            label:
                '${model.strings.searchResults} ${model.titleOf(FolderLocation(folder))}'),
      ));
    }
    return steps;
  }

  String? _volumeLabel(String path) {
    for (final Volume v in model.volumes) {
      if (v.path == path) return v.label;
    }
    return null;
  }

  List<Widget> _subfolderMenu(String path) {
    if (path.startsWith('::')) {
      if (path != '::thispc') return const <Widget>[];
      return <Widget>[
        for (final Volume v in model.volumes)
          MenuItemButton(
            leadingIcon: const Icon(FluentIcons.hardDrive),
            onPressed: () =>
                registry.execute('nav.go', <String, Object?>{'path': v.path}),
            child: Text(v.label),
          ),
      ];
    }
    final List<FileEntry>? known = _subfolders[path];
    if (known == null) {
      unawaited(model.fs.list(path).then((List<FileEntry> all) {
        if (!mounted) return;
        setState(() => _subfolders[path] = <FileEntry>[
              for (final FileEntry e in all)
                if (e.isDirectory && (model.showHidden || !e.isHidden)) e,
            ]..sort((FileEntry a, FileEntry b) =>
                a.name.toLowerCase().compareTo(b.name.toLowerCase())));
      }, onError: (Object _) {}));
      return const <Widget>[
        MenuItemButton(onPressed: null, child: Text('…')),
      ];
    }
    return <Widget>[
      for (final FileEntry e in known)
        MenuItemButton(
          leadingIcon: const Icon(FluentIcons.folder),
          onPressed: () =>
              registry.execute('nav.go', <String, Object?>{'path': e.path}),
          child: Text(e.name),
        ),
    ];
  }

  IconData _locationIcon(Location at) => switch (at) {
        HomeLocation() => FluentIcons.home,
        ThisPcLocation() => FluentIcons.desktop,
        SearchLocation() => FluentIcons.search,
        FolderLocation(:final String path) => model.placeAt(path) == null
            ? FluentIcons.folder
            : placeIcon(model.placeAt(path)).$1,
      };

  // --- layout ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: registry.keyBindings(),
      child: ColoredBox(
        color: theme.surfaceBase,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _tabStrip(theme),
            Expanded(
              child: ColoredBox(
                color: theme.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _addressRow(theme),
                    Expanded(child: _body(theme)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The tabs, where the title bar was: clear of the window buttons the
  /// platform keeps there, and with the empty strip after them a handle that
  /// moves the window.
  Widget _tabStrip(ThemeData theme) {
    final HiddenTitleBarWindow? bar = WindowScope.of(context)?.hiddenTitleBar;
    if (bar == null) return _tabs(theme, leading: 8, height: 40);
    return ValueListenableBuilder<Rect>(
      valueListenable: bar.systemButtons,
      builder: (BuildContext context, Rect buttons, _) => WindowDragArea(
        child: _tabs(
          theme,
          leading: buttons.isEmpty ? 8 : buttons.right + 14,
          height: bar.titleBarHeight > 40 ? bar.titleBarHeight : 40,
        ),
      ),
    );
  }

  Widget _tabs(ThemeData theme,
          {required double leading, required double height}) =>
      SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(left: leading, top: 6),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: DocumentTabStrip(
              style: DocumentTabStyle.raised,
              height: 34,
              selectedColor: theme.surface,
              tabs: <DocumentTab>[
                for (var i = 0; i < model.tabs.length; i++)
                  DocumentTab(
                    id: model.tabs[i],
                    label: model.titleOf(model.tabs[i].location),
                    icon: _locationIcon(model.tabs[i].location),
                    tooltip: model.folderOf(model.tabs[i].location),
                  ),
              ],
              selectedIndex: model.activeIndex,
              onSelected: (int i) =>
                  registry.execute('tab.select', <String, Object?>{'index': i}),
              onClosed: (int i) =>
                  registry.execute('tab.close', <String, Object?>{'index': i}),
              onAdd: () => registry.execute('tab.new'),
              addTooltip: model.strings.newTab,
            ),
          ),
        ),
      );

  Widget _addressRow(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
        child: SizedBox(
          height: 40,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              for (final String id in const <String>[
                'nav.back',
                'nav.forward',
                'nav.up',
                'nav.refresh',
              ])
                BarButton(
                    icon: commandIcon(id)!,
                    registry: registry,
                    command: id,
                    iconSize: 18),
              const SizedBox(width: 8),
              Expanded(
                  child: _searching ? _searchPill(theme) : _omnibar(theme)),
            ],
          ),
        ),
      );

  /// The address as a pill, with the search button at its end.
  Widget _omnibar(ThemeData theme) {
    final List<(String, BreadcrumbItem)> steps = _steps();
    return BreadcrumbBar(
      controller: address,
      height: 36,
      radius: 18,
      leading: Icon(_locationIcon(model.tab.location),
          color: theme.accent, size: 16),
      items: <BreadcrumbItem>[for (final s in steps) s.$2],
      onSelected: (int i) {
        final String id = steps[i].$1;
        switch (id) {
          case '::home':
            registry.execute('nav.home');
          case '::thispc':
            registry.execute('nav.thisPc');
          case '::search':
            break;
          default:
            registry.execute('nav.go', <String, Object?>{'path': id});
        }
      },
      childrenMenu: (int i) => _subfolderMenu(steps[i].$1),
      // Home and This PC have no path; the field shows their name.
      editText: model.currentFolder ?? model.titleOf(model.tab.location),
      onSubmitted: (String text) {
        if (text.trim().isEmpty || text == model.titleOf(model.tab.location)) {
          return;
        }
        registry.execute('nav.go', <String, Object?>{'path': text.trim()});
      },
      trailing: BarButton(
        icon: FluentIcons.search,
        registry: registry,
        command: 'nav.focusSearch',
        iconSize: 16,
        compact: true,
      ),
    );
  }

  /// The pill turned into a search box - Ctrl+F, or its search button.
  Widget _searchPill(ThemeData theme) => CallbackShortcuts(
        bindings: <KeyGesture, void Function()?>{
          const KeyGesture(logicalKeyEscape): _endSearch,
        },
        child: SizedBox(
          height: 36,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceAlternate,
              border: BoxBorder(color: theme.accent, width: 1),
              radius: 18,
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Icon(FluentIcons.search,
                      size: 16, color: theme.foregroundSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: search,
                      focusNode: searchFocus,
                      decorated: false,
                      label: '${model.strings.searchIn} '
                          '${model.titleOf(model.tab.location)}',
                      onSubmitted: (String query) => registry.execute(
                          'nav.search', <String, Object?>{'query': query}),
                    ),
                  ),
                  BarButton(
                    icon: FluentIcons.dismiss,
                    tooltip: model.strings.menu('Close'),
                    onTap: _endSearch,
                    iconSize: 14,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _body(ThemeData theme) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (model.navigationPane)
            SizedBox(
              width: 232,
              child: Sidebar(
                model: model,
                registry: registry,
                settingsMenu: () => menus.widgets(settingsMenu(model.strings)),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _card(theme, _commandBar(theme)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(child: _card(theme, _content(theme))),
                        if (model.detailsPane) ...<Widget>[
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 280,
                            child: _card(theme, DetailsPane(model: model)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _statusBar(theme),
                ],
              ),
            ),
          ),
        ],
      );

  /// A rounded white card on the layer - Files' command bar and file area.
  Widget _card(ThemeData theme, Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.borderSubtle, width: 1),
          radius: 8,
        ),
        child: ClipRRect(radius: 8, child: child),
      );

  Widget _commandBar(ThemeData theme) {
    Widget command(String id) =>
        BarButton(icon: commandIcon(id)!, registry: registry, command: id);
    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: SizedBox(width: 1, child: ColoredBox(color: theme.border)),
        );
    final String Function(String) t = model.strings.menu;
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MenuBarButton(
              icon: FluentIcons.addCircle,
              label: t('New'),
              chevron: false,
              menu: () => menus.widgets(kNewMenu),
            ),
            divider(),
            command('file.cut'),
            command('file.copy'),
            command('file.paste'),
            command('file.rename'),
            command('file.delete'),
            command('file.properties'),
            const Spacer(),
            MenuBarButton(
              icon: FluentIcons.arrowSort,
              tooltip: t('Sort'),
              chevron: true,
              menu: () => menus.widgets(kSortMenu),
            ),
            MenuBarButton(
              icon: _viewIcon(),
              tooltip: t('View'),
              chevron: true,
              menu: () => menus.widgets(viewMenu(model.strings)),
            ),
            MenuBarButton(
              icon: FluentIcons.moreHorizontal,
              tooltip: t('See more'),
              menu: () => menus.widgets(kMoreMenu),
            ),
            BarButton(
              icon: FluentIcons.panelRight,
              registry: registry,
              command: 'view.detailsPane',
            ),
          ],
        ),
      ),
    );
  }

  IconData _viewIcon() => switch (model.viewMode) {
        ViewMode.details => FluentIcons.textBulletListLtr,
        ViewMode.list => FluentIcons.list,
        ViewMode.tiles => FluentIcons.grid,
        _ => FluentIcons.gridDots,
      };

  Widget _content(ThemeData theme) => switch (model.tab.location) {
        HomeLocation() => HomePage(model: model, registry: registry),
        ThisPcLocation() => ThisPcPage(model: model, registry: registry),
        _ => ContextMenuArea(
            menuChildren: () => menus.widgets(model.selectedEntries.isEmpty
                ? backgroundMenu(model.strings)
                : kItemMenu),
            child: FolderView(
              model: model,
              registry: registry,
              renameField: _renameField,
              headerMenu: () => menus.widgets(kColumnsMenu),
            ),
          ),
      };

  /// "17 items | 1 item selected", under the file area.
  Widget _statusBar(ThemeData theme) {
    final (String count, String? selected) = model.statusText;
    final String? message = model.message;
    Widget text(String s, {Color? color}) => Text(s,
        style: theme.textTheme.bodyMedium,
        color: color ?? theme.foregroundSecondary,
        maxLines: 1,
        ellipsis: '…');
    return SizedBox(
      height: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            text(count),
            if (selected != null) ...<Widget>[
              const SizedBox(width: 10),
              SizedBox(
                  height: 16, width: 1, child: ColoredBox(color: theme.border)),
              const SizedBox(width: 10),
              text(selected),
            ],
            if (message != null) ...<Widget>[
              const SizedBox(width: 24),
              Expanded(child: text(message, color: const Color(0xFFC42B1C))),
            ],
          ],
        ),
      ),
    );
  }
}
