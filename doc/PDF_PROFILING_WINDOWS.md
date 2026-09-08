# Profiling do módulo PDF no Windows

O benchmark separa leitura, parsing, geometria, inventário de imagens,
validação e renderização. Ele aquece a VM antes de coletar amostras e informa
mínimo, mediana, p95, máximo e variação do RSS.

## Benchmark JIT

```powershell
powershell -ExecutionPolicy Bypass -File tool\profile_pdf.ps1 `
  -PdfPath C:\documentos\arquivo.pdf `
  -Iterations 20
```

## Executável AOT

```powershell
powershell -ExecutionPolicy Bypass -File tool\profile_pdf.ps1 `
  -PdfPath C:\documentos\arquivo.pdf `
  -Iterations 20 `
  -Aot
```

Use AOT para comparar o comportamento de produção. Não compare diretamente os
números de JIT e AOT como se fossem a mesma população.

## Timeline JSON pelo terminal

```powershell
powershell -ExecutionPolicy Bypass -File tool\profile_pdf.ps1 `
  -PdfPath C:\documentos\arquivo.pdf `
  -Iterations 20 `
  -Trace
```

O script gera `pdf-timeline.json` usando o gravador `file` da própria Dart VM.
Não é necessário abrir a VM Service nem disputar uma requisição JSON-RPC com o
encerramento de um benchmark curto. Abra o resultado no Perfetto ou DevTools.

Por padrão o cenário mede a abertura leve e não descompacta os streams de
conteúdo. As opções abaixo habilitam trabalho adicional:

- `-FullValidation`: resolve objetos e decodifica streams de conteúdo;
- `-RenderFirst`: renderiza a primeira página em modo tolerante;
- `-OutputDirectory caminho`: muda o diretório dos relatórios.

Para investigar um gargalo, compare execuções com o mesmo PDF, SDK, modo de
compilação e quantidade de iterações. Evite logs dentro das regiões medidas.
Antivírus, cache de arquivos e temperatura da máquina podem alterar resultados.

## Instrumentação

As regiões aparecem na timeline com os nomes:

- `pdf.parse`;
- `pdf.page_geometry`;
- `pdf.image_inventory`;
- `pdf.metadata_validation`;
- `pdf.full_validation`, quando solicitada;
- `pdf.render_first`, quando solicitado.

O relatório numérico é a evidência para regressões. A timeline serve para
explicar o custo observado: CPU, compilação JIT, alocações e pausas de GC.
