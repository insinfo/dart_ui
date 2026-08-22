library;

import 'trash_types.dart';

Future<void> moveToTrash(String path) async {
  throw TrashException(
    path: path,
    reason: 'this target has no trash implementation',
  );
}
