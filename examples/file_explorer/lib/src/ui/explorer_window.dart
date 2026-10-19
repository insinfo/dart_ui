/// The window, laid out as Files draws Windows 11's File Explorer: tabs on
/// the Mica strip where the title bar was; under them, on a lighter layer,
/// the address row with its pill; then the sidebar, and beside it the
/// command bar and the items, each a rounded card, over the status line.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/columns.dart';
import '../engine/explorer_commands.dart';
import '../engine/explorer_host.dart';
import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/location.dart';
import 'bar_button.dart';
import 'column_options.dart' as column_options;
import 'command_icons.dart';
import 'details_pane.dart';
import 'folder_options.dart' as options;
import 'folder_view.dart';
import 'home_page.dart';
import 'menus.dart';
import 'preview_pane.dart';
import 'properties_dialog.dart';
import 'sidebar.dart';
import 'thumbnails.dart';

/// The explorer window.
class ExplorerWindow extends StatefulWidget {
  const ExplorerWindow({
    super.key,
    required this.model,
    this.onReady,
    this.onClose,
    this.thumbnailLoader,
  });

  final ExplorerModel model;

  /// Reads pictures' thumbnails for the icon views; null shows file icons.
  final ThumbnailLoader? thumbnailLoader;

  /// Told when the commands are registered - where a test reaches them.
  final void Function(ExplorerWindowState window)? onReady;

  /// The last tab was closed. Null closes the window, exactly as its close
  /// button does - which ends the application when it is the last one.
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
  final _renameRegion = GlobalKey();

  /// Subfolders of the address bar's steps, read when a chevron opens.
  final Map<String, List<FileEntry>> _subfolders = <String, List<FileEntry>>{};

  ExplorerModel get model => widget.model;

  late final ThumbnailCache? _thumbnails = widget.thumbnailLoader == null
      ? null
      : ThumbnailCache(loader: widget.thumbnailLoader!, onLoaded: _changed);

  @override
  void initState() {
    super.initState();
    registerExplorerCommands(registry, model, this);
    model.addListener(_changed);
    final BuildContext self = context;
    _keysOwner = self is Element ? self.owner : null;
    _keysOwner?.addTextInputHandler(_typeAhead);
    unawaited(model.refresh());
    widget.onReady?.call(this);
  }

  BuildOwner? _keysOwner;

  /// What has been typed into the list, and when the last key came: a pause
  /// of a second starts a new name, as in File Explorer.
  String _typed = '';
  final Stopwatch _sinceTyped = Stopwatch();

  /// Typing in the list - nothing else having taken the text - selects the
  /// next item whose name starts with it.
  bool _typeAhead(TextInputEvent event) {
    final Location at = model.tab.location;
    if (at is! FolderLocation && at is! SearchLocation) return false;
    if (model.tab.renaming != null || _searching) return false;
    if (!_sinceTyped.isRunning || _sinceTyped.elapsedMilliseconds > 1000) {
      _typed = '';
    }
    _typed += event.text;
    _sinceTyped
      ..reset()
      ..start();
    registry.execute('select.byName', <String, Object?>{'prefix': _typed});
    return true;
  }

  @override
  void dispose() {
    _keysOwner?.removeTextInputHandler(_typeAhead);
    _thumbnails?.dispose();
    model.removeListener(_changed);
    renameFocus.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final title = model.preferences['showFullPath']
        ? model.currentFolder ?? model.titleOf(model.tab.location)
        : model.strings.locale.startsWith('pt')
            ? 'Explorador de Arquivos'
            : 'File Explorer';
    WindowScope.of(context)?.setTitle(title);
    setState(() {});
  }

  @override
  void showFolderOptions() => unawaited(showFolderOptionsDialog());

  @override
  void showColumnOptions() =>
      unawaited(column_options.showColumnOptions(context, model));

  @override
  void fitAllColumns() {
    final widths = Map<String, double>.of(model.columnWidths);
    for (final column in model.visibleColumns) {
      widths[column.id] = column_options.measureColumnWidth(
          model, Theme.of(context), column, model.tab.visible);
    }
    model.configureColumns(model.visibleColumns, widths);
  }

