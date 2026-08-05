import 'ppm_writer_stub.dart' if (dart.library.io) 'ppm_writer_io.dart'
    as implementation;

Future<void> writePpm(String path, List<int> bytes) =>
    implementation.writePpm(path, bytes);
