import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  test('file filters expose native wildcards and browser accept values', () {
    const FilePickerFilter pdf = FilePickerFilter(
      label: 'PDF documents',
      extensions: <String>['pdf', '.xps'],
    );
    const FilePickerFilter all = FilePickerFilter(
      label: 'All files',
      extensions: <String>['*'],
    );

    expect(pdf.wildcardPattern, '*.pdf;*.xps');
    expect(pdf.accept, '.pdf,.xps');
    expect(all.wildcardPattern, '*.*');
    expect(all.accept, isEmpty);
  });

  test('picked files have one byte-oriented contract on every platform', () {
    final PickedFile file = PickedFile(
      name: 'relatório.pdf',
      path: r'C:\docs\relatório.pdf',
      bytes: Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46]),
    );

    expect(file.name, 'relatório.pdf');
    expect(file.path, endsWith('relatório.pdf'));
    expect(file.size, 4);
  });
}