  @override
  void renameSelection() {
    final controller = TextEditingController();
    final currentModel = model;
    unawaited(showDialog<void>(
        context: context,
        builder: (dialogContext) => SizedBox(
            width: 420,
            child: Dialog(
                title: currentModel.strings.locale.startsWith('pt')
                    ? 'Renomear itens'
                    : 'Rename items',
                onDismiss: () => closeDialog<void>(dialogContext),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          currentModel.strings.locale.startsWith('pt')
                              ? 'Os itens receberão Nome (1), Nome (2)… As extensões serão preservadas.'
                              : 'Items will use Name (1), Name (2)… File extensions are preserved.',
                          softWrap: true),
                      const SizedBox(height: 12),
                      TextField(
                          controller: controller,
                          autofocus: true,
                          label: currentModel.strings.locale.startsWith('pt')
                              ? 'Nome base'
                              : 'Base name'),
                    ]),
                actions: [
                  Button(
                      label: 'OK',
                      isDefault: true,
                      onPressed: () {
                        final name = controller.value;
                        closeDialog<void>(dialogContext);
                        unawaited(currentModel.renameSelection(name));
                      }),
                  Button(
                      label: currentModel.strings.locale.startsWith('pt')
                          ? 'Cancelar'
                          : 'Cancel',
                      accent: false,
                      isCancel: true,
                      onPressed: () => closeDialog<void>(dialogContext)),
                ]))));
  }

  @override
  void showCommands() => unawaited(showCommandPalette(
      context: context,
      registry: registry,
      title: model.strings.locale.startsWith('pt') ? 'Comandos' : 'Commands',
      searchLabel: model.strings.locale.startsWith('pt')
          ? 'Pesquisar comandos'
          : 'Search commands'));

  @override
  void openTerminal(String directory) =>
      unawaited(Shell.openTerminal(directory).catchError((Object error) {
        model.message = '$error';
        model.notify();
      }));

  Future<void> showFolderOptionsDialog() =>
      options.showFolderOptions(context, model);

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
    // Nothing selected: the folder itself, as Explorer does.
    if (entries.isEmpty) {
      final Location at = model.tab.location;
      if (at is! FolderLocation) return;
      unawaited(model.fs.stat(at.path).then((FileEntry? folder) {
        if (folder != null && mounted) {
          unawaited(showPropertiesDialog(context, model, <FileEntry>[folder]));
        }
      }));
      return;
    }
    unawaited(showPropertiesDialog(context, model, entries));
  }

  @override
  void copyText(String text) {
    unawaited(ClipboardScope.of(context).writeText(text).catchError((_) {}));
  }

  @override
  void closeWindow() {
    final void Function()? onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      WindowScope.of(context)?.close();
    }
  }

  // --- rename in place ------------------------------------------------------

  /// Only a press outside the editor commits an unfinished name.
  void _renamePointerDown(PointerDownEvent event) {
    final element = _renameRegion.currentElement;
    if (element is RenderObjectElement) {
      final box = element.renderObject;
      if (box.hasSize &&
          Rect.fromLTWH(0, 0, box.size.width, box.size.height)
              .contains(box.globalToLocal(event.logicalPosition))) {
        return;
      }
    }
    _commitRename();
  }

  void _commitRename() {
    final path = model.tab.renaming;
    if (path == null || _renameSeeded != path) return;
    _renameSeeded = null;
    unawaited(model.rename(path, rename.value));
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
    return PointerListener(
        key: _renameRegion,
        // Editing owns these gestures. Letting them bubble to the row/grid
        // retakes its focus and commits the name while selecting text.
        stopPropagation: (event) =>
            event is PointerDownEvent ||
            event is PointerUpEvent ||
            event is PointerMoveEvent ||
            event is PointerCancelEvent,
        child: CallbackShortcuts(
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
        ));
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
    return PointerListener(
        // Capture observes outside presses even on scrollbars and other
        // controls that correctly stop normal event bubbling.
        onPointerDownCapture: _renamePointerDown,
        child: TooltipPresentation(
            mode: model.preferences['overlayTooltips']
                ? TooltipMode.overlay
                : TooltipMode.auto,
            child: CallbackShortcuts(
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
            )));
  }

  /// The tabs, where the title bar was: clear of the window buttons the
  /// platform keeps there, and with the empty strip after them a handle that
  /// moves the window.
  Widget _tabStrip(ThemeData theme) {
    final HiddenTitleBarWindow? bar = WindowScope.of(context)?.hiddenTitleBar;
    if (bar == null) return _tabs(theme, leading: 8, height: 40);
    return ValueListenableBuilder<Rect>(
      valueListenable: bar.systemButtons,
      builder: (BuildContext context, Rect buttons, _) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            WindowDragArea(
          child: _tabs(
            theme,
            leading:
                buttons.isEmpty || buttons.center.dx >= constraints.maxWidth / 2
                    ? 8
                    : buttons.right + 14,
            trailing:
                buttons.isEmpty || buttons.center.dx < constraints.maxWidth / 2
                    ? 0
                    : (constraints.maxWidth - buttons.left + 8),
            height: bar.titleBarHeight > 40 ? bar.titleBarHeight : 40,
          ),
        ),
      ),
    );
  }

  Widget _tabs(ThemeData theme,
          {required double leading,
          required double height,
          double trailing = 0}) =>
      SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(left: leading, right: trailing, top: 4),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: DocumentTabStrip(
              style: DocumentTabStyle.raised,
              // The raised card 31 px tall under 4 px of headroom, its top
              // 9 px under the window's, as in Files.
              height: 35,
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
              contextMenu: (_) => menus.widgets(const [
                CommandItem('tab.duplicate'),
                CommandItem('tab.reopen'),
                MenuSeparator(),
                CommandItem('tab.moveLeft'),
                CommandItem('tab.moveRight'),
                MenuSeparator(),
                CommandItem('tab.close'),
                CommandItem('tab.closeOthers'),
                CommandItem('tab.closeLeft'),
                CommandItem('tab.closeRight'),
              ]),
              onAdd: () => registry.execute('tab.new'),
              addTooltip: model.strings.newTab,
            ),
          ),
        ),
      );

  /// Back, forward, up and refresh on a 40 px pitch, then the pill - the
  /// row Files draws, its middle level with the pill's.
  Widget _addressRow(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(left: 4, right: 8, top: 4, bottom: 5),
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
                    iconSize: 20),
              const SizedBox(width: 1),
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
      height: _pillHeight,
      radius: _pillHeight / 2,
      // Clear of the rounded end, as far in as the search button is.
      leading: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Icon(_locationIcon(model.tab.location),
            color: theme.accent, size: 16),
      ),
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
      // Inset from the round end by as much as the leading icon is, so the
      // magnifier does not ride the curve.
      trailing: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: BarButton(
          icon: FluentIcons.search,
          registry: registry,
          command: 'nav.focusSearch',
          iconSize: 18,
          compact: true,
        ),
      ),
    );
  }

  /// The address pill's height - and the search box's, which takes its place.
  static const double _pillHeight = 38;

  /// The pill turned into a search box - Ctrl+F, or its search button.
  Widget _searchPill(ThemeData theme) => CallbackShortcuts(
        bindings: <KeyGesture, void Function()?>{
          const KeyGesture(logicalKeyEscape): _endSearch,
        },
        child: SizedBox(
          height: _pillHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.surfaceAlternate,
              border: BoxBorder(color: theme.accent, width: 1),
              radius: _pillHeight / 2,
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 10),
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

  Widget _body(ThemeData theme) {
    final content = _mainPane(theme);
    if (!model.navigationPane) return content;
    return SplitView(
      firstExtent: model.navigationPaneWidth,
      minFirst: 160,
      minSecond: 320,
      dividerThickness: 6,
      onResized: model.resizeNavigationPane,
      first: Sidebar(
        model: model,
        registry: registry,
        settingsMenu: () => menus.widgets(settingsMenu(model.strings)),
      ),
      second: content,
    );
  }

  Widget _mainPane(ThemeData theme) => Padding(
        padding: EdgeInsets.only(left: model.navigationPane ? 0 : 8, right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _card(theme, _commandBar(theme)),
            const SizedBox(height: 4),
            if (model.tab.location is SearchLocation &&
                (model.tab.loading || model.tab.searchTruncated))
              Row(children: [
                Expanded(
                    child: Text(model.tab.searchTruncated
                        ? (model.strings.locale.startsWith('pt')
                            ? 'Limite de 5.000 resultados atingido.'
                            : '5,000 result limit reached.')
                        : (model.strings.locale.startsWith('pt')
                            ? 'Pesquisando…'
                            : 'Searching…'))),
                if (model.tab.loading)
                  Button(
                      label: model.strings.locale.startsWith('pt')
                          ? 'Parar'
                          : 'Stop',
                      accent: false,
                      onPressed: model.cancelSearch),
              ]),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: _card(theme, _content(theme))),
                  if (model.preferences['previewPane']) ...<Widget>[
                    const SizedBox(width: 6),
                    SizedBox(
                        width: 280,
                        child: _card(
                            theme,
                            PreviewPane(
                                model: model, loader: widget.thumbnailLoader))),
                  ] else if (model.detailsPane) ...<Widget>[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 280,
                      child: _card(theme, DetailsPane(model: model)),
                    ),
                  ],
                ],
              ),
            ),
            if (model.preferences['showStatusBar']) _statusBar(theme),
          ],
        ),
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
    Widget command(String id) => BarButton(
        icon: commandIcon(id)!,
        registry: registry,
        command: id,
        iconSize: _commandIconSize);
    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
          child: SizedBox(width: 1, child: ColoredBox(color: theme.border)),
        );
    final String Function(String) t = model.strings.menu;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            MenuBarButton(
              icon: FluentIcons.addCircle,
              iconSize: _commandIconSize,
              label: t('New'),
              chevron: false,
              enabled: registry.isEnabled('file.newFolder') ||
                  registry.isEnabled('file.newTextDocument'),
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
              iconSize: _commandIconSize,
              tooltip: t('Sort'),
              chevron: true,
              menu: () => menus.widgets(kSortMenu),
            ),
            MenuBarButton(
              icon: _viewIcon(),
              iconSize: _commandIconSize,
              tooltip: t('View'),
              chevron: true,
              menu: () => menus.widgets(viewMenu(model.strings)),
            ),
            MenuBarButton(
              icon: FluentIcons.moreHorizontal,
              iconSize: _commandIconSize,
              tooltip: t('See more'),
              menu: () => menus.widgets(kMoreMenu),
            ),
            BarButton(
              icon: FluentIcons.panelRight,
              iconSize: _commandIconSize,
              registry: registry,
              command: 'view.detailsPane',
            ),
          ],
        ),
      ),
    );
  }

  /// The command bar's glyphs: 20 px, on a 40 px pitch.
  static const double _commandIconSize = 20;

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
              thumbnails: _thumbnails,
            ),
          ),
      };

  /// "17 items | 1 item selected", under the file area.
  Widget _statusBar(ThemeData theme) {
    final (String count, String? selected) = model.statusText;
    final String? message = model.archiveBusy
        ? (model.strings.locale.startsWith('pt')
            ? 'Processando ZIP…'
            : 'Processing ZIP…')
        : model.message;
    Widget text(String s, {Color? color}) => Text(s,
        style: theme.textTheme.bodyMedium,
        color: color ?? theme.foregroundSecondary,
        maxLines: 1,
        ellipsis: '…');
    // As tall as the sidebar's Settings row beside it, so the two read as
    // one line.
    return SizedBox(
      height: 36,
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
