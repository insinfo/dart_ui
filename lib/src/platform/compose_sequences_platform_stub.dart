library;

import 'compose_sequences.dart';

/// No filesystem, so no Compose table.
///
/// The web target, where the browser has already applied the layout and dead
/// keys before an `input` event ever reaches Dart - so composing them again
/// here would double every accent.
ComposeTable loadSystemComposeTable({Map<String, String>? environment}) =>
    ComposeTable.empty;

List<String> systemComposeFileCandidates({
  Map<String, String>? environment,
}) =>
    const <String>[];
