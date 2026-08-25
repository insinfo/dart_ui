import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/x509/x509_certificate.dart';
import '../../geometry/rect.dart';
import '../../graphics/image/decoded_image.dart';
import '../../graphics/image/png.dart';
import '../document/pdf_document.dart';
import '../document/pdf_page.dart';
import '../format/pdf_object.dart';
import 'icp_brasil_logo.dart';
import 'pdf_byte_range_signer.dart';
import 'pdf_cms.dart';
import 'pdf_external_signer.dart';

enum PdfSignatureStandard {
  /// PAdES B-B com `/SubFilter /ETSI.CAdES.detached`.
  padesBB,

  /// Reservado para uma futura resposta RFC 3161 incorporada à assinatura.
  padesBT,

  /// Reservado para DSS/VRI (OCSP e CRL) em atualização incremental posterior.
  padesBLT,

  /// CMS destacado tradicional com `/SubFilter /adbe.pkcs7.detached`.
  pkcs7Detached,
}

/// Aparência visual da assinatura em coordenadas da página exibida (top-left).
final class PdfSignatureAppearance {
  PdfSignatureAppearance({
    required this.pageNumber,
    required this.rect,
    required this.signerName,
    this.reason = 'Concordo com os termos deste documento',
    this.location,
    String? cpf,
    this.validatorUrl = 'https://validar.iti.gov.br/',
    this.headline = 'DOCUMENTO ASSINADO DIGITALMENTE',
    this.logoPngBytes,
    DateTime? signingTime,
    this.borderColor = 0xFF2563EB,
    this.backgroundColor = 0xFFF8FAFC,
  })  : maskedCpf = maskBrazilianCpf(cpf),
        signingTime = signingTime ?? DateTime.now();

  /// Aparência oficial brasileira, com logo ICP-Brasil congelado localmente.
  factory PdfSignatureAppearance.icpBrasil({
    required int pageNumber,
    required Rect rect,
    required String signerName,
    String? cpf,
    String? reason = 'Assinatura Digital de Documento',
    String? location,
    DateTime? signingTime,
    String validatorUrl = 'https://validar.iti.gov.br/',
  }) =>
      PdfSignatureAppearance(
        pageNumber: pageNumber,
        rect: rect,
        signerName: signerName,
        cpf: cpf,
        reason: reason,
        location: location,
        signingTime: signingTime,
        validatorUrl: validatorUrl,
        logoPngBytes: icpBrasilLogoPngBytes(),
        borderColor: 0xFF079447,
        backgroundColor: 0xFFFFFFFF,
      );

  final int pageNumber;
  final Rect rect;
  final String signerName;
  final String? reason;
  final String? location;
  final String? maskedCpf;
  final String validatorUrl;
  final String headline;
  final Uint8List? logoPngBytes;
  final DateTime signingTime;
  final int borderColor;
  final int backgroundColor;

  PdfSignatureAppearance copyWith({
    String? signerName,
    DateTime? signingTime,
  }) =>
      PdfSignatureAppearance(
        pageNumber: pageNumber,
        rect: rect,
        signerName: signerName ?? this.signerName,
        cpf: maskedCpf,
        reason: reason,
        location: location,
        signingTime: signingTime ?? this.signingTime,
        validatorUrl: validatorUrl,
        headline: headline,
        logoPngBytes: logoPngBytes,
        borderColor: borderColor,
        backgroundColor: backgroundColor,
      );
}

final class PdfSignatureException implements Exception {
  const PdfSignatureException(this.message);
  final String message;

  @override
  String toString() => 'PdfSignatureException: $message';
}

/// Assinador incremental PAdES/CMS cuja chave é fornecida por uma interface
/// externa (PKCS#11, HSM, serviço remoto ou callback de teste).
final class PdfSigner {
  PdfSigner({
    required this.document,
    required this.signerName,
    this.reason = 'Assinatura Digital de Documento',
    this.location,
    this.standard = PdfSignatureStandard.padesBB,
    DateTime? signingTime,
  }) : signingTime = signingTime ?? DateTime.now();

  final PdfDocument document;
  final String signerName;
  final String? reason;
  final String? location;
  final PdfSignatureStandard standard;
  final DateTime signingTime;
  PdfSignatureAppearance? appearance;

