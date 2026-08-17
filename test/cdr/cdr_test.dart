import 'dart:typed_data';
import 'package:dart_ui/cdr.dart';
import 'package:test/test.dart';

void main() {
  group('CorelDRAW (CDR / CMX) em Puro Dart', () {
    test('RiffReader analisa contêiner RIFF com FourCC e chunks', () {
      final builder = BytesBuilder();
      // 'RIFF' + length (4 bytes LE) + 'CDR6'
      builder.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
      builder.add([20, 0, 0, 0]); // Length 20
      builder.add([0x43, 0x44, 0x52, 0x36]); // 'CDR6'

      // Subchunk 'vrsn' com tamanho 4 e dados
      builder.add([0x76, 0x72, 0x73, 0x6E]); // 'vrsn'
      builder.add([4, 0, 0, 0]); // Length 4
      builder.add([6, 0, 0, 0]); // Version data 6

      final bytes = builder.takeBytes();
      final reader = RiffReader(bytes);
      final root = reader.parse();

      expect(root.fourCC, 'RIFF');
      expect(root.listType, 'CDR6');
      expect(root.children.length, 1);
      expect(root.children[0].fourCC, 'vrsn');
    });

    test('CdrDocument carrega arquivo RIFF e identifica versão', () {
      final builder = BytesBuilder();
      builder.add([0x52, 0x49, 0x46, 0x46]); // 'RIFF'
      builder.add([16, 0, 0, 0]);
      builder.add([0x43, 0x44, 0x52, 0x38]); // 'CDR8' -> CorelDRAW 8
      builder.add([0x74, 0x65, 0x73, 0x74]); // 'test'
      builder.add([0, 0, 0, 0]);

      final bytes = builder.takeBytes();
      final doc = CdrDocument.fromBytes(bytes);

      expect(doc.version, CdrVersion.v8);
      expect(doc.versionName, 'CorelDRAW 8');
    });

    test('CdrPath reconstrói nós Bézier para Path do dart_ui', () {
      const node1 = CdrNode(type: CdrNodeType.moveTo, x: 0, y: 0);
      const node2 = CdrNode(type: CdrNodeType.lineTo, x: 100, y: 50);
      const node3 = CdrNode(
        type: CdrNodeType.cubicTo,
        x: 200,
        y: 100,
        cx1: 120,
        cy1: 80,
        cx2: 180,
        cy2: 90,
        isClosed: true,
      );

      const cdrPath = CdrPath([node1, node2, node3]);
      final path = cdrPath.toPath();
      expect(path, isNotNull);
      expect(path.bounds.width, closeTo(200.0, 1.0));
      expect(path.bounds.height, closeTo(100.0, 1.0));
    });
  });
}
