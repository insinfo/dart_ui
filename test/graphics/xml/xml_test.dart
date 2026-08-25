import 'package:dart_ui/src/graphics/xml/xml.dart';
import 'package:test/test.dart';

/// Analisa [source] esperando um documento mal formado, e devolve a excecao
/// para que o teste possa olhar mensagem, linha e coluna.
XmlParserException _erro(String source) {
  try {
    XmlDocument.parse(source);
  } on XmlParserException catch (e) {
    return e;
  }
  fail('esperava XmlParserException para: $source');
}

Matcher get _malFormado => throwsA(isA<XmlParserException>());

void main() {
  group('estrutura', () {
    test('elementos aninhados, self-closing e as duas aspas', () {
      final XmlDocument document = XmlDocument.parse(
        '<raiz a="1" b=\'2\'><vazio/><filho>texto</filho></raiz>',
      );
      final XmlElement root = document.rootElement;

      expect(root.name.local, 'raiz');
      expect(root.name.prefix, isNull);
      expect(root.name.qualified, 'raiz');
      expect(root.getAttribute('a'), '1');
      expect(root.getAttribute('b'), '2');
      expect(root.attributes, hasLength(2));
      expect(root.attributes.first.toString(), 'a="1"');
      expect(root.toString(), '<raiz>');

      expect(root.childElements, hasLength(2));
      final XmlElement vazio = root.childElements.first;
      expect(vazio.name.local, 'vazio');
      expect(vazio.children, isEmpty);
      expect(vazio.innerText, isEmpty);
      expect(root.childElements.last.innerText, 'texto');
    });

    test('self-closing com espaco antes da barra', () {
      final XmlElement root =
          XmlDocument.parse('<raiz><vazio a="1" /></raiz>').rootElement;
      expect(root.childElements.single.getAttribute('a'), '1');
      expect(root.childElements.single.children, isEmpty);
    });

    test('end tag aceita espaco antes do ">"', () {
      expect(
        XmlDocument.parse('<raiz></raiz  >').rootElement.name.local,
        'raiz',
      );
    });

    test('children mistura texto e elementos na ordem do documento', () {
      final XmlElement root =
          XmlDocument.parse('<raiz>a<b/>c<d/>e</raiz>').rootElement;
      expect(root.children, hasLength(5));
      expect(root.children[0], isA<XmlText>());
      expect((root.children[0] as XmlText).value, 'a');
      expect(root.children[1], isA<XmlElement>());
      expect(root.children[3], isA<XmlElement>());
      expect((root.children[4] as XmlText).value, 'e');
      expect(root.childElements, hasLength(2));
    });

    test('innerText concatena todos os descendentes', () {
      final XmlDocument document =
          XmlDocument.parse('<a>1<b>2<c>3</c>4</b>5</a>');
      expect(document.rootElement.innerText, '12345');
      expect(document.innerText, '12345');
      expect(document.rootElement.findElements('b').single.innerText, '234');
    });

    test('findElements olha so os filhos diretos e usa o nome qualificado', () {
      final XmlDocument document = XmlDocument.parse(
        '<raiz><item/><outro><item/></outro><item/></raiz>',
      );
      expect(document.rootElement.findElements('item'), hasLength(2));
      expect(document.rootElement.findElements('nada'), isEmpty);
      expect(document.findElements('raiz'), hasLength(1));
      expect(document.findElements('item'), isEmpty);
      expect(document.children, hasLength(1));
    });

    test('texto nao tem filhos', () {
      final XmlText text =
          XmlDocument.parse('<a>oi</a>').rootElement.children.single as XmlText;
      expect(text.children, isEmpty);
      expect(text.innerText, 'oi');
      expect(text.toString(), 'oi');
    });
  });

  group('namespaces sintaticos', () {
    test('prefixo e local sao separados e xmlns e atributo comum', () {
      final XmlDocument document = XmlDocument.parse(
        '<svg:svg xmlns:svg="http://www.w3.org/2000/svg" xmlns="urn:x">'
        '<svg:rect/></svg:svg>',
      );
      final XmlElement root = document.rootElement;
      expect(root.name.prefix, 'svg');
      expect(root.name.local, 'svg');
      expect(root.name.qualified, 'svg:svg');
      expect(root.getAttribute('xmlns:svg'), 'http://www.w3.org/2000/svg');
      expect(root.getAttribute('xmlns'), 'urn:x');
      expect(root.getAttribute('svg'), isNull);
      expect(root.attributes.first.name.prefix, 'xmlns');
      expect(root.attributes.first.name.local, 'svg');
      expect(root.attributes.last.name.prefix, isNull);

      final XmlElement rect = root.childElements.single;
      expect(rect.name.prefix, 'svg');
      expect(rect.name.local, 'rect');
      expect(root.findElements('svg:rect'), hasLength(1));
      expect(root.findElements('rect'), isEmpty);
    });

    test('getAttribute casa o nome qualificado inteiro', () {
      final XmlElement root =
          XmlDocument.parse('<use xlink:href="#alvo" href="#outro"/>')
              .rootElement;
      expect(root.getAttribute('xlink:href'), '#alvo');
      expect(root.getAttribute('href'), '#outro');
      expect(root.getAttribute('xlink'), isNull);
      expect(root.attributes.first.name.prefix, 'xlink');
      expect(root.attributes.first.name.local, 'href');
    });
  });

  group('prolog', () {
    test('declaracao xml, comentario, doctype e PI antes e depois do root', () {
      final XmlDocument document = XmlDocument.parse('''
<?xml version="1.0" encoding="utf-8"?>
<!-- um comentario -->
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<?instrucao dado="1"?>
<svg width="10"/>
<?depois do root?>
<!-- fim -->
''');
      expect(document.rootElement.name.local, 'svg');
      expect(document.rootElement.getAttribute('width'), '10');
      // Comentarios, PIs e o DOCTYPE nao viram nos: so o root sobra.
      expect(document.children, hasLength(1));
      expect(document.toString(), '<?xml?><svg>');
    });

    test('DOCTYPE com subset interno e ignorado por inteiro', () {
      final XmlDocument document = XmlDocument.parse('''
<!DOCTYPE nota [
  <!ELEMENT nota (#PCDATA)>
  <!ATTLIST nota id CDATA #IMPLIED>
  <!ENTITY exemplo "texto">
]>
<nota id="1">oi</nota>
''');
      expect(document.rootElement.name.local, 'nota');
      expect(document.rootElement.getAttribute('id'), '1');
      expect(document.rootElement.innerText, 'oi');
    });

    test('DOCTYPE sem subset', () {
      expect(
        XmlDocument.parse('<!DOCTYPE nota><nota/>').rootElement.name.local,
        'nota',
      );
    });

    test('comentarios e PIs dentro do elemento nao entram no texto', () {
      final XmlElement root =
          XmlDocument.parse('<a>x<!-- c -->y<?pi dado?>z</a>').rootElement;
      expect(root.innerText, 'xyz');
      // Cada comentario/PI corta o texto em um no novo.
      expect(root.children, hasLength(3));
      expect(root.childElements, isEmpty);
    });
  });

  group('CDATA', () {
    test('mantem "<" e "&" literais', () {
      final XmlElement root = XmlDocument.parse(
        '<a><![CDATA[if (x < y && y > z) { p("&amp;"); }]]></a>',
      ).rootElement;
      expect(root.innerText, 'if (x < y && y > z) { p("&amp;"); }');
      expect(root.children, hasLength(1));
      expect(root.childElements, isEmpty);
    });

    test('cola com o texto vizinho num unico no', () {
      final XmlElement root =
          XmlDocument.parse('<a>x<![CDATA[<b/>&y]]>z</a>').rootElement;
      expect(root.children, hasLength(1));
      expect(root.innerText, 'x<b/>&yz');
    });

    test('"]]" solto nao encerra a secao', () {
      expect(
        XmlDocument.parse('<a><![CDATA[a]]b]]></a>').rootElement.innerText,
        'a]]b',
      );
    });

    test('secao vazia nao gera no de texto', () {
      final XmlElement root =
          XmlDocument.parse('<a><![CDATA[]]></a>').rootElement;
      expect(root.children, isEmpty);
      expect(root.innerText, isEmpty);
    });
  });

  group('referencias', () {
    test('as cinco entidades predefinidas, em texto e em atributo', () {
      final XmlElement root = XmlDocument.parse(
        '<a t="&lt;&gt;&amp;&quot;&apos;">&lt;&gt;&amp;&quot;&apos;</a>',
      ).rootElement;
      expect(root.getAttribute('t'), '<>&"\'');
      expect(root.innerText, '<>&"\'');
    });

    test('referencias numericas decimais e hexadecimais', () {
      final XmlElement root = XmlDocument.parse(
        '<a t="&#65;&#x42;&#x63;">&#65;&#x42;&#x63;</a>',
      ).rootElement;
      expect(root.innerText, 'ABc');
      expect(root.getAttribute('t'), 'ABc');
    });

    test('code point acima de 0xFFFF vira par surrogate', () {
      final XmlElement root =
          XmlDocument.parse('<a t="&#x1F600;">&#128512;</a>').rootElement;
      expect(root.innerText, '\u{1F600}');
      expect(root.innerText.runes, hasLength(1));
      expect(root.innerText.length, 2,
          reason: 'par surrogate ocupa 2 unidades');
      expect(root.getAttribute('t'), root.innerText);
      expect(
        XmlDocument.parse('<a>&#x10FFFF;</a>').rootElement.innerText.runes,
        hasLength(1),
      );
    });

    test('"&#38;" nao e reinterpretado como inicio de entidade', () {
      expect(
        XmlDocument.parse('<a>&#38;amp;</a>').rootElement.innerText,
        '&amp;',
      );
    });

    test('referencia numerica invalida e recusada', () {
      expect(() => XmlDocument.parse('<a>&#x110000;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&#;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&#x;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&#xZZ;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&#-1;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&#+65;</a>'), _malFormado);
      // A producao CharRef so aceita o "x" minusculo.
      expect(() => XmlDocument.parse('<a>&#X41;</a>'), _malFormado);
    });
  });

  group('normalizacao de valor de atributo (XML 1.0 3.3.3)', () {
    test('tab, newline e CR literais viram espaco', () {
      final XmlElement root =
          XmlDocument.parse('<a d="M0\t0\nL1\rL2"/>').rootElement;
      expect(root.getAttribute('d'), 'M0 0 L1 L2');
    });

    test('CRLF literal conta como uma quebra so, logo um espaco so', () {
      // 2.11 normaliza CRLF para um unico #xA antes de 3.3.3 virar espaco.
      expect(
        XmlDocument.parse('<a d="1\r\n2"/>').rootElement.getAttribute('d'),
        '1 2',
      );
    });

    test('referencias de caractere escapam a normalizacao', () {
      final XmlElement root =
          XmlDocument.parse('<a t="1&#9;2&#10;3&#13;4"/>').rootElement;
      expect(root.getAttribute('t'), '1\t2\n3\r4');
    });

    test('valor pode conter ">" e a outra aspa', () {
      final XmlElement root =
          XmlDocument.parse('<a x="a>b" y=\'diz "oi"\'/>').rootElement;
      expect(root.getAttribute('x'), 'a>b');
      expect(root.getAttribute('y'), 'diz "oi"');
    });

    test('espaco em volta do "=" e permitido', () {
      expect(
        XmlDocument.parse('<a x = "1"/>').rootElement.getAttribute('x'),
        '1',
      );
    });

    test('quebras de linha no conteudo sao normalizadas para #xA', () {
      // 2.11: o processador se comporta como se CRLF e CR isolado fossem #xA.
      expect(
        XmlDocument.parse('<a>1\r\n2\r3\n4</a>').rootElement.innerText,
        '1\n2\n3\n4',
      );
    });
  });

  group('erros', () {
    test('tag nao fechada', () {
      expect(() => XmlDocument.parse('<a>texto'), _malFormado);
      expect(() => XmlDocument.parse('<a><b>texto</b>'), _malFormado);
      expect(() => XmlDocument.parse('<a'), _malFormado);
      expect(() => XmlDocument.parse('<a x="1"'), _malFormado);
    });

    test('end tag trocada', () {
      final XmlParserException e = _erro('<a><b></a></b>');
      expect(e.message, contains('does not close'));
      expect(() => XmlDocument.parse('<a></b>'), _malFormado);
    });

    test('end tag sem start tag', () {
      expect(_erro('</a>').message, contains('end tag'));
    });

    test('dois roots', () {
      expect(_erro('<a/><b/>').message, contains('one root element'));
      expect(() => XmlDocument.parse('<a/><a/>'), _malFormado);
    });

    test('texto fora do root', () {
      expect(_erro('texto<a/>').message, contains('outside the root'));
      expect(() => XmlDocument.parse('<a/>texto'), _malFormado);
      // So espaco em branco em volta do root e legal.
      expect(XmlDocument.parse('\n  <a/>  \n').rootElement.name.local, 'a');
    });

    test('atributo sem aspas', () {
      expect(_erro('<a x=1/>').message, contains('quoted'));
      expect(() => XmlDocument.parse('<a x=/>'), _malFormado);
      expect(() => XmlDocument.parse('<a x/>'), _malFormado);
    });

    test('atributo duplicado', () {
      expect(_erro('<a x="1" x="2"/>').message, contains('duplicate'));
      expect(() => XmlDocument.parse('<a x="1" y="2" x="3"/>'), _malFormado);
      // Prefixos diferentes sao nomes diferentes.
      expect(
        XmlDocument.parse('<a x:href="1" href="2"/>').rootElement.attributes,
        hasLength(2),
      );
    });

    test('falta espaco entre atributos', () {
      expect(_erro('<a x="1"y="2"/>').message, contains('whitespace'));
    });

    test('"<" dentro de valor de atributo', () {
      expect(_erro('<a x="1 < 2"/>').message, contains("'<'"));
    });

    test('entidade nao declarada', () {
      expect(_erro('<a>&nbsp;</a>').message, contains('undeclared entity'));
      expect(() => XmlDocument.parse('<a x="&nbsp;"/>'), _malFormado);
    });

    test('referencia de entidade sem ";"', () {
      expect(_erro('<a>&amp</a>').message, contains('entity reference'));
      expect(() => XmlDocument.parse('<a>&amp x;</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a>&</a>'), _malFormado);
      expect(() => XmlDocument.parse('<a x="&"/>'), _malFormado);
    });

    test('comentario nao terminado', () {
      expect(_erro('<!-- oi <a/>').message, contains('comment'));
      expect(() => XmlDocument.parse('<a><!-- oi </a>'), _malFormado);
    });

    test('CDATA nao terminado', () {
      expect(_erro('<a><![CDATA[oi</a>').message, contains('CDATA'));
    });

    test('processing instruction nao terminada', () {
      expect(
        _erro('<?xml version="1.0"<a/>').message,
        contains('processing instruction'),
      );
      expect(() => XmlDocument.parse('<a><?pi </a>'), _malFormado);
    });

    test('DOCTYPE nao terminado', () {
      expect(() => XmlDocument.parse('<!DOCTYPE a <a/>'), _malFormado);
      expect(() => XmlDocument.parse('<!DOCTYPE a [<!ELEMENT a>'), _malFormado);
    });

    test('declaracao dentro de elemento', () {
      expect(
        _erro('<a><!DOCTYPE b><b/></a>').message,
        contains('declaration is not allowed'),
      );
    });

    test('documento vazio ou so com prolog', () {
      expect(_erro('').message, contains('no root element'));
      expect(() => XmlDocument.parse('   \n  '), _malFormado);
      expect(() => XmlDocument.parse('<!-- so um comentario -->'), _malFormado);
      expect(() => XmlDocument.parse('<?xml version="1.0"?>'), _malFormado);
    });

    test('nome invalido', () {
      expect(_erro('< a/>').message, contains('name'));
      expect(() => XmlDocument.parse('<1a/>'), _malFormado);
    });
  });

  group('posicao do erro', () {
    test('aponta a linha e a coluna da start tag nao fechada', () {
      final XmlParserException e = _erro('<raiz>\n  <filho>oi');
      expect(e.message, contains('filho'));
      expect(e.offset, 9);
      expect(e.line, 2);
      expect(e.column, 3);
      expect(e.toString(), contains('line 2, column 3'));
      expect(e.toString(), startsWith('XmlParserException: '));
    });

    test('aponta a end tag trocada', () {
      final XmlParserException e = _erro('<raiz>\n  <filho>\n</raiz>');
      expect(e.line, 3);
      expect(e.column, 1);
    });

    test('documento vazio reporta linha 1, coluna 1', () {
      final XmlParserException e = _erro('');
      expect(e.offset, 0);
      expect(e.line, 1);
      expect(e.column, 1);
    });

    test('coluna avanca dentro da linha', () {
      final XmlParserException e = _erro('<a x="1" x="2"/>');
      expect(e.line, 1);
      expect(e.column, greaterThan(8));
    });
  });

  // O par recursivo que este parser tinha antes levantava StackOverflowError
  // com ~10 mil niveis - um `Error`, que passa direto pelo `on
  // XmlParserException` de quem chama. A varredura com pilha explicita mais o
  // teto de [maxNestingDepth] trocam isso por um erro de parse comum.
  group('profundidade de aninhamento', () {
    String aninhado(int niveis) => '${'<g>' * niveis}x${'</g>' * niveis}';

    test('aceita ate o limite', () {
      final XmlDocument doc = XmlDocument.parse(aninhado(maxNestingDepth));
      XmlNode atual = doc.rootElement;
      int medido = 1;
      while (atual.children.whereType<XmlElement>().isNotEmpty) {
        atual = atual.children.whereType<XmlElement>().first;
        medido++;
      }
      expect(medido, maxNestingDepth);
      expect(doc.rootElement.innerText, 'x');
    });

    test('recusa um nivel alem do limite, sem estourar a pilha', () {
      expect(
        () => XmlDocument.parse(aninhado(maxNestingDepth + 1)),
        throwsA(isA<XmlParserException>()),
      );
    });

    test('recusa aninhamento absurdo como erro de parse comum', () {
      for (final int niveis in <int>[10000, 200000]) {
        expect(
          () => XmlDocument.parse(aninhado(niveis)),
          throwsA(isA<XmlParserException>()),
          reason: '$niveis niveis',
        );
      }
    });

    test('elementos vazios nao contam para a profundidade', () {
      // 200 mil irmaos self-closing sao rasos, por mais numerosos que sejam.
      final XmlDocument doc = XmlDocument.parse('<r>${'<c/>' * 200000}</r>');
      expect(doc.rootElement.childElements.length, 200000);
    });

    test('innerText percorre sem recursao', () {
      final XmlDocument doc = XmlDocument.parse(
        '<r>${List<String>.generate(2000, (int i) => '<c>$i</c>').join()}</r>',
      );
      expect(doc.rootElement.innerText.startsWith('012'), isTrue);
      expect(doc.rootElement.innerText.endsWith('1999'), isTrue);
    });
  });
}