  void setVisualAppearance(PdfSignatureAppearance value) {
    appearance = value.copyWith(
      signerName: signerName,
      signingTime: signingTime,
    );
  }

  /// Prepara AcroForm, widget, dicionário `/Sig`, aparência e `/ByteRange`.
  ///
  /// O resultado ainda não contém CMS e pode ser entregue a um processo de
  /// assinatura remota por meio de [PdfPreparedSignature.documentDigest].
  PdfPreparedSignature prepare({int reservedSignatureBytes = 32768}) {
    if (reservedSignatureBytes < 1024) {
      throw ArgumentError.value(
        reservedSignatureBytes,
        'reservedSignatureBytes',
        'must reserve at least 1024 bytes',
      );
    }
    if (standard == PdfSignatureStandard.padesBT ||
        standard == PdfSignatureStandard.padesBLT) {
      throw PdfSignatureException(
        '$standard requires RFC 3161/LTV data; use padesBB until a '
        'timestamp/revocation provider is configured',
      );
    }
    return _PdfIncrementalSignatureWriter(
      document: document,
      signerName: signerName,
      reason: reason,
      location: location,
      standard: standard,
      signingTime: signingTime,
      appearance: appearance,
      reservedSignatureBytes: reservedSignatureBytes,
    ).prepare();
  }

  /// Executa o fluxo completo sem jamais receber a chave privada.
  Future<Uint8List> sign({
    required PdfExternalSigner externalSigner,
    int reservedSignatureBytes = 32768,
  }) async {
    if (externalSigner.certificateChain.isEmpty) {
      throw const PdfSignatureException(
        'the external signer returned an empty certificate chain',
      );
    }
    final certificate = X509Certificate.parse(
      externalSigner.certificateChain.first,
    );
    if (!certificate.isValidAt(signingTime)) {
      throw PdfSignatureException(
        'signer certificate is not valid at ${signingTime.toUtc()}',
      );
    }
    final prepared = prepare(
      reservedSignatureBytes: reservedSignatureBytes,
    );
    final request = PdfCmsBuilder.createSigningRequest(
      documentDigest: prepared.documentDigest,
      signerCertificate: certificate.derBytes,
      signingTime: signingTime,
    );
    final signature = await externalSigner.sign(
      request.authenticatedAttributesDer,
    );
    if (signature.isEmpty) {
      throw const PdfSignatureException(
        'the external signer returned an empty signature',
      );
    }
    final cms = PdfCmsBuilder.buildDetachedSignedData(
      request: request,
      signature: signature,
      certificateChain: externalSigner.certificateChain,
      algorithm: externalSigner.algorithm,
    );
    return prepared.embed(cms);
  }
}

final class _PdfIncrementalSignatureWriter {
  _PdfIncrementalSignatureWriter({
    required this.document,
    required this.signerName,
    required this.reason,
    required this.location,
    required this.standard,
    required this.signingTime,
    required this.appearance,
    required this.reservedSignatureBytes,
  });

  final PdfDocument document;
  final String signerName;
  final String? reason;
  final String? location;
  final PdfSignatureStandard standard;
  final DateTime signingTime;
  final PdfSignatureAppearance? appearance;
  final int reservedSignatureBytes;

