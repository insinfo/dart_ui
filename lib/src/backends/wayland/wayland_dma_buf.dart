/// GPU buffers imported by a compositor through linux-dmabuf v3.
library;

/// One plane of an exported DRM buffer. The caller owns [fd] and keeps it
/// open until the import request has been flushed.
final class WaylandDmaBufPlane {
  const WaylandDmaBufPlane(
      {required this.fd,
      required this.stride,
      required this.offset,
      required this.modifier});
  final int fd;
  final int stride;
  final int offset;
  final int modifier;
}

/// Separate from the CPU client so existing transports and test doubles do
/// not need native GPU support. Release callbacks run once per submitted use,
/// after compositor use or when a connection with busy storage is torn down.
abstract interface class WaylandDmaBufClient {
  bool get supportsDmaBuf;
  bool supportsDmaBufFormat(int format, int modifier);
  int importDmaBuf(
      {required int width,
      required int height,
      required int format,
      required List<WaylandDmaBufPlane> planes,
      required void Function() onRelease});
  void destroyDmaBuf(int bufferId);
  bool commitDmaBuf(
      {required int surfaceId,
      required int bufferId,
      required int width,
      required int height,
      required int bufferScale});
}

const String linuxDmaBufInterface = 'zwp_linux_dmabuf_v1';
const int linuxDmaBufBindVersion = 3;
const int drmFormatArgb8888 = 0x34325241;
const int drmFormatXrgb8888 = 0x34325258;
// DRM_FORMAT_MOD_INVALID: implicit modifiers, distinct from LINEAR (zero).
const int drmFormatModInvalid = 0x00ffffffffffffff;
