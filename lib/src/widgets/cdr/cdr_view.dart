import '../../cdr/document/cdr_document.dart';
import '../basic.dart';
import '../proxy.dart';
import '../widget.dart';

class CdrView extends StatelessWidget {
  final CdrDocument document;
  final bool enablePanZoom;
  final int backgroundColor;

  const CdrView({
    super.key,
    required this.document,
    this.enablePanZoom = true,
    this.backgroundColor = 0xFFFFFFFF,
  });

  @override
  Widget build(BuildContext context) {
    final width = document.bounds.width > 0 ? document.bounds.width : 1.0;
    final height = document.bounds.height > 0 ? document.bounds.height : 1.0;
    return ColoredBox(
      color: backgroundColor,
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Text(document.versionName),
        ),
      ),
    );
  }
}