  PdfPreparedSignature prepare() {
    final trailer = document.xref.trailer;
    if (trailer == null) {
      throw const PdfSignatureException('PDF has no trailer');
    }
    if (trailer.containsKey('Encrypt')) {
      throw const PdfSignatureException(
        'encrypted PDFs must be decrypted before signing',
      );
    }
    final rootReference = trailer['Root'];
    if (rootReference is! PdfRef) {
      throw const PdfSignatureException(
        'incremental signing requires an indirect catalog',
      );
    }
    final catalog = document.xref.resolveRef(rootReference);
    if (catalog is! PdfDict) {
      throw const PdfSignatureException('PDF catalog could not be resolved');
    }

    final selectedPageNumber = appearance?.pageNumber ?? 1;
    final page = document.getPage(selectedPageNumber);
    final pageReference = page.reference;
    if (pageReference == null) {
      throw const PdfSignatureException(
        'incremental signing requires an indirect page dictionary',
      );
    }
    final originalPage = document.xref.resolveRef(pageReference);
    if (originalPage is! PdfDict) {
      throw const PdfSignatureException('PDF page could not be resolved');
    }

    final oldSize = trailer.getNumber('Size')?.toInt() ?? 0;
    final highest = document.xref.entries.keys.fold<int>(
      oldSize > 0 ? oldSize - 1 : 0,
      (value, object) => object > value ? object : value,
    );
    var nextObject = highest + 1;
    final signatureReference = PdfRef(nextObject++, 0);
    final widgetReference = PdfRef(nextObject++, 0);
    final acroFormReference = PdfRef(nextObject++, 0);
    final appearanceReference =
        appearance == null ? null : PdfRef(nextObject++, 0);
    final linkReference = appearance == null || appearance!.validatorUrl.isEmpty
        ? null
        : PdfRef(nextObject++, 0);
    final logo = appearance?.logoPngBytes == null
        ? null
        : _decodeAppearanceLogo(appearance!.logoPngBytes!);
    final logoReference = logo == null ? null : PdfRef(nextObject++, 0);
    final logoMaskReference =
        logo?.hasAlpha == true ? PdfRef(nextObject++, 0) : null;

    final acroForm = _updatedAcroForm(catalog, widgetReference);
    final updatedCatalog = PdfDict(Map<String, PdfObject>.from(catalog.entries))
      ..['AcroForm'] = acroFormReference;
    final updatedPage = _updatedPage(originalPage, <PdfRef>[
      widgetReference,
      if (linkReference != null) linkReference,
    ]);
    final widget = _signatureWidget(
      page,
      pageReference,
      signatureReference,
      appearanceReference,
      'Signature${signatureReference.objNum}',
    );

    final output = BytesBuilder(copy: false)..add(document.rawBytes);
    if (document.rawBytes.isNotEmpty && document.rawBytes.last != 0x0a) {
      output.addByte(0x0a);
    }
    final offsets = <PdfRef, int>{};
    void addObject(PdfRef reference, Uint8List body) {
      offsets[reference] = output.length;
      output
        ..add(ascii.encode('${reference.objNum} ${reference.genNum} obj\n'))
        ..add(body)
        ..add(ascii.encode('\nendobj\n'));
    }

    final placeholder = '0' * (reservedSignatureBytes * 2);
    final byteRangePlaceholder =
        '/ByteRange [0 ${'0' * 20} ${'0' * 20} ${'0' * 20}]';
    final signatureDictionary = StringBuffer()
      ..write('<< /Type /Sig /Filter /Adobe.PPKLite ')
      ..write(
          '/SubFilter /${standard == PdfSignatureStandard.padesBB ? 'ETSI.CAdES.detached' : 'adbe.pkcs7.detached'} ')
      ..write('$byteRangePlaceholder ')
      ..write('/Contents <$placeholder> ')
      ..write('/Name ${_pdfText(signerName)} ')
      ..write('/M ${_pdfText(_pdfDate(signingTime))} ');
    if (reason != null && reason!.isNotEmpty) {
      signatureDictionary.write('/Reason ${_pdfText(reason!)} ');
    }
    if (location != null && location!.isNotEmpty) {
      signatureDictionary.write('/Location ${_pdfText(location!)} ');
    }
    signatureDictionary.write('>>');

    addObject(signatureReference, ascii.encode(signatureDictionary.toString()));
    addObject(widgetReference, ascii.encode(_serialize(widget)));
    if (linkReference != null) {
      addObject(
        linkReference,
        ascii.encode(_serialize(_validatorLink(
          page,
          pageReference,
          appearance!,
        ))),
      );
    }
    addObject(acroFormReference, ascii.encode(_serialize(acroForm)));
    if (logoReference != null) {
      addObject(
        logoReference,
        _logoImageStream(logo!, logoMaskReference),
      );
    }
    if (logoMaskReference != null) {
      addObject(logoMaskReference, _logoMaskStream(logo!));
    }
    if (appearanceReference != null) {
      addObject(
        appearanceReference,
        _appearanceStream(appearance!, logoReference),
      );
    }
    addObject(rootReference, ascii.encode(_serialize(updatedCatalog)));
    if (pageReference != rootReference) {
      addObject(pageReference, ascii.encode(_serialize(updatedPage)));
    }

    final xrefOffset = output.length;
    final xref = StringBuffer('xref\n');
    final orderedOffsets = offsets.entries.toList()
      ..sort((a, b) => a.key.objNum.compareTo(b.key.objNum));
    for (final entry in orderedOffsets) {
      xref
        ..writeln('${entry.key.objNum} 1')
        ..writeln(
          '${entry.value.toString().padLeft(10, '0')} '
          '${entry.key.genNum.toString().padLeft(5, '0')} n ',
        );
    }
    xref.write('trailer\n<< /Size $nextObject /Root $rootReference');
    for (final key in const <String>['Info', 'ID']) {
      final value = trailer[key];
      if (value != null) {
        xref.write(' /$key ${_serialize(value)}');
      }
    }
    final previousXref = _findStartXref(document.rawBytes);
    if (previousXref < 0) {
      throw const PdfSignatureException('PDF startxref could not be found');
    }
    xref
      ..write(' /Prev $previousXref >>\n')
      ..write('startxref\n$xrefOffset\n%%EOF\n');
    output.add(ascii.encode(xref.toString()));

    final bytes = output.takeBytes();
    final contentsMarker = ascii.encode('/Contents <');
    final contentsMarkerOffset = _lastIndexOf(bytes, contentsMarker);
    final byteRangeOffset =
        _lastIndexOf(bytes, ascii.encode(byteRangePlaceholder));
    if (contentsMarkerOffset < 0 || byteRangeOffset < 0) {
      throw const PdfSignatureException('signature placeholders were lost');
    }
    final contentsHexOffset = contentsMarkerOffset + contentsMarker.length;
    final excludedStart = contentsHexOffset - 1;
    final excludedLength = reservedSignatureBytes * 2 + 2;
    final range = const PdfByteRangeSigner().calculateByteRange(
      bytes,
      excludedStart,
      excludedLength,
    );
    final actualByteRange =
        '/ByteRange [0 ${range[1]} ${range[2]} ${range[3]}]';
    if (actualByteRange.length > byteRangePlaceholder.length) {
      throw const PdfSignatureException(
          'PDF is too large for ByteRange fields');
    }
    final replacement = ascii.encode(
      actualByteRange.padRight(byteRangePlaceholder.length, ' '),
    );
    bytes.setRange(
      byteRangeOffset,
      byteRangeOffset + replacement.length,
      replacement,
    );
    return PdfPreparedSignature(
      bytes: bytes,
      byteRange: range,
      contentsHexOffset: contentsHexOffset,
      reservedSignatureBytes: reservedSignatureBytes,
    );
  }

