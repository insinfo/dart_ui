# Exemplo de relatório PDF avançado

Este exemplo gera um relatório A4 de duas páginas usando o módulo PDF do
`dart_ui`. Ele demonstra, no mesmo documento:

- SVG declarado inline e importado como `VectorDocument`;
- JPEG incorporado sem decodificação ou recompressão (`DCTDecode`);
- tabela com células, bordas, cores e tipografia;
- Inter SemiBold, disponível no Google Fonts, parseada por `Typeface` e
  desenhada como contornos vetoriais;
- reabertura, inventário de imagens e validação do PDF gerado.

Execute a partir da raiz do repositório:

```powershell
dart run examples/pdf_report_demo/main.dart
```

O arquivo é criado em `output/pdf/dart_ui_relatorio_exemplo.pdf`. Um caminho
alternativo pode ser informado como primeiro argumento.

A fonte Inter é distribuída sob a SIL Open Font License 1.1; a licença está em
`assets/OFL-1.1.txt`.
