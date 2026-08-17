/// Background computation with a Flutter-compatible public contract.
library;

export 'compute_stub.dart' if (dart.library.io) 'compute_io.dart'
    show ComputeCallback, compute;
