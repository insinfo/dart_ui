/// The portable clipboard facade over a Wayland data-device connection.
library;

import '../../platform/clipboard.dart';
import 'wayland_connection.dart';

/// Adapts [WaylandSelectionClient]'s protocol operations to the application
/// clipboard contract.
final class WaylandClipboard implements Clipboard {
  const WaylandClipboard(this.client);

  final WaylandSelectionClient client;

  @override
  Future<String?> readText() => client.readClipboardText();

  @override
  Future<void> writeText(String text) async => client.setClipboardText(text);
}
