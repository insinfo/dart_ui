# Qualidade de bordas arredondadas (2026-10-18)

A irregularidade relatada na barra de endereço foi reproduzida em um framebuffer
CPU, sem depender do monitor, compositor ou ampliação de screenshot. Uma borda
circular de 1 pixel apresentou erro máximo de cobertura de 0,227 em relação a
uma referência independente com 100 × 100 amostras por pixel.

A aproximação de curvas permitia desvio de 0,25 pixel antes de integrar a área
coberta. Esse limite é grande para o traço fino: as pequenas cordas aparecem
como variações de espessura no contorno. O orçamento padrão passou para 0,025
pixel de dispositivo, compartilhado pelo rasterizador CPU, atlas de máscaras e
rotas vetoriais que usam o mesmo padrão. O contorno do widget não foi engrossado.
A contagem de segmentos continua considerando a transformação e o limite máximo
por curva existente.

Os seis testes de regressão medem o traço contra dois círculos concêntricos
independentes, nas escalas 1, 1,25 e 2, em posições inteiras e fracionárias. Todos
exigem erro inferior a 0,04 de cobertura, incluindo a quantização para 8 bits.
A comparação histórica do preenchimento de círculo mantém explicitamente seu
orçamento antigo, e também verifica o atual: erro inferior a 0,025, contra cerca
de 0,164 do polígono antigo. O caso histórico de estabilidade numérica do
compute mantém sua subdivisão de 0,25; os demais casos exercitam o padrão novo.

[Antes](ROUNDED_BORDER_BEFORE_2026-10-18.png) ·
[Depois](ROUNDED_BORDER_AFTER_2026-10-18.png)

Os PNGs são renderizações sintéticas de uma barra de 1.126 × 56 pixels com a
mesma geometria de borda, sem redimensionamento. Em um probe CPU aquecido no
macOS, sete lotes de 150 quadros mediram medianas de aproximadamente 0,206 ms
antes e 0,210 ms depois. Isso mede somente essa barra; cenas com muitas curvas
podem gastar mais tempo e memória com a subdivisão adicional.

Um monitor de baixa densidade, escala fracionária ou nitidez excessiva pode
acentuar linhas finas. Isso não elimina o erro de rasterização medido aqui.

## Validação

- macOS: análise estática limpa; 2.180 testes de renderização, geometria,
  pintura, widgets, plataforma e Wayland passaram, com 478 skips por recursos
  não disponíveis nesse sistema. O exemplo passou seus 58 testes e gerou AOT.
- Windows ARM64: análise limpa, 796 testes selecionados e 58 do exemplo passaram;
  executável AOT recompilado.
- Linux ARM64: análise limpa, 7.824 testes do framework e 58 do exemplo
  passaram; 907 skips. O smoke nativo em GNOME Wayland confirmou virgl, 24
  apresentações DMA-BUF, oito imports, três redimensionamentos com o mesmo
  contexto GL e popups medidos em 183 × 148 e 120 × 80 pixels. Build AOT concluído.