  PdfDict _updatedAcroForm(PdfDict catalog, PdfRef widgetReference) {
    final raw = catalog['AcroForm'];
    final resolved = raw is PdfRef ? document.xref.resolveRef(raw) : raw;
    final result = resolved is PdfDict
        ? PdfDict(Map<String, PdfObject>.from(resolved.entries))
        : PdfDict();
    final rawFields = result['Fields'];
    final resolvedFields =
        rawFields is PdfRef ? document.xref.resolveRef(rawFields) : rawFields;
    final fields = resolvedFields is PdfArray
        ? List<PdfObject>.from(resolvedFields.elements)
        : <PdfObject>[];
    fields.add(widgetReference);
    result
      ..['Fields'] = PdfArray(fields)
      ..['SigFlags'] = const PdfNumber(3);
    return result;
  }

  PdfDict _updatedPage(PdfDict page, List<PdfRef> newAnnotations) {
    final result = PdfDict(Map<String, PdfObject>.from(page.entries));
    final rawAnnots = result['Annots'];
    final resolvedAnnots =
        rawAnnots is PdfRef ? document.xref.resolveRef(rawAnnots) : rawAnnots;
    final annotations = resolvedAnnots is PdfArray
        ? List<PdfObject>.from(resolvedAnnots.elements)
        : <PdfObject>[];
    annotations.addAll(newAnnotations);
    result['Annots'] = PdfArray(annotations);
    return result;
  }

