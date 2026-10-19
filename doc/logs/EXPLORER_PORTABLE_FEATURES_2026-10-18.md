# Experiência portátil do File Explorer (2026-10-18)

O inventário fornecido pelo proprietário reúne o Explorador do Windows e o
Files Community. A implementação aproveita os fluxos já existentes e prioriza
recursos locais úteis em macOS, Linux e Windows. A interface continua com menus,
comandos e atalhos compartilhados; as operações de disco permanecem no adaptador
`IoFileSystem`, sem dependências de widgets no motor.

## Recursos implementados

| Área | Comportamento |
|---|---|
| Opções de Pasta | Janela Geral / Modo de Exibição / Pesquisar, com OK, Cancelar, Aplicar e restaurar padrões. Alterações ficam em uma cópia até aplicar. |
| Inicialização | Início ou Este Computador para novas abas; restauração opcional de abas e aba ativa. Caminho informado na linha de comando prevalece. |
| Persistência | Preferências por usuário, acesso rápido, favoritos, recentes e vistas por diretório. Gravações ordenadas, com arquivo temporário e substituição. JSON inválido não impede iniciar. |
| Vistas por pasta | Modo, ordenação, direção, colunas e larguras; aplicar vista atual a todas as pastas ou redefinir vistas. Limite de 500 diretórios lembrados. |
| Exibição | Modo Conteúdo, espaçamento compacto, caixas de seleção de itens, miniaturas opcionais, dicas, barra de status, caminho completo no título. |
| Abertura | Um ou dois cliques; modificadores mantêm seleção múltipla. No DataGrid, abertura por clique único espera soltar e não ocorre após arrastar. Abertura opcional de pastas em outra aba. |
| Privacidade | Mostrar/lembrar recentes pode ser desativado; limpar histórico remove recentes e histórico de navegação, preservando favoritos. |
| Favoritos | Adicionar/remover arquivos pelo menu; seção no Início com abrir, remover e localizar no sistema. Pastas continuam no Acesso rápido. |
| Painéis | Prévia de texto e imagem e painel de detalhes são alternativas. Prévia textual limitada a 64 KiB; binários não são exibidos como texto. Leituras antigas não substituem a seleção nova. |
| Pesquisa | Nomes, curingas, frases entre aspas, AND / OR / NOT, `ext:`, `kind:`, `size:`, `modified:` e `created:`. Escopo opcional de subpastas, botão Parar e aviso no limite de 5.000 resultados. |
| Ordenação | Data de criação e extensão, além de nome, modificação, tipo e tamanho. Comparação natural e pastas primeiro permanecem. |
| Abas | Menu com duplicar, restaurar, fechar outras/esquerda/direita e mover para esquerda/direita. Fechar abas preserva a identidade da ativa. |
| Paleta de comandos | Ctrl/Cmd+Shift+P abre pesquisa de comandos, com atalhos, estados e motivos de indisponibilidade. Enter executa o primeiro resultado habilitado. |
| Terminal | Abrir a pasta atual no terminal por comando. Caminhos são argumentos separados, sem interpolação por shell ou elevação automática. |
| Renomeação em lote | F2 com vários itens pede nome base e gera Nome (1), Nome (2)… preservando extensões e recusando conflitos. |
| Desfazer/refazer | Renomeações e movimentações da sessão, inclusive em lote; recusa sobrescrever destinos ocupados. Não anuncia desfazer cópias ou exclusões. |
| ZIP | Criação com deflate e extração para nova pasta em isolate, sem programas de compactação externos. Nomes Unicode e diretórios vazios são preservados. |

A configuração fica em `dart_ui_file_explorer/preferences.json`, sob
`StandardPaths.appData`: Application Support no macOS, XDG config no Linux e
AppData Roaming no Windows. O estado não é gravado na pasta que está sendo
navegada. Até 30 abas e 100 favoritos são restaurados; recentes são limitados
pelo motor a 20 durante o uso.

Exemplos de pesquisa:

```text
*.pdf
"annual report" AND NOT ext:tmp
ext:png OR ext:jpg
kind:image size:>10MB
modified:>=2026-01-01
created:<2026-06-01
```

Datas usam ISO `AAAA-MM-DD`, tamanhos aceitam B/KB/MB/GB decimais e KiB/MiB/GiB
binários. Filtros desconhecidos e consultas incompletas mostram erro em vez de
retornar silenciosamente um resultado diferente. Não é uma implementação do
Windows Search/AQS nem faz indexação de conteúdo de documentos.

