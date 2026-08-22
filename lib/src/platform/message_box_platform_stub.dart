library;

import 'message_box_types.dart';

Future<bool> show({
  required String title,
  required String message,
  required MessageBoxKind kind,
  required int ownerWindowHandle,
}) async {
  throw const MessageBoxException(
    reason: 'this target has no native message-box implementation',
  );
}