  PdfDict _signatureWidget(
    PdfPage page,
    PdfRef pageReference,
    PdfRef signatureReference,
    PdfRef? appearanceReference,
    String fieldName,
  ) {
    final visual = appearance;
    final rect = visual == null
        ? const Rect.fromLTWH(0, 0, 0, 0)
        : _toPdfRect(page, visual.rect);
    return PdfDict(<String, PdfObject>{
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Widget'),
      'FT': const PdfName('Sig'),
      'F': const PdfNumber(4),
      'T': PdfString.fromString(fieldName),
      'V': signatureReference,
      'P': pageReference,
      'Rect': PdfArray(<PdfObject>[
        PdfNumber(rect.left),
        PdfNumber(rect.top),
        PdfNumber(rect.right),
        PdfNumber(rect.bottom),
      ]),
      if (appearanceReference != null)
        'AP': PdfDict(<String, PdfObject>{'N': appearanceReference}),
    });
  }

  Rect _toPdfRect(PdfPage page, Rect displayed) {
    final box = page.cropBox;
    if (displayed.isEmpty ||
        displayed.left < 0 ||
        displayed.top < 0 ||
        displayed.right > page.width ||
        displayed.bottom > page.height) {
      throw PdfSignatureException(
        'visual signature rectangle $displayed is outside page '
        '${page.pageNumber} (${page.width} x ${page.height})',
      );
    }
    return switch ((page.rotation % 360 + 360) % 360) {
      0 => Rect.fromLTRB(
          box.left + displayed.left,
          box.bottom - displayed.bottom,
          box.left + displayed.right,
          box.bottom - displayed.top,
        ),
      90 => Rect.fromLTRB(
          box.left + displayed.top,
          box.top + displayed.left,
          box.left + displayed.bottom,
          box.top + displayed.right,
        ),
      180 => Rect.fromLTRB(
          box.right - displayed.right,
          box.top + displayed.top,
          box.right - displayed.left,
          box.top + displayed.bottom,
        ),
      270 => Rect.fromLTRB(
          box.right - displayed.bottom,
          box.bottom - displayed.right,
          box.right - displayed.top,
          box.bottom - displayed.left,
        ),
      _ => throw PdfSignatureException(
          'unsupported PDF page rotation ${page.rotation}',
        ),
    };
  }

  PdfDict _validatorLink(
    PdfPage page,
    PdfRef pageReference,
    PdfSignatureAppearance appearance,
  ) {
    final local = Rect.fromLTWH(
      appearance.logoPngBytes == null ? 8 : appearance.rect.height * 0.82,
      appearance.rect.height - 17,
      appearance.rect.width -
          (appearance.logoPngBytes == null ? 16 : appearance.rect.height * 0.9),
      13,
    );
    final displayed = Rect.fromLTWH(
      appearance.rect.left + local.left,
      appearance.rect.top + local.top,
      local.width,
      local.height,
    );
    final rect = _toPdfRect(page, displayed);
    return PdfDict(<String, PdfObject>{
      'Type': const PdfName('Annot'),
      'Subtype': const PdfName('Link'),
      'P': pageReference,
      'Rect': PdfArray(<PdfObject>[
        PdfNumber(rect.left),
        PdfNumber(rect.top),
        PdfNumber(rect.right),
        PdfNumber(rect.bottom),
      ]),
      'Border': const PdfArray(<PdfObject>[
        PdfNumber(0),
        PdfNumber(0),
        PdfNumber(0),
      ]),
      'A': PdfDict(<String, PdfObject>{
        'S': const PdfName('URI'),
        'URI': PdfString.fromString(appearance.validatorUrl),
      }),
    });
  }

