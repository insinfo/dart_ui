# Configurable file explorer columns — 2026-10-19

The Details view now has 16 columns: name, modification date, type, size,
creation date, access date, metadata change date, extension, folder path,
full path, size in bytes, attributes, permissions, hidden and read-only flags,
and symbolic link target.

The header menu and View menu open Choose columns. Its searchable list supports
visibility, ordering, per-column width, content sizing and restoring defaults.
Name remains required and first. Apply commits a draft; Cancel discards pending
changes. Order, visibility and widths are saved per folder. Existing column IDs
and the default location column in search results remain compatible.

File values come from the filesystem rather than placeholder metadata. Windows
attributes use GetFileAttributesW, including Unicode and extended-length paths.
Dart FileStat.changed is creation time on Windows and metadata change time on
POSIX; these now populate separate columns. The current POSIX provider cannot
supply birth time, so creation date stays empty there. Unavailable fields stay
empty. Media tags and document metadata extraction are outside this change.

Validation: analyzer clean and 74 tests passed, one platform-specific test skipped,
on macOS, Windows 11 ARM64 and Ubuntu 24.04 ARM64. Windows exercised read-only,
hidden, Unicode and long paths. Architecture tests: 23 passed on both guests.
AOT application builds succeeded on all three systems. The native Windows
Direct3D 11 smoke opened and dismissed the real chooser without application
errors; its captured layout was inspected.

References:
- https://api.dart.dev/dart-io/FileStat-class.html
- https://github.com/dart-lang/sdk/blob/main/sdk/lib/io/file_system_entity.dart
- https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileattributesw
- https://learn.microsoft.com/en-us/windows/win32/fileio/file-attribute-constants