## Suporte acrescentado à dart_ui

- `showCommandPalette` / `CommandPalette`, usando `CommandRegistry`.
- `Shell.openTerminal`, com planos de argumentos testáveis para os três sistemas.
- `DataGrid.activateOnSingleClick`, preservando drag e seleção com modificadores.
- `PointerListener.stopPropagation`: um controle dentro de uma linha pode
  receber o clique sem também acionar a seleção/abertura da linha. O scroll
  continua a passar quando o predicado não o interrompe.

## Arquivos compactados

O serviço ZIP recusa entradas fora do destino, links, criptografia, métodos
além de stored/deflate, arquivos multivolume e ZIP64. Os limites são 10.000
entradas, 64 MiB por arquivo, 256 MiB descompactados e 128 MiB de ZIP. A expansão
é contada durante a decodificação, e CRC/tamanho são verificados. Extração em
pasta temporária é concluída antes de expor o destino; falha remove a pasta
incompleta. Um destino existente nunca é escolhido para sobrescrita.

Não há editor de conteúdo ZIP, 7z/RAR, senha, preservação de ACLs nem restauração
de permissões Unix neste lote. As mensagens de erro identificam as limitações.

## Relação com os inventários

Navegação, breadcrumbs, árvore lateral, seleção múltipla, copiar/recortar/colar,
arrastar arquivos, lixeira do sistema, propriedades, ícones, miniaturas,
redimensionamento de colunas, localização de resultados e os modos principais
já existiam; os testes anteriores continuam como regressão.

Os inventários também incluem serviços ou integrações próprias do sistema:
OneDrive/SharePoint, BitLocker/EFS/NTFS, Histórico de Arquivos, extensões COM,
Defender, WSL, indexadores, permissões administrativas e clientes de nuvem.
Essas capacidades exigem provedores e credenciais reais e não foram simuladas.
As funções de nuvem não são inferidas a partir da presença de uma pasta.

Recursos adicionais do Files, como painel duplo, etiquetas, Git, FTP/FTPS,
coleções, descoberta de rede e arrastar abas entre janelas, continuam fora desta
implementação. Também não há navegador/restauração da Lixeira, edição de
metadados de Office/EXIF, cancelamento por bloco de cópia ou prévia de PDF/Office.
A matriz acima descreve o comportamento disponível, sem reivindicar equivalência
com todos os itens dos dois inventários.

## Validação

Os testes cobrem preferências, cancelar/aplicar, privacidade, restauração de
sessão e precedência da linha de comando, vistas por diretório, filtros,
renomeação em lote com undo/redo e conflito, leitura limitada, ZIP Unicode e
pastas vazias, CRC inválido, travessia de diretório e destinos existentes.
A interação com checkboxes passa pelo roteador real de eventos.

- macOS: análise estática limpa, 58 testes do exemplo e build AOT `.app`.
- Windows 11 ARM64: Dart 3.6.2 nativo, análise limpa, 796 testes de framework
  selecionados e 58 testes do exemplo; executável AOT GUI compilado e aberto
  com `--cpu`. A sondagem OpenGL da VM tem uma limitação registrada no
  [relatório de foco/tooltip](EXPLORER_INPUT_TOOLTIP_2026-10-18.md).
- Linux ARM64: análise, suíte completa do framework e exemplo executados na VM;
  os totais finais são registrados com a correção das bordas no relatório abaixo.

No GNOME Wayland, a interface foi exercitada com GPU virgl: opções com aplicar /
cancelar, modo compacto, checkboxes, paleta com texto digitado e modo Conteúdo
com prévia do README. Durante essa validação, o parser XKB revelou um erro:
`type[Group1]` era confundido com a lista de símbolos, anulando caracteres.
A busca explícita por `symbols[Group1]` e as regressões de keymap corrigem isso.
O atalho de Opções também usa agora a tecla lógica de vírgula correta.

Evidências: [Opções](EXPLORER_OPTIONS_2026-10-18.png),
[paleta filtrada](EXPLORER_PALETTE_2026-10-18.png),
[Conteúdo com prévia](EXPLORER_PREVIEW_2026-10-18.png).
A correção posterior de suavidade tem [relatório próprio](ROUNDED_BORDER_QUALITY_2026-10-18.md).
