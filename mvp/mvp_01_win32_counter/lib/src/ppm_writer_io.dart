import 'dart:io';

Future<void> writePpm(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes);
}