  Uint8List _appearanceStream(
    PdfSignatureAppearance appearance,
    PdfRef? logoReference,
  ) {
    final width = appearance.rect.width;
    final height = appearance.rect.height;
    final background = _rgb(appearance.backgroundColor);
    final border = _rgb(appearance.borderColor);
    final textX = logoReference == null ? 10.0 : height * 0.82;
    final availableTextWidth = width - textX - 8;
    final compact = height < 70;
    final headlineSize = compact ? 6.2 : 7.5;
    final nameSize = compact ? 8.0 : 10.0;
    final detailSize = compact ? 5.9 : 7.2;
    final lines = <String>[
      'q',
      '${background.$1} ${background.$2} ${background.$3} rg',
      '0 0 ${_number(width)} ${_number(height)} re f',
      if (logoReference != null)
        'q ${_number(height * 0.54)} 0 0 ${_number(height * 0.62)} '
            '${_number(height * 0.13)} ${_number(height * 0.18)} cm /Logo Do Q',
      '${border.$1} ${border.$2} ${border.$3} rg',
      'BT /HelvBold ${_number(headlineSize)} Tf ${_number(textX)} ${_number(height - (compact ? 9 : 13))} Td '
          '(${_literal(_fitText(appearance.headline, availableTextWidth, headlineSize))}) Tj ET',
      '0.08 0.12 0.18 rg',
      'BT /HelvBold ${_number(nameSize)} Tf ${_number(textX)} ${_number(height - (compact ? 20 : 28))} Td '
          '(${_literal(_fitText(appearance.signerName, availableTextWidth, nameSize))}) Tj ET',
      if (appearance.maskedCpf != null)
        'BT /Helv ${_number(detailSize)} Tf ${_number(textX)} ${_number(height - (compact ? 30 : 41))} Td '
            '(${_literal('CPF: ${appearance.maskedCpf}')}) Tj ET',
      'BT /Helv ${_number(detailSize)} Tf ${_number(textX)} ${_number(height - (appearance.maskedCpf == null ? (compact ? 30 : 41) : (compact ? 39 : 53)))} Td '
          '(${_literal('Data: ${_humanDate(appearance.signingTime)}')}) Tj ET',
      '0.02 0.35 0.72 rg',
      'BT /Helv ${_number(compact ? 5.8 : 7)} Tf ${_number(textX)} 7 Td '
          '(${_literal(_fitText('Valide em ${appearance.validatorUrl}', availableTextWidth, compact ? 5.8 : 7))}) Tj ET',
      'Q',
    ];
    final stream = latin1.encode(lines.join('\n'));
    final dictionary = '<< /Type /XObject /Subtype /Form /FormType 1 '
        '/BBox [0 0 ${_number(width)} ${_number(height)}] '
        '/Resources << /Font << /Helv << /Type /Font /Subtype /Type1 '
        '/BaseFont /Helvetica /Encoding /WinAnsiEncoding >> '
        '/HelvBold << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold '
        '/Encoding /WinAnsiEncoding >> >> '
        '${logoReference == null ? '' : '/XObject << /Logo $logoReference >> '}>> '
        '/Length ${stream.length} >>\nstream\n';
    return Uint8List.fromList(<int>[
      ...ascii.encode(dictionary),
      ...stream,
      ...ascii.encode('\nendstream'),
    ]);
  }

  Uint8List _logoImageStream(_PdfAppearanceLogo logo, PdfRef? maskReference) {
    final dictionary = '<< /Type /XObject /Subtype /Image '
        '/Width ${logo.width} /Height ${logo.height} '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 '
        '${maskReference == null ? '' : '/SMask $maskReference '}'
        '/Length ${logo.rgb.length} >>\nstream\n';
    return Uint8List.fromList(<int>[
      ...ascii.encode(dictionary),
      ...logo.rgb,
      ...ascii.encode('\nendstream'),
    ]);
  }

  Uint8List _logoMaskStream(_PdfAppearanceLogo logo) {
    final dictionary = '<< /Type /XObject /Subtype /Image '
        '/Width ${logo.width} /Height ${logo.height} '
        '/ColorSpace /DeviceGray /BitsPerComponent 8 '
        '/Length ${logo.alpha.length} >>\nstream\n';
    return Uint8List.fromList(<int>[
      ...ascii.encode(dictionary),
      ...logo.alpha,
      ...ascii.encode('\nendstream'),
    ]);
  }
}

final class _PdfAppearanceLogo {
  const _PdfAppearanceLogo({
    required this.width,
    required this.height,
    required this.rgb,
    required this.alpha,
    required this.hasAlpha,
  });

  final int width;
  final int height;
  final Uint8List rgb;
  final Uint8List alpha;
  final bool hasAlpha;
}

_PdfAppearanceLogo _decodeAppearanceLogo(Uint8List bytes) {
  final decoded = decodePng(bytes, order: ImageChannelOrder.rgba);
  // A aparência exibe o logo com poucas dezenas de pontos. Limitar o XObject
  // evita acrescentar centenas de KiB a cada coassinatura sem ganho visual.
  final image = decoded.height > 96
      ? decoded.resample(
          width: (decoded.width * 96 / decoded.height).round(),
          height: 96,
        )
      : decoded;
  final rgb = Uint8List(image.width * image.height * 3);
  final alpha = Uint8List(image.width * image.height);
  for (var source = 0, color = 0, mask = 0;
      source < image.pixels.length;
      source += 4, color += 3, mask++) {
    final a = image.pixels[source + 3];
    alpha[mask] = a;
    int straight(int channel) => a == 0
        ? 0
        : ((image.pixels[source + channel] * 255 + a ~/ 2) ~/ a).clamp(0, 255);
    rgb[color] = straight(0);
    rgb[color + 1] = straight(1);
    rgb[color + 2] = straight(2);
  }
  return _PdfAppearanceLogo(
    width: image.width,
    height: image.height,
    rgb: rgb,
    alpha: alpha,
    hasAlpha: image.hasAlpha,
  );
}

