library;

import 'standard_paths_types.dart';

String resolve(StandardFolder folder) {
  throw StandardPathsException(
    folder: folder,
    reason: 'this target exposes no filesystem to name standard folders in',
  );
}
