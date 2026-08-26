// Prova de equivalencia entre os dois ramos do seletor do JPEG.
//
// `jpeg_data.dart` escolhe entre `_jpeg_quantize_io.dart` e
// `_jpeg_quantize_html.dart` por importacao condicional, entao apenas um dos
// dois e compilado em cada alvo e nenhum teste normal ve os dois ao mesmo
// tempo. Este arquivo importa os dois com prefixo e roda o mesmo trabalho nos
// dois, exigindo bytes identicos -- e o pre-requisito que a secao 69.3 do
// roteiro impoe antes de mexer no eixo do seletor.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/graphics/image/codecs/formats/jpeg/_jpeg_quantize_html.dart'
    as html_impl;
import 'package:dart_ui/src/graphics/image/codecs/formats/jpeg/_jpeg_quantize_io.dart'
    as io_impl;
import 'package:dart_ui/src/graphics/image/codecs/formats/jpeg/jpeg_data.dart';
import 'package:dart_ui/src/graphics/image/codecs/image/icc_profile.dart';
import 'package:dart_ui/src/graphics/image/codecs/image_lib.dart' as image_lib;
import 'package:test/test.dart';

/// Gerador deterministico (xorshift de 32 bits) para nao depender de `Random`.
class _Rng {
  _Rng(this._state);
  int _state;

  int next() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  /// Inteiro em `[-bound, bound]`.
  int signed(int bound) => (next() % (2 * bound + 1)) - bound;
}

({Uint8List io, Uint8List html}) _runBothQuantize(
    Int16List quant, Int32List coef) {
  const sentinel = 0xAA;
  final ioOut = Uint8List(64)..fillRange(0, 64, sentinel);
  final htmlOut = Uint8List(64)..fillRange(0, 64, sentinel);
  io_impl.quantizeAndInverse(quant, coef, ioOut, Int32List(64));
  html_impl.quantizeAndInverse(quant, coef, htmlOut, Int32List(64));
  return (io: ioOut, html: htmlOut);
}

image_lib.Image _sourceImage(int width, int height) {
  final image = image_lib.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // Gradientes cruzados para que cada componente de croma tenha conteudo
      // real -- uma imagem chapada decodifica igual em qualquer implementacao.
      image.setPixelRgb(
        x,
        y,
        (x * 255) ~/ (width == 1 ? 1 : width - 1),
        (y * 255) ~/ (height == 1 ? 1 : height - 1),
        ((x + y) * 37) & 0xFF,
      );
    }
  }
  return image;
}

IccProfile _iccProfile() => IccProfile(
      'icc',
      IccProfileCompression.none,
      Uint8List.fromList(List<int>.generate(512, (int i) => (i * 7) & 0xFF)),
    );

void _expectSameDecode(Uint8List jpegBytes, String what) {
  final JpegData jpeg = JpegData()..read(jpegBytes);
  final image_lib.Image fromIo = io_impl.getImageFromJpeg(jpeg);
  final image_lib.Image fromHtml = html_impl.getImageFromJpeg(jpeg);

  expect(fromHtml.width, fromIo.width, reason: '$what: largura');
  expect(fromHtml.height, fromIo.height, reason: '$what: altura');
  expect(fromHtml.numChannels, fromIo.numChannels, reason: '$what: canais');
  expect(fromHtml.toUint8List(), orderedEquals(fromIo.toUint8List()),
      reason: '$what: pixels');
  expect(fromHtml.iccProfile?.data, fromIo.iccProfile?.data,
      reason: '$what: perfil ICC');
  expect(fromHtml.iccProfile?.name, fromIo.iccProfile?.name,
      reason: '$what: nome do perfil ICC');
  expect(fromHtml.exif.imageIfd.orientation, fromIo.exif.imageIfd.orientation,
      reason: '$what: orientacao');
}

