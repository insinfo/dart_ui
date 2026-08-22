library;

abstract interface class FramePresenter {
  String get name;
  String get device;
  String get mode;

  void initialize();
  void present(int frameNumber);
  void finish();
  void dispose();
}
