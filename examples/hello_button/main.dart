import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/win32.dart';

void main() async {
  final backend = Win32WindowingBackend();
  await backend.initialize();

  final window = await backend.createWindow(
    const WindowOptions(
      title: 'dart_ui — Widget → CPU → Win32 DIB',
      size: Size(400, 300),
    ),
  ) as Win32Window;

  final pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(window.clientSize),
  );
  final builds = BuildOwner(pipelineOwner: pipeline);
  final presenter = Win32CpuPresenter(window);
  final displayLists = <DisplayList>[DisplayList(), DisplayList()];
  var nextDisplayList = 0;
  var hovered = false;
  var pressed = false;

  Widget view() => ColoredBox(
        color: 0xFF18212F,
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: ColoredBox(
            color: pressed
                ? 0xFF2F80ED
                : hovered
                    ? 0xFF4C9AFF
                    : 0xFF3B82F6,
          ),
        ),
      );

  Future<void> drawFrame() async {
    builds.updateRoot(view());
    pipeline.rootConstraints = BoxConstraints.tight(window.clientSize);
    final list = displayLists[nextDisplayList];
    nextDisplayList = (nextDisplayList + 1) % displayLists.length;
    list.reset();
    pipeline.drawFrame(list);
    final result = await presenter.renderDisplayList(
      list,
      clearColor: 0xFF18212F,
    );
    if (!result.isSuccess && result.diagnostic != null) {
      print(result.diagnostic);
    }
  }

  Future<void> pendingDraw = Future<void>.value();
  void scheduleDraw() {
    pendingDraw = pendingDraw.then((_) => drawFrame()).catchError(
      (Object error, StackTrace stackTrace) {
        print('frame failed: $error\n$stackTrace');
      },
    );
  }

  var running = true;

  window.events.listen((event) {
    if (event is WindowCloseRequestedEvent) {
      window.close();
    } else if (event is WindowClosedEvent) {
      running = false;
    } else if (event is PointerDownEvent) {
      pressed = true;
      scheduleDraw();
    } else if (event is PointerUpEvent) {
      pressed = false;
      scheduleDraw();
    } else if (event is WindowPointerEnterEvent) {
      hovered = true;
      scheduleDraw();
    } else if (event is WindowPointerLeaveEvent) {
      hovered = false;
      pressed = false;
      scheduleDraw();
    } else if (event is KeyDownEvent) {
      if (event.logicalKey == 0x0D || event.logicalKey == 0x20) {
        pressed = true;
        scheduleDraw();
      }
    } else if (event is KeyUpEvent) {
      if (event.logicalKey == 0x0D || event.logicalKey == 0x20) {
        pressed = false;
        scheduleDraw();
      }
    } else if (event is WindowResizedEvent ||
        event is WindowScaleChangedEvent) {
      scheduleDraw();
    }
  });

  await drawFrame();

  while (running) {
    if (!backend.pumpEvents(timeout: const Duration(milliseconds: 16))) {
      running = false;
    }
    // Native callbacks enqueue stream events and frame work. Yield after each
    // blocking pump so those asynchronous deliveries cannot starve behind the
    // synchronous message loop.
    await Future<void>.delayed(Duration.zero);
  }

  await pendingDraw;
  presenter.dispose();
  builds.dispose();
  await backend.shutdown();
}
