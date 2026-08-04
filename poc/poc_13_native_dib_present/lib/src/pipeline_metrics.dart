final class PipelineMetrics {
  const PipelineMetrics({
    required this.name,
    required this.frames,
    required this.pixelsPerFrame,
    required this.elapsed,
    required this.renderMicroseconds,
    required this.presentMicroseconds,
  });

  final String name;
  final int frames;
  final int pixelsPerFrame;
  final Duration elapsed;
  final int renderMicroseconds;
  final int presentMicroseconds;

  double get framesPerSecond =>
      frames * Duration.microsecondsPerSecond / elapsed.inMicroseconds;
  double get averageRenderMicroseconds => renderMicroseconds / frames;
  double get averagePresentMicroseconds => presentMicroseconds / frames;
  double get averageFrameMicroseconds => elapsed.inMicroseconds / frames;
  double get renderNanosecondsPerPixel =>
      renderMicroseconds * 1000 / (frames * pixelsPerFrame);
}

final class PipelineComparison {
  const PipelineComparison({required this.dartCopy, required this.nativeDib});

  final PipelineMetrics dartCopy;
  final PipelineMetrics nativeDib;

  double get presentationSpeedup =>
      dartCopy.averagePresentMicroseconds /
      nativeDib.averagePresentMicroseconds;
  double get throughputSpeedup =>
      nativeDib.framesPerSecond / dartCopy.framesPerSecond;
}
