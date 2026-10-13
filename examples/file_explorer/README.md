# Explorador de arquivos (estilo Windows 11), 100% Dart

Um explorador de arquivos com a cara e o comportamento do Explorador do
Windows 11, tendo o [Files](https://github.com/files-community/files) como
referência de recursos e layout (nenhum código copiado).

```
dart run bin/file_explorer.dart [pasta]
```

## Arquitetura

- `lib/src/engine/` - o motor, sem widgets: `FileSystem` (interface),
  `ExplorerModel` (abas, histórico, seleção, área de transferência de
  arquivos, operações), e os comandos em módulos (`commands/`). Tudo o que a
  janela faz é um comando executado pelo registro, como no editor vetorial.
- `lib/src/io/` - o adaptador para o disco (`dart:io`, lixeira, abrir com o
  aplicativo padrão, observar a pasta).
- `lib/src/ui/` - a janela.
- `test/` - o motor contra um `MemoryFileSystem`, e a janela sem tela.