void main() {
  group('quantizeAndInverse: os dois ramos produzem os mesmos bytes', () {
    test('blocos aleatorios dentro da faixa de um JPEG valido', () {
      final rng = _Rng(0x2BAD5EED);
      for (var trial = 0; trial < 2000; trial++) {
        final quant = Int16List(64);
        for (var i = 0; i < 64; i++) {
          quant[i] = 1 + (rng.next() % 255);
        }
        final coef = Int32List(64);
        for (var i = 0; i < 64; i++) {
          coef[i] = rng.signed(1023);
        }
        final r = _runBothQuantize(quant, coef);
        expect(r.html, orderedEquals(r.io),
            reason: 'bloco aleatorio #$trial divergiu');
      }
    });

    test('blocos com coeficientes extremos (entrada corrompida)', () {
      // Estes sao os blocos que fazem o indice do clip sair da tabela: e onde
      // o `if (index < 0) break` do ramo `_io` e a indexacao sem guarda do
      // ramo `_html` discordavam.
      final rng = _Rng(0x0BADF00D);
      final quant = Int16List(64)..fillRange(0, 64, 255);
      for (var trial = 0; trial < 500; trial++) {
        final coef = Int32List(64);
        for (var i = 0; i < 64; i++) {
          // Amplitudes muito acima do que um JPEG valido carrega, dos dois
          // lados do zero, para varrer os dois extremos da tabela de clip.
          coef[i] = rng.signed(32767);
        }
        final r = _runBothQuantize(quant, coef);
        expect(r.html, orderedEquals(r.io),
            reason: 'bloco extremo #$trial divergiu');
      }
    });

    test('DC saturado nos dois sentidos', () {
      for (final int dc in <int>[
        -32768,
        -20000,
        -6153,
        -6152,
        6135,
        6136,
        32767
      ]) {
        final quant = Int16List(64)..fillRange(0, 64, 255);
        final coef = Int32List(64)..[0] = dc;
        final r = _runBothQuantize(quant, coef);
        expect(r.html, orderedEquals(r.io), reason: 'DC=$dc divergiu');
      }
    });
  });

  group('getImageFromJpeg: os dois ramos decodificam os mesmos bytes', () {
    test('croma 4:4:4', () {
      _expectSameDecode(
        image_lib.encodeJpg(_sourceImage(37, 23),
            quality: 90, chroma: image_lib.JpegChroma.yuv444),
        '4:4:4',
      );
    });

    test('croma 4:2:0 subamostrado', () {
      for (final (int w, int h) in <(int, int)>[(37, 23), (16, 16), (1, 1)]) {
        _expectSameDecode(
          image_lib.encodeJpg(_sourceImage(w, h),
              quality: 85, chroma: image_lib.JpegChroma.yuv420),
          '4:2:0 ${w}x$h',
        );
      }
    });

    test('com perfil ICC', () {
      final image_lib.Image source = _sourceImage(29, 19)
        ..iccProfile = _iccProfile();
      for (final image_lib.JpegChroma chroma in image_lib.JpegChroma.values) {
        final Uint8List bytes =
            image_lib.encodeJpg(source, quality: 92, chroma: chroma);
        final JpegData jpeg = JpegData()..read(bytes);
        expect(jpeg.iccProfile, isNotNull,
            reason: 'o fixture precisa mesmo carregar um perfil ICC');
        _expectSameDecode(bytes, 'ICC ${chroma.name}');
      }
    });

    test('sem perfil ICC o campo continua nulo nos dois', () {
      final Uint8List bytes = image_lib.encodeJpg(_sourceImage(24, 24),
          quality: 80, chroma: image_lib.JpegChroma.yuv420);
      final JpegData jpeg = JpegData()..read(bytes);
      expect(jpeg.iccProfile, isNull);
      expect(io_impl.getImageFromJpeg(jpeg).iccProfile, isNull);
      expect(html_impl.getImageFromJpeg(jpeg).iccProfile, isNull);
    });

    test('todas as orientacoes EXIF', () {
      for (var orientation = 1; orientation <= 8; orientation++) {
        final image_lib.Image source = _sourceImage(21, 13);
        source.exif.imageIfd.orientation = orientation;
        _expectSameDecode(
          image_lib.encodeJpg(source,
              quality: 88, chroma: image_lib.JpegChroma.yuv420),
          'orientacao $orientation',
        );
      }
    });
  });
}
