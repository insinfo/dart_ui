/// The window: tabs in the top strip, the address row, the command bar,
/// then the navigation pane, the items and the details pane, over the
/// status bar - Windows 11's File Explorer, laid out after Files.
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
import 'nav_pane.dart';

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

  @override
  void focusSearch() {
    search.selectAll();
    searchFocus.requestFocus();
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
            ColoredBox(
              color: theme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _addressRow(theme),
                  _commandBar(theme),
                ],
              ),
            ),
            Expanded(child: _body(theme)),
            _statusBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _tabStrip(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(left: 8, top: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: DocumentTabStrip(
            style: DocumentTabStyle.raised,
            height: 36,
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
      );

  Widget _addressRow(ThemeData theme) {
    final List<(String, BreadcrumbItem)> steps = _steps();
    final String placeName = model.titleOf(model.tab.location);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (final String id in const <String>[
            'nav.back',
            'nav.forward',
            'nav.up',
            'nav.refresh',
          ])
            BarButton(icon: commandIcon(id)!, registry: registry, command: id),
          const SizedBox(width: 6),
          Expanded(
            child: BreadcrumbBar(
              controller: address,
              height: 34,
              leading: Icon(_locationIcon(model.tab.location),
                  color: theme.foregroundSecondary),
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
              editText: model.currentFolder ?? '',
              onSubmitted: (String text) {
                if (text.trim().isEmpty) return;
                registry
                    .execute('nav.go', <String, Object?>{'path': text.trim()});
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 260,
            height: 34,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: TextField(
                    controller: search,
                    focusNode: searchFocus,
                    label: '${model.strings.searchIn} $placeName',
                    onSubmitted: (String query) => registry.execute(
                        'nav.search', <String, Object?>{'query': query}),
                  ),
                ),
                Positioned(
                  right: 10,
                  top: 9,
                  child: IgnorePointer(
                    child: Icon(FluentIcons.search,
                        size: 16, color: theme.foregroundSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commandBar(ThemeData theme) {
    Widget command(String id) =>
        BarButton(icon: commandIcon(id)!, registry: registry, command: id);
    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: SizedBox(width: 1, child: ColoredBox(color: theme.border)),
        );
    final String Function(String) t = model.strings.menu;
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, bottom: 6),
      child: SizedBox(
        height: 36,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MenuBarButton(
              icon: FluentIcons.addCircle,
              label: t('New'),
              menu: () => menus.widgets(kNewMenu),
            ),
            divider(),
            command('file.cut'),
            command('file.copy'),
            command('file.paste'),
            command('file.rename'),
            command('file.delete'),
            divider(),
            MenuBarButton(
              icon: FluentIcons.arrowSort,
              label: t('Sort'),
              menu: () => menus.widgets(kSortMenu),
            ),
            MenuBarButton(
              icon: FluentIcons.textBulletListLtr,
              label: t('View'),
              menu: () => menus.widgets(viewMenu(model.strings)),
            ),
            MenuBarButton(
              icon: FluentIcons.moreHorizontal,
              tooltip: t('See more'),
              menu: () => menus.widgets(kMoreMenu),
            ),
            const Spacer(),
            BarButton(
              icon: FluentIcons.panelRight,
              label: t('Details'),
              registry: registry,
              command: 'view.detailsPane',
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final Location at = model.tab.location;
    final Widget content = switch (at) {
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
          ),
        ),
    };
    final Widget card = Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 4, top: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surfaceAlternate,
          border: BoxBorder(color: theme.borderSubtle, width: 1),
          radius: 8,
        ),
        child: ClipRRect(radius: 8, child: content),
      ),
    );
    return ColoredBox(
      color: theme.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (model.navigationPane)
            SizedBox(
              width: 240,
              child: NavigationPane(model: model, registry: registry),
            ),
          Expanded(child: card),
          if (model.detailsPane)
            SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 4, top: 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.surfaceAlternate,
                    border: BoxBorder(color: theme.borderSubtle, width: 1),
                    radius: 8,
                  ),
                  child: DetailsPane(model: model),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusBar(ThemeData theme) {
    final (String count, String? selected) = model.statusText;
    final String? message = model.message;
    Widget text(String s, {Color? color}) => Text(s,
        style: theme.textTheme.bodySmall,
        color: color ?? theme.foregroundSecondary,
        maxLines: 1,
        ellipsis: '…');
    return ColoredBox(
      color: theme.surface,
      child: SizedBox(
        height: 30,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              text(count),
              if (selected != null) ...<Widget>[
                const SizedBox(width: 12),
                SizedBox(
                    height: 14,
                    width: 1,
                    child: ColoredBox(color: theme.border)),
                const SizedBox(width: 12),
                text(selected),
              ],
              if (message != null) ...<Widget>[
                const SizedBox(width: 24),
                Expanded(child: text(message, color: const Color(0xFFC42B1C))),
              ] else
                const Spacer(),
              BarButton(
                icon: FluentIcons.textBulletListLtr,
                registry: registry,
                command: 'view.details',
              ),
              BarButton(
                icon: FluentIcons.grid,
                registry: registry,
                command: 'view.largeIcons',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
