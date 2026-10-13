/// Every word the explorer shows, in English and Brazilian Portuguese -
/// Windows 11's own wording in each, so it reads like the Explorer the user
/// already knows.
library;

/// The explorer's vocabulary in one language.
final class ExplorerStrings {
  const ExplorerStrings({
    required this.locale,
    required this.home,
    required this.thisPc,
    required this.network,
    required this.desktop,
    required this.downloads,
    required this.documents,
    required this.pictures,
    required this.music,
    required this.videos,
    required this.quickAccess,
    required this.recent,
    required this.drives,
    required this.folder,
    required this.fileFolder,
    required this.file,
    required this.name,
    required this.dateModified,
    required this.type,
    required this.size,
    required this.newFolder,
    required this.newTextDocument,
    required this.textDocument,
    required this.items,
    required this.item,
    required this.selected,
    required this.selectedOne,
    required this.emptyFolder,
    required this.searchIn,
    required this.searchResults,
    required this.noResults,
    required this.freeOf,
    required this.newTab,
    required this.location,
    this.commandLabels = const <String, String>{},
    this.menuNames = const <String, String>{},
  });

  final String locale;
  final String home;
  final String thisPc;
  final String network;
  final String desktop;
  final String downloads;
  final String documents;
  final String pictures;
  final String music;
  final String videos;
  final String quickAccess;
  final String recent;
  final String drives;
  final String folder;
  final String fileFolder;
  final String file;
  final String name;
  final String dateModified;
  final String type;
  final String size;
  final String newFolder;
  final String newTextDocument;
  final String textDocument;
  final String items;
  final String item;
  final String selected;
  final String selectedOne;
  final String emptyFolder;
  final String searchIn;
  final String searchResults;
  final String noResults;

  /// "{free} free of {total}".
  final String freeOf;
  final String newTab;
  final String location;

  /// Command labels in this language, by command id; a command missing
  /// here keeps its English label.
  final Map<String, String> commandLabels;

  /// Submenu and button names - "View", "Sort by" - by their English name.
  final Map<String, String> menuNames;

  /// [english] in this language.
  String menu(String english) => menuNames[english] ?? english;

  /// "12 items", "1 item".
  String itemCount(int n) => '${_number(n)} ${n == 1 ? item : items}';

  /// "3 items selected", "1 item selected".
  String selectedCount(int n) =>
      n == 1 ? '1 $selectedOne' : '${_number(n)} $selected';

