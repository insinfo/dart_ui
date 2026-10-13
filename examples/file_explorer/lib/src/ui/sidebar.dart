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
              padding: const EdgeInsets.only(left: 8, right: 4, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _row(
                    id: '::home',
                    label: model.strings.home,
                    icon: FluentIcons.homeFilled,
                    color: const Color(0xFF0F6CBD),
                  ),
                  const SizedBox(height: 14),
                  ..._section(pt ? 'Fixados' : 'Pinned', <Widget>[
                    for (final String path in model.pinned) _pinned(path),
                  ]),
                  ..._section(pt ? 'Unidades' : 'Drives', <Widget>[
                    for (final Volume volume in model.volumes)
                      _row(
                        id: volume.path,
                        label: volume.label,
                        icon: FluentIcons.hardDrive,
                        color: const Color(0xFF5F6B7A),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 4, bottom: 6),
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
              padding: const EdgeInsets.only(left: 12, right: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Text(title,
                        style: theme.textTheme.bodySmall,
                        color: theme.foregroundSecondary),
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
      if (!folded) ...rows,
      const SizedBox(height: 14),
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
      child: _row(
        id: path,
        label: place == null ? model.fs.nameOf(path) : model.placeName(place),
        icon: icon,
        color: color,
        pin: true,
      ),
    );
  }

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
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: SizedBox(
            height: 32,
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
                    left: 0,
                    top: 8,
                    bottom: 8,
                    width: 3,
                    child: DecoratedBox(
                      decoration:
                          BoxDecoration(color: theme.accent, radius: 1.5),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 12, right: 10),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
