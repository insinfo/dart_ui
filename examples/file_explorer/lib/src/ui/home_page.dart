/// Home - Quick access and Recent - and This PC - the drives.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/explorer_model.dart';
import '../engine/file_system.dart';
import '../engine/file_types.dart';
import '../engine/location.dart';
import 'file_icon.dart';

/// Home: the pinned folders as tiles, then the files opened lately.
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.model, required this.registry});

  final ExplorerModel model;
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ScrollViewer(
      child: Padding(
        padding:
            const EdgeInsets.only(left: 20, top: 12, right: 20, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Section(model.strings.quickAccess),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String path in model.pinned)
                  _QuickAccessTile(
                    name: _nameOf(path),
                    detail: model.fs.parentOf(path) ?? path,
                    onOpen: () => registry
                        .execute('nav.go', <String, Object?>{'path': path}),
                    onUnpin: () => registry
                        .execute('file.unpin', <String, Object?>{'path': path}),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _Section(model.strings.recent),
            if (model.recent.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  model.strings.locale.startsWith('pt')
                      ? 'Os arquivos que você abrir aparecerão aqui.'
                      : "After you've opened some files, we'll show the most "
                          'recent ones here.',
                  style: theme.textTheme.bodyMedium,
                  color: theme.foregroundSecondary,
                ),
              )
            else
              for (final FileEntry file in model.recent)
                _RecentRow(
                  entry: file,
                  location: model.fs.parentOf(file.path) ?? '',
                  onOpen: () => model.open(file),
                ),
          ],
        ),
      ),
    );
  }

  String _nameOf(String path) {
    final Place? place = model.placeAt(path);
    return place == null ? model.fs.nameOf(path) : model.placeName(place);
  }
}

/// This PC: one card per drive.
class ThisPcPage extends StatelessWidget {
  const ThisPcPage({super.key, required this.model, required this.registry});

  final ExplorerModel model;
  final CommandRegistry registry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ScrollViewer(
      child: Padding(
        padding:
            const EdgeInsets.only(left: 20, top: 12, right: 20, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Section(model.strings.drives),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final Volume volume in model.volumes)
                  _Hoverable(
                    onTap: () => registry.execute(
                        'nav.go', <String, Object?>{'path': volume.path}),
                    child: SizedBox(
                      width: 260,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            const FileIcon(FileKind.drive, size: 40),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(volume.label,
                                      style: theme.textTheme.bodyMedium,
                                      color: theme.foreground,
                                      maxLines: 1,
                                      ellipsis: '…'),
                                  const SizedBox(height: 6),
                                  _UsageBar(volume: volume),
                                  if (volume.totalBytes != null &&
                                      volume.freeBytes != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        model.strings.freeOf
                                            .replaceFirst(
                                                '{free}',
                                                humanSize(volume.freeBytes!,
                                                    model.strings))
                                            .replaceFirst(
                                                '{total}',
                                                humanSize(volume.totalBytes!,
                                                    model.strings)),
                                        style: theme.textTheme.bodySmall,
                                        color: theme.foregroundSecondary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.volume});

  final Volume volume;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? total = volume.totalBytes;
    final int? free = volume.freeBytes;
    final double used =
        total == null || free == null || total == 0 ? 0 : 1 - free / total;
    return SizedBox(
      height: 6,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => Stack(
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: theme.borderSubtle, radius: 3),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: c.maxWidth * used,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // Windows turns the bar red past nine tenths.
                  color: used > .9 ? const Color(0xFFD13438) : theme.accent,
                  radius: 3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: <Widget>[
          Icon(PhosphorIcons.caretDown,
              size: theme.iconSize - 4, color: theme.foregroundSecondary),
          const SizedBox(width: 6),
          Text(title,
              style: theme.textTheme.titleSmall, color: theme.foreground),
        ],
      ),
    );
  }
}

/// A surface that lights up under the pointer and opens on a click.
class _Hoverable extends StatelessWidget {
  const _Hoverable({required this.onTap, required this.child});

  final void Function() onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hovered ? theme.hoverSurface : null,
            radius: theme.cornerRadius,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _QuickAccessTile extends StatelessWidget {
  const _QuickAccessTile({
    required this.name,
    required this.detail,
    required this.onOpen,
    required this.onUnpin,
  });

  final String name;
  final String detail;
  final void Function() onOpen;
  final void Function() onUnpin;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ContextMenuArea(
      menuChildren: () => <Widget>[
        MenuItemButton(onPressed: onOpen, child: const Text('Open')),
        MenuItemButton(
            onPressed: onUnpin, child: const Text('Unpin from Quick access')),
      ],
      child: _Hoverable(
        onTap: onOpen,
        child: SizedBox(
          width: 200,
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                const FileIcon(FileKind.folder, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(name,
                          style: theme.textTheme.bodyMedium,
                          color: theme.foreground,
                          maxLines: 1,
                          ellipsis: '…'),
                      Text(detail,
                          style: theme.textTheme.bodySmall,
                          color: theme.foregroundSecondary,
                          maxLines: 1,
                          ellipsis: '…'),
                    ],
                  ),
                ),
                Icon(PhosphorIcons.pushPin,
                    size: theme.iconSize - 4, color: theme.foregroundSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.entry,
    required this.location,
    required this.onOpen,
  });

  final FileEntry entry;
  final String location;
  final void Function() onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return _Hoverable(
      onTap: onOpen,
      child: SizedBox(
        height: 32,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              FileIcon(kindOf(entry), size: 16),
              const SizedBox(width: 10),
              SizedBox(
                width: 300,
                child: Text(entry.name,
                    style: theme.textTheme.bodyMedium,
                    color: theme.foreground,
                    maxLines: 1,
                    ellipsis: '…'),
              ),
              Expanded(
                child: Text(location,
                    style: theme.textTheme.bodyMedium,
                    color: theme.foregroundSecondary,
                    maxLines: 1,
                    ellipsis: '…'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