  String _number(int n) {
    final String digits = n.toString();
    final String mark = locale.startsWith('pt') ? '.' : ',';
    final StringBuffer out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(mark);
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// "{type} File" / "Arquivo {type}" for an extension with no known name.
  String fileOfType(String extension) => locale.startsWith('pt')
      ? 'Arquivo ${extension.toUpperCase()}'
      : '${extension.toUpperCase()} File';

  static const ExplorerStrings english = ExplorerStrings(
    locale: 'en',
    home: 'Home',
    thisPc: 'This PC',
    network: 'Network',
    desktop: 'Desktop',
    downloads: 'Downloads',
    documents: 'Documents',
    pictures: 'Pictures',
    music: 'Music',
    videos: 'Videos',
    quickAccess: 'Quick access',
    recent: 'Recent',
    drives: 'Devices and drives',
    folder: 'Folder',
    fileFolder: 'File folder',
    file: 'File',
    name: 'Name',
    dateModified: 'Date modified',
    type: 'Type',
    size: 'Size',
    newFolder: 'New folder',
    newTextDocument: 'New Text Document',
    textDocument: 'Text Document',
    items: 'items',
    item: 'item',
    selected: 'items selected',
    selectedOne: 'item selected',
    emptyFolder: 'This folder is empty.',
    searchIn: 'Search',
    searchResults: 'Search Results in',
    noResults: 'No items match your search.',
    freeOf: '{free} free of {total}',
    newTab: 'New tab',
    location: 'Location',
  );

  static const ExplorerStrings portuguese = ExplorerStrings(
    locale: 'pt-BR',
    home: 'Início',
    thisPc: 'Este Computador',
    network: 'Rede',
    desktop: 'Área de Trabalho',
    downloads: 'Downloads',
    documents: 'Documentos',
    pictures: 'Imagens',
    music: 'Músicas',
    videos: 'Vídeos',
    quickAccess: 'Acesso rápido',
    recent: 'Recentes',
    drives: 'Dispositivos e unidades',
    folder: 'Pasta',
    fileFolder: 'Pasta de arquivos',
    file: 'Arquivo',
    name: 'Nome',
    dateModified: 'Data de modificação',
    type: 'Tipo',
    size: 'Tamanho',
    newFolder: 'Nova pasta',
    newTextDocument: 'Novo Documento de Texto',
    textDocument: 'Documento de Texto',
    items: 'itens',
    item: 'item',
    selected: 'itens selecionados',
    selectedOne: 'item selecionado',
    emptyFolder: 'Esta pasta está vazia.',
    searchIn: 'Pesquisar',
    searchResults: 'Resultados da pesquisa em',
    noResults: 'Nenhum item corresponde à pesquisa.',
    freeOf: '{free} livres de {total}',
    newTab: 'Nova guia',
    location: 'Local',
    menuNames: <String, String>{
      'New': 'Novo',
      'Sort': 'Classificar',
      'Sort by': 'Classificar por',
      'View': 'Exibir',
      'Show': 'Mostrar',
      'See more': 'Ver mais',
      'Details': 'Detalhes',
      'Open': 'Abrir',
      'Unpin from Quick access': 'Desafixar do Acesso rápido',
    },
    commandLabels: <String, String>{
      'nav.back': 'Voltar',
      'nav.forward': 'Avançar',
      'nav.up': 'Para cima',
      'nav.refresh': 'Atualizar',
      'nav.home': 'Início',
      'nav.thisPc': 'Este Computador',
      'nav.go': 'Ir para',
      'nav.place': 'Ir para uma pasta conhecida',
      'nav.editAddress': 'Editar endereço',
      'nav.focusSearch': 'Pesquisar',
      'nav.search': 'Pesquisar por',
      'tab.new': 'Nova guia',
      'tab.close': 'Fechar guia',
      'tab.select': 'Ir para a guia',
      'tab.next': 'Próxima guia',
      'tab.previous': 'Guia anterior',
      'tab.duplicate': 'Duplicar guia',
      'tab.reopen': 'Reabrir guia fechada',
      'file.open': 'Abrir',
      'file.openInNewTab': 'Abrir em nova guia',
      'file.newFolder': 'Pasta',
      'file.newTextDocument': 'Documento de Texto',
      'file.rename': 'Renomear',
      'file.delete': 'Excluir',
      'file.cut': 'Recortar',
      'file.copy': 'Copiar',
      'file.paste': 'Colar',
      'file.copyPath': 'Copiar como caminho',
      'file.properties': 'Propriedades',
      'file.reveal': 'Mostrar no gerenciador do sistema',
      'file.pin': 'Fixar no Acesso rápido',
      'file.unpin': 'Desafixar do Acesso rápido',
      'select.all': 'Selecionar tudo',
      'select.none': 'Selecionar nenhum',
      'select.invert': 'Inverter seleção',
      'select.byName': 'Selecionar pelo nome',
      'select.paths': 'Selecionar itens',
      'view.extraLargeIcons': 'Ícones extra grandes',
      'view.largeIcons': 'Ícones grandes',
      'view.mediumIcons': 'Ícones médios',
      'view.smallIcons': 'Ícones pequenos',
      'view.list': 'Lista',
      'view.details': 'Detalhes',
      'view.tiles': 'Blocos',
      'sort.name': 'Nome',
      'sort.dateModified': 'Data de modificação',
      'sort.type': 'Tipo',
      'sort.size': 'Tamanho',
      'sort.ascending': 'Crescente',
      'sort.descending': 'Decrescente',
      'view.hiddenItems': 'Itens ocultos',
      'view.extensions': 'Extensões de nomes de arquivos',
      'view.navigationPane': 'Painel de navegação',
      'view.detailsPane': 'Painel de detalhes',
    },
  );

  /// The strings for [localeName] (`pt_BR.UTF-8`, `en-US`...).
  static ExplorerStrings forLocale(String localeName) =>
      localeName.toLowerCase().startsWith('pt') ? portuguese : english;
}