String _serialize(PdfObject object) {
  if (object is PdfNull) return 'null';
  if (object is PdfBoolean) return object.value ? 'true' : 'false';
  if (object is PdfNumber) return _number(object.value);
  if (object is PdfName) return '/${_name(object.name)}';
  if (object is PdfRef) return object.toString();
  if (object is PdfString) {
    final hex = object.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '<$hex>';
  }
  if (object is PdfArray) {
    return '[${object.elements.map(_serialize).join(' ')}]';
  }
  if (object is PdfDict) {
    return '<< ${object.entries.entries.map((entry) => '/${_name(entry.key)} ${_serialize(entry.value)}').join(' ')} >>';
  }
  throw PdfSignatureException(
    'cannot serialize ${object.runtimeType} in an incremental dictionary',
  );
}

String _name(String value) {
  const delimiters = <int>{
    0x00,
    0x09,
    0x0a,
    0x0c,
    0x0d,
    0x20,
    0x23,
    0x25,
    0x28,
    0x29,
    0x2f,
    0x3c,
    0x3e,
    0x5b,
    0x5d,
    0x7b,
    0x7d,
  };
  final result = StringBuffer();
  for (final byte in utf8.encode(value)) {
    if (byte < 0x21 || byte > 0x7e || delimiters.contains(byte)) {
      result.write('#${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    } else {
      result.writeCharCode(byte);
    }
  }
  return result.toString();
}

String _pdfText(String value) {
  final bytes = <int>[0xfe, 0xff];
  for (final unit in value.codeUnits) {
    bytes
      ..add(unit >> 8)
      ..add(unit & 0xff);
  }
  return '<${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}>';
}

String _literal(String value) {
  final latin = latin1.encode(value.replaceAll(RegExp(r'[^\x00-\xff]'), '?'));
  final result = StringBuffer();
  for (final byte in latin) {
    if (byte == 0x28 || byte == 0x29 || byte == 0x5c) {
      result.write('\\');
    }
    result.writeCharCode(byte);
  }
  return result.toString();
}

String _number(num value) {
  if (value is int || value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _pdfDate(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return 'D:${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
      '${two(utc.day)}${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
}

String _humanDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final totalMinutes = offset.inMinutes.abs();
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)} '
      '$sign${two(totalMinutes ~/ 60)}:${two(totalMinutes % 60)}';
}

String _fitText(String value, double width, double fontSize) {
  final maximum =
      (width / (fontSize * 0.54)).floor().clamp(4, value.length).toInt();
  if (value.length <= maximum) return value;
  return '${value.substring(0, maximum - 3).trimRight()}...';
}

(String, String, String) _rgb(int argb) {
  String channel(int shift) =>
      (((argb >> shift) & 0xff) / 255).toStringAsFixed(4);
  return (channel(16), channel(8), channel(0));
}

int _lastIndexOf(Uint8List bytes, Uint8List pattern) {
  for (var i = bytes.length - pattern.length; i >= 0; i--) {
    var matches = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

int _findStartXref(Uint8List bytes) {
  final marker = ascii.encode('startxref');
  final offset = _lastIndexOf(bytes, marker);
  if (offset < 0) return -1;
  var cursor = offset + marker.length;
  while (cursor < bytes.length &&
      (bytes[cursor] == 0x20 ||
          bytes[cursor] == 0x0a ||
          bytes[cursor] == 0x0d)) {
    cursor++;
  }
  var value = 0;
  var found = false;
  while (
      cursor < bytes.length && bytes[cursor] >= 0x30 && bytes[cursor] <= 0x39) {
    found = true;
    value = value * 10 + bytes[cursor] - 0x30;
    cursor++;
  }
  return found ? value : -1;
}
