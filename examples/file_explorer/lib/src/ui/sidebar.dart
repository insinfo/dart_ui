/// The sidebar, as Files draws it: Home, then sections - Pinned, Drives -
/// under small grey headers that fold, each row an icon and a name, the
/// current one a white card with an accent pill on its left; Settings at the
/// foot.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/location.dart';
import 'drag_support.dart';

/// The icon and colour Windows 11 gives each known folder.
(IconData, Color) placeIcon(Place? place) => switch (place) {
      Place.desktop => (FluentIcons.desktopFilled, const Color(0xFF2B88D8)),
      Place.downloads => (FluentIcons.arrowDownload, const Color(0xFF1E8E4E)),
      Place.documents => (FluentIcons.documentFilled, const Color(0xFF5A7FA8)),
      Place.pictures => (FluentIcons.imageFilled, const Color(0xFF2B88D8)),
      Place.music => (FluentIcons.musicNote2Filled, const Color(0xFFD9541E)),
      Place.videos => (FluentIcons.videoClipFilled, const Color(0xFF8E44AD)),
      Place.home => (FluentIcons.homeFilled, const Color(0xFF0F6CBD)),
      null => (FluentIcons.folderFilled, const Color(0xFFE0A100)),
    };

/// The sidebar.
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.model,
    required this.registry,
    required this.settingsMenu,
  });

  final ExplorerModel model;
  final CommandRegistry registry;

  /// What the Settings row opens.
  final List<Widget> Function() settingsMenu;

  @override
  State<Sidebar> createState() => _SidebarState();
}

/// The sidebar's side margins, which the selected card keeps clear of.
const double _inset = 8;

/// The space after Home and after each section.
const double _sectionGap = 18;

class _SidebarState extends State<Sidebar> {
  final Set<String> _folded = <String>{};

  ExplorerModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    if (model.volumes.isEmpty) {
      unawaited(model.fs.volumes().then((List<Volume> found) {
        if (!mounted) return;
        setState(() => model.volumes = found);
      }, onError: (Object _) {}));
    }
  }

  bool _isCurrent(String id) => switch (model.tab.location) {
        HomeLocation() => id == '::home',
        ThisPcLocation() => id == '::thispc',
        FolderLocation(:final String path) => id == path,
        SearchLocation(:final String root) => id == root,
      };

  void _go(String id) => switch (id) {
        '::home' => widget.registry.execute('nav.home'),
        '::thispc' => widget.registry.execute('nav.thisPc'),
        _ => widget.registry.execute('nav.go', <String, Object?>{'path': id}),
      };

  @override
  Widget build(BuildContext context) {
    final bool pt = model.strings.locale.startsWith('pt');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: ScrollViewer(
            child: Padding(
              padding: const EdgeInsets.only(
                  left: _inset, right: _inset + 1, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _row(
                    id: '::home',
                    label: model.strings.home,
                    icon: FluentIcons.homeFilled,
                    color: const Color(0xFF0F6CBD),
                  ),
                  const SizedBox(height: _sectionGap),
                  ..._section(pt ? 'Fixados' : 'Pinned', <Widget>[
                    for (final String path in model.pinned) _pinned(path),
                  ]),
                  ..._section(pt ? 'Unidades' : 'Drives', <Widget>[
                    for (final Volume volume in model.volumes)
                      _dropInto(
                        volume.path,
                        _row(
                          id: volume.path,
                          label: volume.label,
                          icon: FluentIcons.hardDrive,
                          color: const Color(0xFF5F6B7A),
                        ),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        ),
        // A hairline between the scrolling places and Settings, as Files
        // draws it; Settings then sits on the status line's level.
        Padding(
          padding: const EdgeInsets.only(left: _inset, right: _inset + 1),
          child: SizedBox(
            height: 1,
            child: ColoredBox(color: Theme.of(context).borderSubtle),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
              left: _inset, right: _inset + 1, top: 4, bottom: 3),
          child: MenuAnchor(
            menuChildren: widget.settingsMenu(),
            builder: (BuildContext context, MenuController controller, _) =>
                _row(
              id: '::settings',
              label: pt ? 'Configurações' : 'Settings',
              icon: FluentIcons.settings,
              color: Theme.of(context).foregroundSecondary,
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _section(String title, List<Widget> rows) {
    final ThemeData theme = Theme.of(context);
    final bool folded = _folded.contains(title);
    return <Widget>[
      HoverBuilder(
        builder: (BuildContext context, bool hovered) => GestureDetector(
          behavior: GestureHitTestBehavior.opaque,
          onTap: () => setState(() {
            if (!_folded.remove(title)) _folded.add(title);
          }),
          child: SizedBox(
            height: 28,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(title,
                        style: theme.textTheme.bodySmall.copyWith(fontSize: 12),
                        color: theme.foregroundSecondary,
                        maxLines: 1,
                        ellipsis: '…'),
                  ),
                  Opacity(
                    opacity: hovered || folded ? 1 : .6,
                    child: Icon(
                        folded
                            ? FluentIcons.chevronDown
                            : FluentIcons.chevronUp,
                        size: 12,
                        color: theme.foregroundSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 2),
      if (!folded) ...rows,
      const SizedBox(height: _sectionGap),
    ];
  }

  Widget _pinned(String path) {
    final Place? place = model.placeAt(path);
    final (IconData icon, Color color) = placeIcon(place);
    return ContextMenuArea(
      menuChildren: () => <Widget>[
        MenuItemButton(
          onPressed: () => _go(path),
          child: Text(model.strings.menu('Open')),
        ),
        MenuItemButton(
          onPressed: () => widget.registry
              .execute('file.unpin', <String, Object?>{'path': path}),
          child: Text(model.strings.menu('Unpin from Quick access')),
        ),
      ],
      child: _dropInto(
        path,
        _row(
          id: path,
          label: place == null ? model.fs.nameOf(path) : model.placeName(place),
          icon: icon,
          color: color,
          pin: true,
        ),
      ),
    );
  }

  /// [row] as a place files dragged onto it are dropped into [folder] - a
  /// pinned folder, a drive - lit while they hover.
  Widget _dropInto(String folder, Widget row) => folderDropTarget(
        model: model,
        folder: folder,
        highlight: Theme.of(context).accent.withAlpha(0x2E),
        child: row,
      );

  Widget _row({
    required String id,
    required String label,
    required IconData icon,
    required Color color,
    bool pin = false,
    void Function()? onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    final bool current = _isCurrent(id);
    final bool dark = theme.brightness == ThemeBrightness.dark;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onTap ?? () => _go(id),
        // A 32 px slot, the card 28 px inside it - Files' rhythm.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SizedBox(
            height: 28,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: current
                          ? (dark
                              ? const Color(0x14FFFFFF)
                              : const Color(0xFFFFFFFF))
                          : hovered
                              ? (dark
                                  ? const Color(0x0FFFFFFF)
                                  : const Color(0x0A000000))
                              : null,
                      border: current && !dark
                          ? const BoxBorder(color: Color(0x0F000000), width: 1)
                          : null,
                      radius: 4,
                    ),
                  ),
                ),
                if (current)
                  Positioned(
                    left: 1,
                    top: 6,
                    bottom: 6,
                    width: 3,
                    child: DecoratedBox(
                      decoration:
                          BoxDecoration(color: theme.accent, radius: 1.5),
                    ),
                  ),
                // Filling the card, so the row centres in it: left loose in
                // the stack it would sit at the card's top.
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Icon(icon, size: 16, color: color),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(label,
                              style: theme.textTheme.bodyMedium,
                              color: theme.foreground,
                              maxLines: 1,
                              ellipsis: '…'),
                        ),
                        if (pin)
                          Icon(FluentIcons.pin,
                              size: 14, color: theme.foregroundSecondary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
