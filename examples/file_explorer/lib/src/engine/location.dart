/// Where a tab is: Home, This PC, a folder, or a search inside one.
library;

/// A place a tab can show, and what its history remembers.
sealed class Location {
  const Location();
}

/// Quick access and recent files - what a new tab opens on.
final class HomeLocation extends Location {
  const HomeLocation();

  @override
  bool operator ==(Object other) => other is HomeLocation;

  @override
  int get hashCode => 1;
}

/// The drives.
final class ThisPcLocation extends Location {
  const ThisPcLocation();

  @override
  bool operator ==(Object other) => other is ThisPcLocation;

  @override
  int get hashCode => 2;
}

/// A folder on disk.
final class FolderLocation extends Location {
  const FolderLocation(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is FolderLocation && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FolderLocation($path)';
}

/// What matches [query] under [root], subfolders included.
final class SearchLocation extends Location {
  const SearchLocation(this.root, this.query);

  final String root;
  final String query;

  @override
  bool operator ==(Object other) =>
      other is SearchLocation && other.root == root && other.query == query;

  @override
  int get hashCode => Object.hash(root, query);
}

/// The known folders the navigation pane pins, by role.
enum Place { home, desktop, downloads, documents, pictures, music, videos }

/// How the items of a folder are laid out - Windows 11's View menu.
enum ViewMode {
  extraLargeIcons,
  largeIcons,
  mediumIcons,
  smallIcons,
  list,
  details,
  tiles,
  content,
}

/// The columns Details can show; Name always is.
enum DetailsColumn { name, dateModified, type, size, dateCreated }

/// The columns a folder can be sorted by.
enum SortField { name, dateModified, type, size, dateCreated, extension }
