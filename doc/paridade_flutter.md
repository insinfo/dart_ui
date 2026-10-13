# Paridade de API com o Flutter

Gerado por `dart run tool/flutter_parity.dart`; não edite à mão. As regras estão em [AGENTS_FLUTTER.md](AGENTS_FLUTTER.md) e o histórico em [DIARIO_FLUTTER.md](DIARIO_FLUTTER.md).

Cada nome público do Flutter (`packages/flutter/lib`) é procurado na API pública do `dart_ui` (`lib/*.dart`). ✅ existe com o mesmo nome; 🟡 existe mas difere (a nota diz em quê) e conta metade; ❌ falta; — não se aplica, com o motivo. O nome existir não prova a mesma assinatura: divergências conhecidas ficam em `tool/flutter_parity/catalog.dart`, e na dúvida se marca para baixo.

## Por prioridade

| Prioridade | ✅ | 🟡 | ❌ | total | paridade |
|---|---|---|---|---|---|
| P0 | 191 | 51 | 79 | 321 | 67% |
| P1 | 405 | 7 | 1764 | 2176 | 18% |
| P2 | 0 | 0 | 116 | 116 | 0% |
| **todas** | 596 | 58 | 1959 | 2613 | 23% |

P0: o que um app ou pacote típico usa primeiro. P1: o resto do núcleo e do Material. P2: Cupertino. Fora da conta: 145 nomes que não se aplicam.

## Por biblioteca

| Biblioteca | ✅ | 🟡 | ❌ | total | paridade |
|---|---|---|---|---|---|
| `animation` | 16 | 0 | 43 | 59 | 27% |
| `cupertino` | 0 | 0 | 116 | 116 | 0% |
| `dart:io` | 0 | 0 | 0 | 0 | - |
| `dart:typed_data` | 0 | 0 | 0 | 0 | - |
| `dart:ui` | 32 | 4 | 31 | 67 | 50% |
| `foundation` | 18 | 0 | 96 | 114 | 15% |
| `gestures` | 57 | 0 | 130 | 187 | 30% |
| `material` | 42 | 6 | 466 | 514 | 8% |
| `painting` | 40 | 7 | 78 | 125 | 34% |
| `physics` | 4 | 0 | 6 | 10 | 40% |
| `rendering` | 96 | 1 | 192 | 289 | 33% |
| `scheduler` | 2 | 0 | 10 | 12 | 16% |
| `semantics` | 3 | 1 | 31 | 35 | 10% |
| `services` | 20 | 1 | 166 | 187 | 10% |
| `widgets` | 266 | 38 | 594 | 898 | 31% |

## P0, nome a nome

| | Nome | Biblioteca | Tipo | Nota |
|---|---|---|---|---|
| ✅ | `AbsorbPointer` | widgets | class |  |
| ✅ | `Action` | widgets | class |  |
| ✅ | `Actions` | widgets | class |  |
| ✅ | `Align` | widgets | class |  |
| ✅ | `Alignment` | painting | class |  |
| ✅ | `AlignmentDirectional` | painting | class |  |
| ✅ | `AlwaysScrollableScrollPhysics` | widgets | class |  |
| ✅ | `AnimatedAlign` | widgets | class |  |
| ✅ | `AnimatedBuilder` | widgets | class |  |
| ✅ | `AnimatedContainer` | widgets | class |  |
| ✅ | `AnimatedOpacity` | widgets | class |  |
| ✅ | `AnimatedPadding` | widgets | class |  |
| ✅ | `AnimatedPositioned` | widgets | class |  |
| ✅ | `AnimatedSize` | widgets | class |  |
| ✅ | `AnimatedSwitcher` | widgets | class |  |
| ✅ | `Animation` | animation | class |  |
| ✅ | `AnimationController` | animation | class |  |
| ✅ | `AspectRatio` | widgets | class |  |
| ✅ | `AsyncSnapshot` | widgets | class |  |
| ✅ | `AutovalidateMode` | widgets | enum |  |
| ✅ | `Badge` | material | class |  |
| ✅ | `Baseline` | widgets | class |  |
| ✅ | `Border` | painting | class |  |
| ✅ | `BorderRadius` | painting | class |  |
| ✅ | `BorderSide` | painting | class |  |
| ✅ | `BoxFit` | painting | enum |  |
| ✅ | `BuildContext` | widgets | class |  |
| ✅ | `Builder` | widgets | class |  |
| ✅ | `Card` | material | class |  |
| ✅ | `Center` | widgets | class |  |
| ✅ | `ChangeNotifier` | foundation | class |  |
| ✅ | `Chip` | material | class |  |
| ✅ | `CircularProgressIndicator` | material | class |  |
| ✅ | `ClampingScrollPhysics` | widgets | class |  |
| ✅ | `Clip` | dart:ui | class |  |
| ✅ | `ClipRect` | widgets | class |  |
| ✅ | `Clipboard` | services | class |  |
| ✅ | `Color` | dart:ui | class |  |
| ✅ | `ColorScheme` | material | class |  |
| ✅ | `ColorTween` | animation | class |  |
| ✅ | `ColoredBox` | widgets | class |  |
| ✅ | `Colors` | material | class |  |
| ✅ | `Column` | widgets | class |  |
| ✅ | `ConnectionState` | widgets | enum |  |
| ✅ | `ConstrainedBox` | widgets | class |  |
| ✅ | `Container` | widgets | class |  |
| ✅ | `CurvedAnimation` | animation | class |  |
| ✅ | `Curves` | animation | class |  |
| ✅ | `CustomClipper` | rendering | class |  |
| ✅ | `CustomMultiChildLayout` | widgets | class |  |
| ✅ | `DecoratedBox` | widgets | class |  |
| ✅ | `DefaultTextStyle` | widgets | class |  |
| ✅ | `Dialog` | material | class |  |
| ✅ | `Directionality` | widgets | class |  |
| ✅ | `Divider` | material | class |  |
| ✅ | `DragTarget` | widgets | class |  |
| ✅ | `EdgeInsets` | painting | class |  |
| ✅ | `EdgeInsetsDirectional` | painting | class |  |
| ✅ | `Expanded` | widgets | class |  |
| ✅ | `FadeTransition` | widgets | class |  |
| ✅ | `FilteringTextInputFormatter` | services | class |  |
| ✅ | `FittedBox` | widgets | class |  |
| ✅ | `Flex` | widgets | class |  |
| ✅ | `Flexible` | widgets | class |  |
| ✅ | `FocusNode` | widgets | class |  |
| ✅ | `FocusScope` | widgets | class |  |
| ✅ | `FocusScopeNode` | widgets | class |  |
| ✅ | `FocusTraversalGroup` | widgets | class |  |
| ✅ | `FontWeight` | dart:ui | class |  |
| ✅ | `FormField` | widgets | class |  |
| ✅ | `FormState` | widgets | class |  |
| ✅ | `FractionallySizedBox` | widgets | class |  |
| ✅ | `FutureBuilder` | widgets | class |  |
| ✅ | `GestureDetector` | widgets | class |  |
| ✅ | `GlobalKey` | widgets | class |  |
| ✅ | `GlobalObjectKey` | widgets | class |  |
| ✅ | `Hero` | widgets | class |  |
| ✅ | `Icon` | widgets | class |  |
| ✅ | `IconButton` | material | class |  |
| ✅ | `IconData` | widgets | class |  |
| ✅ | `IconTheme` | widgets | class |  |
| ✅ | `IconThemeData` | widgets | class |  |
| ✅ | `Icons` | material | class |  |
| ✅ | `IgnorePointer` | widgets | class |  |
| ✅ | `Image` | widgets | class |  |
| ✅ | `IndexedStack` | widgets | class |  |
| ✅ | `InheritedModel` | widgets | class |  |
| ✅ | `InheritedNotifier` | widgets | class |  |
| ✅ | `InheritedWidget` | widgets | class |  |
| ✅ | `Intent` | widgets | class |  |
| ✅ | `IntrinsicHeight` | widgets | class |  |
| ✅ | `IntrinsicWidth` | widgets | class |  |
| ✅ | `Key` | foundation | class |  |
| ✅ | `KeyboardListener` | widgets | class |  |
| ✅ | `KeyedSubtree` | widgets | class |  |
| ✅ | `LayoutBuilder` | widgets | class |  |
| ✅ | `LengthLimitingTextInputFormatter` | services | class |  |
| ✅ | `LimitedBox` | widgets | class |  |
| ✅ | `LinearProgressIndicator` | material | class |  |
| ✅ | `Listenable` | foundation | class |  |
| ✅ | `ListenableBuilder` | widgets | class |  |
| ✅ | `Localizations` | widgets | class |  |
| ✅ | `MediaQuery` | widgets | class |  |
| ✅ | `MediaQueryData` | widgets | class |  |
| ✅ | `MenuAnchor` | material | class |  |
| ✅ | `MenuBar` | material | class |  |
| ✅ | `MenuItemButton` | material | class |  |
| ✅ | `MouseRegion` | widgets | class |  |
| ✅ | `Navigator` | widgets | class |  |
| ✅ | `NavigatorState` | widgets | class |  |
| ✅ | `NeverScrollableScrollPhysics` | widgets | class |  |
| ✅ | `NotificationListener` | widgets | class |  |
| ✅ | `ObjectKey` | widgets | class |  |
| ✅ | `Offset` | dart:ui | class |  |
| ✅ | `Offstage` | widgets | class |  |
| ✅ | `Opacity` | widgets | class |  |
| ✅ | `OutlineInputBorder` | material | class |  |
| ✅ | `OverflowBox` | widgets | class |  |
| ✅ | `Overlay` | widgets | class |  |
| ✅ | `OverlayEntry` | widgets | class |  |
| ✅ | `Padding` | widgets | class |  |
| ✅ | `PageRoute` | widgets | class |  |
| ✅ | `PageRouteBuilder` | widgets | class |  |
| ✅ | `PageStorageKey` | widgets | class |  |
| ✅ | `Placeholder` | widgets | class |  |
| ✅ | `PopScope` | widgets | class |  |
| ✅ | `PopupMenuButton` | material | class |  |
| ✅ | `PopupMenuItem` | material | class |  |
| ✅ | `Positioned` | widgets | class |  |
| ✅ | `RRect` | dart:ui | class |  |
| ✅ | `Radio` | material | class |  |
| ✅ | `Radius` | dart:ui | class |  |
| ✅ | `Rect` | dart:ui | class |  |
| ✅ | `RichText` | widgets | class |  |
| ✅ | `RotatedBox` | widgets | class |  |
| ✅ | `RotationTransition` | widgets | class |  |
| ✅ | `Route` | widgets | class |  |
| ✅ | `Row` | widgets | class |  |
| ✅ | `SafeArea` | widgets | class |  |
| ✅ | `ScaleTransition` | widgets | class |  |
| ✅ | `ScrollNotification` | widgets | class |  |
| ✅ | `ShaderMask` | widgets | class |  |
| ✅ | `SingleActivator` | widgets | class |  |
| ✅ | `Size` | dart:ui | class |  |
| ✅ | `SizeTransition` | widgets | class |  |
| ✅ | `SizedBox` | widgets | class |  |
| ✅ | `SlideTransition` | widgets | class |  |
| ✅ | `Slider` | material | class |  |
| ✅ | `SliverFillRemaining` | widgets | class |  |
| ✅ | `SliverGrid` | widgets | class |  |
| ✅ | `SliverPadding` | widgets | class |  |
| ✅ | `SliverPersistentHeader` | widgets | class |  |
| ✅ | `SliverToBoxAdapter` | widgets | class |  |
| ✅ | `Spacer` | widgets | class |  |
| ✅ | `Stack` | widgets | class |  |
| ✅ | `State` | widgets | class |  |
| ✅ | `StatefulBuilder` | widgets | class |  |
| ✅ | `StatefulWidget` | widgets | class |  |
| ✅ | `StatelessWidget` | widgets | class |  |
| ✅ | `StreamBuilder` | widgets | class |  |
| ✅ | `SubmenuButton` | material | class |  |
| ✅ | `Switch` | material | class |  |
| ✅ | `Table` | widgets | class |  |
| ✅ | `TableRow` | widgets | class |  |
| ✅ | `Text` | widgets | class |  |
| ✅ | `TextAlign` | dart:ui | class |  |
| ✅ | `TextFormField` | material | class |  |
| ✅ | `TextInputAction` | services | enum |  |
| ✅ | `TextInputFormatter` | services | class |  |
| ✅ | `TextInputType` | services | class |  |
| ✅ | `TextOverflow` | painting | enum |  |
| ✅ | `TextSpan` | painting | class |  |
| ✅ | `TextStyle` | painting | class |  |
| ✅ | `TextTheme` | material | class |  |
| ✅ | `Theme` | material | class |  |
| ✅ | `ThemeData` | material | class |  |
| ✅ | `Tooltip` | material | class |  |
| ✅ | `Tween` | animation | class |  |
| ✅ | `UnconstrainedBox` | widgets | class |  |
| ✅ | `UniqueKey` | foundation | class |  |
| ✅ | `ValueChanged` | foundation | typedef |  |
| ✅ | `ValueKey` | foundation | class |  |
| ✅ | `ValueListenableBuilder` | widgets | class |  |
| ✅ | `ValueNotifier` | foundation | class |  |
| ✅ | `Visibility` | widgets | class |  |
| ✅ | `VoidCallback` | dart:ui | class |  |
| ✅ | `Widget` | widgets | class |  |
| ✅ | `WidgetSpan` | widgets | class |  |
| ✅ | `Wrap` | widgets | class |  |
| ✅ | `showDialog` | material | function |  |
| ✅ | `showMenu` | material | function |  |
| 🟡 | `BlendMode` | dart:ui | class | only the Porter-Duff modes are real; the rest draw as `srcOver` |
| 🟡 | `BouncingScrollPhysics` | widgets | class | `fast` only changes the spring |
| 🟡 | `BoxDecoration` | painting | class | no `image`; shadows layered, not blurred; `gradient` only a `SweepGradient` |
| 🟡 | `BoxShadow` | painting | class | layered translucent shapes, not a blur |
| 🟡 | `CallbackShortcuts` | widgets | class | listens across the whole window |
| 🟡 | `Canvas` | dart:ui | class | non-rectangular clips are a layer and a mask; no `drawParagraph`, `drawVertices` or `drawAtlas` |
| 🟡 | `ClipOval` | widgets | class | an offscreen layer; not on Direct2D or the DOM |
| 🟡 | `ClipPath` | widgets | class | an offscreen layer; not on Direct2D or the DOM |
| 🟡 | `ClipRRect` | widgets | class | an offscreen layer; not on Direct2D or the DOM |
| 🟡 | `CustomPaint` | widgets | class | `isComplex` and `willChange` ignored; no semantics |
| 🟡 | `CustomPainter` | rendering | class | no `semanticsBuilder` |
| 🟡 | `CustomScrollView` | widgets | class | `axis:` instead of `scrollDirection:`; no `center`, no `shrinkWrap` |
| 🟡 | `Dismissible` | widgets | class | a fling has no spring simulation |
| 🟡 | `Draggable` | widgets | class | primary button only; cancelled if it leaves the tree |
| 🟡 | `ErrorWidget` | widgets | class | a StatelessWidget drawn in the UI font |
| 🟡 | `Flow` | widgets | class | `paintChild` takes `Transform2D`, not `Matrix4`; no `clipBehavior` |
| 🟡 | `Focus` | widgets | class | no `onKey`; `includeSemantics` has no effect |
| 🟡 | `Form` | widgets | class | `onPopInvokedWithResult` always gets a null result |
| 🟡 | `GridView` | widgets | class | `axis:` instead of `scrollDirection:`; `controller` is a `ScrollPosition` |
| 🟡 | `InputDecoration` | material | class | no `label`/`hint` widgets, `prefixIconConstraints`, `floatingLabelAlignment` or `visualDensity` |
| 🟡 | `InteractiveViewer` | widgets | class | `Transform2D` instead of `Matrix4`; no inertia, no `.builder` |
| 🟡 | `LinearGradient` | painting | class | the display list's absolute gradient, not `colors:` with `Alignment` |
| 🟡 | `ListView` | widgets | class | `axis:` instead of `scrollDirection:`; `controller` is a `ScrollPosition` |
| 🟡 | `Listener` | widgets | class | dart_ui's pointer events; `translucent` is hit as `opaque` |
| 🟡 | `LogicalKeyboardKey` | services | class | `event.logicalKey` is still an `int`; left and right modifiers compare equal |
| 🟡 | `LongPressDraggable` | widgets | class | needs a `GestureScope` for the long press |
| 🟡 | `NestedScrollView` | widgets | class | no `SliverOverlapAbsorber`/`Injector` (not needed: the body is measured below the pinned headers) |
| 🟡 | `PageController` | widgets | class | `keepPage` only applies across an axis change |
| 🟡 | `PageView` | widgets | class | `itemCount: null` becomes a very large count; one wheel notch turns one page |
| 🟡 | `Paint` | dart:ui | class | no `maskFilter`, `colorFilter`, `imageFilter` or `filterQuality` |
| 🟡 | `Path` | dart:ui | class | no `combine` or `computeMetrics`; `conicTo` is a cubic |
| 🟡 | `RadialGradient` | painting | class | the display list's absolute gradient, not `colors:` with `Alignment` |
| 🟡 | `ScrollController` | widgets | class | views take a `ScrollPositionSource`; `keepScrollOffset` has no effect |
| 🟡 | `ScrollPhysics` | widgets | class | simulations take a `Duration`; no `adjustPositionForNewDimensions` |
| 🟡 | `ScrollPosition` | widgets | class | plays the part of `ScrollController` too, and has neither `ScrollActivity` nor `ScrollContext` |
| 🟡 | `Scrollbar` | material | class | takes `position:`, not `controller:` |
| 🟡 | `SelectableText` | material | class | no touch handles or toolbar; `minLines` ignored |
| 🟡 | `ShapeDecoration` | painting | class | no `image`; shadows layered, not blurred |
| 🟡 | `Shortcuts` | widgets | class | does not answer when nothing is focused |
| 🟡 | `SingleChildScrollView` | widgets | class | `axis:` instead of `scrollDirection:` |
| 🟡 | `SliverAppBar` | material | class | no `snap`, `stretch` or `automaticallyImplyLeading`; `bottom` is a widget plus `bottomHeight` |
| 🟡 | `SliverList` | widgets | class | its delegate needs a `childCount`; rows are estimated by `estimatedItemExtent` |
| 🟡 | `SweepGradient` | painting | class | no `transform`; painted in 1-degree wedges |
| 🟡 | `TextEditingController` | widgets | class | positional `TextEditingController('x')`; `value` is the text, the `TextEditingValue` is `editingValue` |
| 🟡 | `TextField` | material | class | no `style`, `textAlign`, `cursor*` or `expands` |
| 🟡 | `Transform` | widgets | class | a 2D affine `Transform2D`, no perspective |
| 🟡 | `TweenAnimationBuilder` | widgets | class | resumes from the current value only for types it knows how to interpolate |
| 🟡 | `WidgetsApp` | widgets | class | no `.router`, `navigatorObservers`, `shortcuts` or `actions`; `title` names the window |
| 🟡 | `WidgetsBinding` | widgets | mixin | a class, not a mixin, speaking for the main window; no `platformDispatcher`, `renderView` or `deferFirstFrame` |
| 🟡 | `WidgetsFlutterBinding` | widgets | class | only `ensureInitialized` |
| 🟡 | `runApp` | widgets | function | returns `Future<Application>`; window title and size through `options:` |
| ❌ | `AlertDialog` | material | class |  |
| ❌ | `AnimatedCrossFade` | widgets | class |  |
| ❌ | `AnimatedRotation` | widgets | class |  |
| ❌ | `AnimatedScale` | widgets | class |  |
| ❌ | `AnimatedSlide` | widgets | class |  |
| ❌ | `AppBar` | material | class |  |
| ❌ | `AssetBundle` | services | class |  |
| ❌ | `AssetImage` | painting | class |  |
| ❌ | `AutomaticKeepAliveClientMixin` | widgets | mixin |  |
| ❌ | `BackdropFilter` | widgets | class |  |
| ❌ | `BottomNavigationBar` | material | class |  |
| ❌ | `BottomNavigationBarItem` | widgets | class |  |
| ❌ | `ButtonStyle` | material | class |  |
| ❌ | `Checkbox` | material | class |  |
| ❌ | `CheckboxListTile` | material | class |  |
| ❌ | `CircleAvatar` | material | class |  |
| ❌ | `ClipboardData` | services | class |  |
| ❌ | `ColorFiltered` | widgets | class |  |
| ❌ | `CustomSingleChildLayout` | widgets | class |  |
| ❌ | `DataTable` | material | class |  |
| ❌ | `DefaultTabController` | material | class |  |
| ❌ | `Drawer` | material | class |  |
| ❌ | `DropdownButton` | material | class |  |
| ❌ | `DropdownMenuItem` | material | class |  |
| ❌ | `EditableText` | widgets | class |  |
| ❌ | `ElevatedButton` | material | class |  |
| ❌ | `ExpansionTile` | material | class |  |
| ❌ | `FileImage` | painting | class |  |
| ❌ | `FilledButton` | material | class |  |
| ❌ | `FloatingActionButton` | material | class |  |
| ❌ | `HapticFeedback` | services | class |  |
| ❌ | `ImageFiltered` | widgets | class |  |
| ❌ | `ImageProvider` | painting | class |  |
| ❌ | `InkResponse` | material | class |  |
| ❌ | `InkWell` | material | class |  |
| ❌ | `ListBody` | widgets | class |  |
| ❌ | `ListTile` | material | class |  |
| ❌ | `Material` | material | class |  |
| ❌ | `MaterialApp` | material | class |  |
| ❌ | `MaterialPageRoute` | material | class |  |
| ❌ | `Matrix4` | gestures | class |  |
| ❌ | `MemoryImage` | painting | class |  |
| ❌ | `ModalRoute` | widgets | class |  |
| ❌ | `NavigationBar` | material | class |  |
| ❌ | `NavigationRail` | material | class |  |
| ❌ | `NetworkImage` | painting | class |  |
| ❌ | `OutlinedButton` | material | class |  |
| ❌ | `OverflowBar` | widgets | class |  |
| ❌ | `OverlayPortal` | widgets | class |  |
| ❌ | `PhysicalModel` | widgets | class |  |
| ❌ | `PositionedDirectional` | widgets | class |  |
| ❌ | `RadioListTile` | material | class |  |
| ❌ | `RangeSlider` | material | class |  |
| ❌ | `RefreshIndicator` | material | class |  |
| ❌ | `ReorderableListView` | material | class |  |
| ❌ | `Scaffold` | material | class |  |
| ❌ | `ScaffoldMessenger` | material | class |  |
| ❌ | `SearchBar` | material | class |  |
| ❌ | `SegmentedButton` | material | class |  |
| ❌ | `SelectionArea` | material | class |  |
| ❌ | `SimpleDialog` | material | class |  |
| ❌ | `SingleTickerProviderStateMixin` | widgets | mixin |  |
| ❌ | `SnackBar` | material | class |  |
| ❌ | `Stepper` | material | class |  |
| ❌ | `SwitchListTile` | material | class |  |
| ❌ | `SystemChrome` | services | class |  |
| ❌ | `SystemNavigator` | services | class |  |
| ❌ | `Tab` | material | class |  |
| ❌ | `TabBar` | material | class |  |
| ❌ | `TabBarView` | material | class |  |
| ❌ | `TabController` | material | class |  |
| ❌ | `TextButton` | material | class |  |
| ❌ | `Ticker` | scheduler | class |  |
| ❌ | `TickerProviderStateMixin` | widgets | mixin |  |
| ❌ | `rootBundle` | services | variable |  |
| ❌ | `showDatePicker` | material | function |  |
| ❌ | `showGeneralDialog` | widgets | function |  |
| ❌ | `showModalBottomSheet` | material | function |  |
| ❌ | `showTimePicker` | material | function |  |

## P1 por biblioteca

### `animation` (18%)

❌ `AlwaysStoppedAnimation`, `Animatable`, `AnimatableCallback`, `AnimationBehavior`, `AnimationEagerListenerMixin`, `AnimationLazyListenerMixin`, `AnimationLocalListenersMixin`, `AnimationLocalStatusListenersMixin`, `AnimationMax`, `AnimationMean`, `AnimationMin`, `AnimationStatusListener`, `AnimationStyle`, `AnimationWithParentMixin`, `CatmullRomCurve`, `CatmullRomSpline`, `CompoundAnimation`, `ConstantTween`, `Curve2D`, `Curve2DSample`, `CurveTween`, `ElasticInCurve`, `ElasticInOutCurve`, `ElasticOutCurve`, `FlippedTweenSequence`, `IntTween`, `ParametricCurve`, `ProxyAnimation`, `ReverseAnimation`, `ReverseTween`, `SawTooth`, `Split`, `StepTween`, `ThreePointCubic`, `TickerCanceled`, `TickerFuture`, `TickerProvider`, `TrainHoppingAnimation`, `TweenSequence`, `TweenSequenceItem`, `ValueListenableTransformer`, `kAlwaysCompleteAnimation`, `kAlwaysDismissedAnimation`

✅ `AnimationStatus`, `Cubic`, `Curve`, `FlippedCurve`, `Interval`, `RectTween`, `Simulation`, `SizeTween`, `SpringDescription`, `Threshold`

### `dart:ui` (41%)

❌ `AccessibilityFeatures`, `ChannelBuffers`, `ColorFilter`, `FilterQuality`, `FontFeature`, `FontVariation`, `GlyphInfo`, `ImageShader`, `ImmutableBuffer`, `KeyData`, `LineMetrics`, `LocaleStringAttribute`, `MaskFilter`, `PathOperation`, `PlatformMessageResponseCallback`, `PointerDeviceKind`, `RSTransform`, `RSuperellipse`, `RootIsolateToken`, `SemanticsActionEvent`, `SemanticsFlag`, `SemanticsFlags`, `SemanticsUpdateBuilder`, `SemanticsValidationResult`, `SpellOutStringAttribute`, `StringAttribute`, `TextHeightBehavior`, `TextLeadingDistribution`, `VertexMode`, `clampDouble`, `kTextHeightNone`

✅ `AppLifecycleState`, `BlurStyle`, `Brightness`, `FontStyle`, `Locale`, `PaintingStyle`, `PathFillType`, `PlaceholderAlignment`, `SemanticsAction`, `SemanticsRole`, `Shader`, `Shadow`, `StrokeCap`, `StrokeJoin`, `TextAffinity`, `TextBaseline`, `TextBox`, `TextDecoration`, `TextDecorationStyle`, `TextDirection`, `TextPosition`, `TileMode`

### `foundation` (10%)

❌ `AbstractNode`, `AggregatedTimedBlock`, `AggregatedTimings`, `BindingBase`, `BitField`, `BytesReceivedCallback`, `CachingIterable`, `Category`, `ComputeImpl`, `ComputePropertyValueCallback`, `DocumentationIcon`, `DoubleProperty`, `EnumProperty`, `ErrorToConsoleDumper`, `Factory`, `FlagProperty`, `FlagsSummary`, `FlutterExceptionHandler`, `FlutterMemoryAllocations`, `FlutterTimeline`, `FoundationServiceExtensions`, `HashedObserverList`, `InformationCollector`, `IntProperty`, `IterableFilter`, `IterableProperty`, `LicenseEntry`, `LicenseEntryCollector`, `LicenseEntryWithLineBreaks`, `LicenseParagraph`, `LicenseRegistry`, `MemoryAllocations`, `MessageProperty`, `ObjectCreated`, `ObjectDisposed`, `ObjectEvent`, `ObjectEventListener`, `ObjectFlagProperty`, `ObserverList`, `PartialStackFrame`, `PercentProperty`, `PersistentHashMap`, `ReadBuffer`, `RecordUse`, `RepetitiveStackFrameFilter`, `ServiceExtensionCallback`, `StackFilter`, `StackFrame`, `StackTraceDemangler`, `StringProperty`, `Summary`, `SynchronousFuture`, `TargetPlatform`, `TextTreeConfiguration`, `TextTreeRenderer`, `TimedBlock`, `Unicode`, `ValueListenable`, `WriteBuffer`, `awaitNotRequired`, `binarySearch`, `consolidateHttpClientResponseBytes`, `dashedTextConfiguration`, `denseTextConfiguration`, `describeEnum`, `describeIdentity`, `errorPropertyTextConfiguration`, `errorTextConfiguration`, `factory`, `flatTextConfiguration`, `immutable`, `internal`, `kFlutterMemoryAllocationsEnabled`, `kIsWasm`, `kMaxUnsignedSMI`, `kNoDefaultValue`, `lerpDuration`, `listEquals`, `mapEquals`, `mergeSort`, `mustBeConst`, `mustCallSuper`, `nonVirtual`, `objectRuntimeType`, `optionalTypeArgs`, `protected`, `required`, `setEquals`, `shallowTextConfiguration`, `shortHash`, `singleLineTextConfiguration`, `sparseTextConfiguration`, `transitionTextConfiguration`, `visibleForOverriding`, `visibleForTesting`, `whitespaceTextConfiguration`

✅ `AsyncCallback`, `AsyncValueGetter`, `AsyncValueSetter`, `ComputeCallback`, `LocalKey`, `ValueGetter`, `ValueSetter`, `compute`, `kDebugMode`, `kProfileMode`, `kReleaseMode`

### `gestures` (30%)

❌ `BaseTapAndDragGestureRecognizer`, `BaseTapGestureRecognizer`, `DelayedMultiDragGestureRecognizer`, `DeviceGestureSettings`, `DevicePixelRatioGetter`, `Drag`, `DragDownDetails`, `DragStartBehavior`, `EagerGestureRecognizer`, `ForcePressDetails`, `ForcePressGestureRecognizer`, `GestureArenaTeam`, `GestureCancelCallback`, `GestureDoubleTapCallback`, `GestureDragCancelCallback`, `GestureDragDownCallback`, `GestureDragEndCallback`, `GestureDragStartCallback`, `GestureDragUpdateCallback`, `GestureForceInterpolation`, `GestureForcePressEndCallback`, `GestureForcePressPeakCallback`, `GestureForcePressStartCallback`, `GestureForcePressUpdateCallback`, `GestureLongPressCallback`, `GestureLongPressCancelCallback`, `GestureLongPressDownCallback`, `GestureLongPressEndCallback`, `GestureLongPressMoveUpdateCallback`, `GestureLongPressStartCallback`, `GestureLongPressUpCallback`, `GestureMultiDragStartCallback`, `GestureMultiTapCallback`, `GestureMultiTapCancelCallback`, `GestureMultiTapDownCallback`, `GestureMultiTapUpCallback`, `GestureRecognizerState`, `GestureScaleEndCallback`, `GestureScaleStartCallback`, `GestureScaleUpdateCallback`, `GestureSerialTapCancelCallback`, `GestureSerialTapDownCallback`, `GestureSerialTapUpCallback`, `GestureTapCallback`, `GestureTapCancelCallback`, `GestureTapDownCallback`, `GestureTapDragDownCallback`, `GestureTapDragEndCallback`, `GestureTapDragStartCallback`, `GestureTapDragUpCallback`, `GestureTapDragUpdateCallback`, `GestureTapMoveCallback`, `GestureTapUpCallback`, `GestureVelocityTrackerBuilder`, `HandleEventCallback`, `HitTestDispatcher`, `HitTestEntry`, `HitTestResult`, `HitTestTarget`, `HitTestable`, `HorizontalMultiDragGestureRecognizer`, `IOSScrollViewFlingVelocityTracker`, `ImmediateMultiDragGestureRecognizer`, `LeastSquaresSolver`, `LongPressDownDetails`, `MacOSScrollViewFlingVelocityTracker`, `MultiDragGestureRecognizer`, `MultiDragPointerState`, `MultiTapGestureRecognizer`, `MultitouchDragStrategy`, `NativeHitTestTarget`, `OffsetPair`, `OneSequenceGestureRecognizer`, `PointerAddedEvent`, `PointerEnterEvent`, `PointerEventConverter`, `PointerEventResampler`, `PointerExitEvent`, `PointerRemovedEvent`, `PointerRoute`, `PointerScaleEvent`, `PointerScrollInertiaCancelEvent`, `PositionedGestureDetails`, `RecognizerCallback`, `RespondPointerEventCallback`, `SamplingClock`, `SerialTapCancelDetails`, `SerialTapDownDetails`, `SerialTapGestureRecognizer`, `SerialTapUpDetails`, `TapAndDragGestureRecognizer`, `TapAndHorizontalDragGestureRecognizer`, `TapAndPanGestureRecognizer`, `TapDownDetails`, `TapDragDownDetails`, `TapDragEndDetails`, `TapDragStartDetails`, `TapDragUpDetails`, `TapDragUpdateDetails`, `TapMoveDetails`, `TapUpDetails`, `VerticalMultiDragGestureRecognizer`, `computeHitSlop`, `computePanSlop`, `computeScaleSlop`, `isSingleButton`, `kDefaultTrackpadScrollToScaleFactor`, `kDoubleTapSlop`, `kDoubleTapTouchSlop`, `kHoverTapSlop`, `kHoverTapTimeout`, `kJumpTapTimeout`, `kPagingTouchSlop`, `kPanSlop`, `kPrecisePointerHitSlop`, `kPrecisePointerPanSlop`, `kPrecisePointerScaleSlop`, `kPressTimeout`, `kPrimaryStylusButton`, `kScaleSlop`, `kSecondaryStylusButton`, `kStylusContact`, `kTertiaryButton`, `kTouchContact`, `kWindowTouchSlop`, `kZoomControlsTimeout`, `nthMouseButton`, `nthStylusButton`, `smallestButton`

✅ `AllowedButtonsFilter`, `DoubleTapGestureRecognizer`, `DragEndDetails`, `DragGestureRecognizer`, `DragStartDetails`, `DragUpdateDetails`, `GestureArenaEntry`, `GestureArenaManager`, `GestureArenaMember`, `GestureBinding`, `GestureDisposition`, `GestureRecognizer`, `HorizontalDragGestureRecognizer`, `LongPressEndDetails`, `LongPressGestureRecognizer`, `LongPressMoveUpdateDetails`, `LongPressStartDetails`, `PanGestureRecognizer`, `PointerCancelEvent`, `PointerDownEvent`, `PointerEvent`, `PointerHoverEvent`, `PointerMoveEvent`, `PointerPanZoomEndEvent`, `PointerPanZoomStartEvent`, `PointerPanZoomUpdateEvent`, `PointerRouter`, `PointerScrollEvent`, `PointerSignalEvent`, `PointerSignalResolvedCallback`, `PointerSignalResolver`, `PointerUpEvent`, `PolynomialFit`, `PrimaryPointerGestureRecognizer`, `ScaleEndDetails`, `ScaleGestureRecognizer`, `ScaleStartDetails`, `ScaleUpdateDetails`, `TapGestureRecognizer`, `Velocity`, `VelocityEstimate`, `VelocityTracker`, `VerticalDragGestureRecognizer`, `kBackMouseButton`, `kDefaultMouseScrollToScaleFactor`, `kDoubleTapMinTime`, `kDoubleTapTimeout`, `kForwardMouseButton`, `kLongPressTimeout`, `kMaxFlingVelocity`, `kMiddleMouseButton`, `kMinFlingVelocity`, `kPrimaryButton`, `kPrimaryMouseButton`, `kSecondaryButton`, `kSecondaryMouseButton`, `kTouchSlop`

### `material` (3%)

❌ `AboutDialog`, `AboutListTile`, `ActionChip`, `ActionIconTheme`, `ActionIconThemeData`, `Adaptation`, `AdaptiveTextSelectionToolbar`, `AnimatedTheme`, `AppBarTheme`, `AppBarThemeData`, `Autocomplete`, `BackButton`, `BackButtonIcon`, `BadgeTheme`, `BadgeThemeData`, `BaseRangeSliderTrackShape`, `BaseSliderTrackShape`, `BottomAppBar`, `BottomAppBarTheme`, `BottomAppBarThemeData`, `BottomNavigationBarLandscapeLayout`, `BottomNavigationBarTheme`, `BottomNavigationBarThemeData`, `BottomNavigationBarType`, `BottomSheet`, `BottomSheetDragEndHandler`, `BottomSheetDragStartHandler`, `BottomSheetThemeData`, `ButtonBar`, `ButtonBarLayoutBehavior`, `ButtonBarTheme`, `ButtonBarThemeData`, `ButtonLayerBuilder`, `ButtonSegment`, `ButtonStyleButton`, `ButtonTextTheme`, `ButtonTheme`, `ButtonThemeData`, `CalendarDatePicker`, `CalendarDelegate`, `CardTheme`, `CardThemeData`, `CarouselController`, `CarouselScrollPhysics`, `CarouselView`, `CarouselViewTheme`, `CarouselViewThemeData`, `CheckboxMenuButton`, `CheckboxTheme`, `CheckboxThemeData`, `CheckedPopupMenuItem`, `CheckmarkableChipAttributes`, `ChipAnimationStyle`, `ChipAttributes`, `ChipTheme`, `ChipThemeData`, `ChoiceChip`, `CloseButton`, `CloseButtonIcon`, `ControlsDetails`, `ControlsWidgetBuilder`, `CupertinoBasedMaterialThemeData`, `DataCell`, `DataColumn`, `DataColumnSortCallback`, `DataRow`, `DataTableSource`, `DataTableTheme`, `DataTableThemeData`, `DatePickerDialog`, `DatePickerEntryMode`, `DatePickerMode`, `DatePickerTheme`, `DatePickerThemeData`, `DateRangePickerDialog`, `DateTimeRange`, `DateUtils`, `DayPeriod`, `DefaultMaterialLocalizations`, `DeletableChipAttributes`, `DesktopTextSelectionControls`, `DesktopTextSelectionToolbar`, `DesktopTextSelectionToolbarButton`, `DialogRoute`, `DialogTheme`, `DialogThemeData`, `DisabledChipAttributes`, `DividerTheme`, `DividerThemeData`, `DrawerAlignment`, `DrawerButton`, `DrawerButtonIcon`, `DrawerCallback`, `DrawerController`, `DrawerControllerState`, `DrawerHeader`, `DrawerTheme`, `DrawerThemeData`, `DropRangeSliderValueIndicatorShape`, `DropSliderValueIndicatorShape`, `DropdownButtonBuilder`, `DropdownButtonFormField`, `DropdownButtonHideUnderline`, `DropdownMenu`, `DropdownMenuCloseBehavior`, `DropdownMenuDecorationBuilder`, `DropdownMenuEntry`, `DropdownMenuFormField`, `DropdownMenuTheme`, `DropdownMenuThemeData`, `Durations`, `DynamicSchemeVariant`, `Easing`, `ElevatedButtonTheme`, `ElevatedButtonThemeData`, `ElevationOverlay`, `EndDrawerButton`, `EndDrawerButtonIcon`, `EntryModeChangeCallback`, `ExpandIcon`, `ExpansionPanel`, `ExpansionPanelCallback`, `ExpansionPanelHeaderBuilder`, `ExpansionPanelList`, `ExpansionPanelRadio`, `ExpansionTileController`, `ExpansionTileTheme`, `ExpansionTileThemeData`, `FabCenterOffsetX`, `FabContainedOffsetY`, `FabDockedOffsetY`, `FabEndOffsetX`, `FabFloatOffsetY`, `FabMiniOffsetAdjustment`, `FabStartOffsetX`, `FabTopOffsetY`, `FadeForwardsPageTransitionsBuilder`, `FilledButtonTheme`, `FilledButtonThemeData`, `FilterCallback`, `FilterChip`, `FloatingActionButtonAnimator`, `FloatingActionButtonLocation`, `FloatingActionButtonTheme`, `FloatingActionButtonThemeData`, `FloatingLabelAlignment`, `GappedRangeSliderTrackShape`, `GappedSliderTrackShape`, `GregorianCalendarDelegate`, `GridTile`, `GridTileBar`, `HandleRangeSliderThumbShape`, `HandleThumbShape`, `HourFormat`, `IconAlignment`, `IconButtonTheme`, `IconButtonThemeData`, `Ink`, `InkDecoration`, `InkFeature`, `InkHighlight`, `InkRipple`, `InkSparkle`, `InkSplash`, `InputChip`, `InputCounterWidgetBuilder`, `InputDatePickerFormField`, `InputDecorationTheme`, `InputDecorationThemeData`, `InteractiveInkFeature`, `InteractiveInkFeatureFactory`, `LicensePage`, `ListTileControlAffinity`, `ListTileStyle`, `ListTileTheme`, `ListTileThemeData`, `ListTileTitleAlignment`, `Magnifier`, `MaterialAccentColor`, `MaterialBanner`, `MaterialBannerClosedReason`, `MaterialBannerTheme`, `MaterialBannerThemeData`, `MaterialBasedCupertinoThemeData`, `MaterialButton`, `MaterialColor`, `MaterialGap`, `MaterialInkController`, `MaterialLocalizations`, `MaterialPage`, `MaterialPointArcTween`, `MaterialPropertyResolver`, `MaterialRectArcTween`, `MaterialRectCenterArcTween`, `MaterialRouteTransitionMixin`, `MaterialScrollBehavior`, `MaterialSlice`, `MaterialState`, `MaterialStateBorderSide`, `MaterialStateColor`, `MaterialStateMixin`, `MaterialStateMouseCursor`, `MaterialStateOutlineInputBorder`, `MaterialStateOutlinedBorder`, `MaterialStateProperty`, `MaterialStatePropertyAll`, `MaterialStateTextStyle`, `MaterialStateUnderlineInputBorder`, `MaterialStatesController`, `MaterialTapTargetSize`, `MaterialTextSelectionControls`, `MaterialTextSelectionHandleControls`, `MaterialType`, `MenuAcceleratorCallbackBinding`, `MenuAcceleratorChildBuilder`, `MenuAnchorChildBuilder`, `MenuBarTheme`, `MenuBarThemeData`, `MenuButtonTheme`, `MenuButtonThemeData`, `MenuStyle`, `MenuTheme`, `MenuThemeData`, `MergeableMaterial`, `MergeableMaterialItem`, `ModalBottomSheetRoute`, `NavigationBarTheme`, `NavigationBarThemeData`, `NavigationDestination`, `NavigationDestinationLabelBehavior`, `NavigationDrawer`, `NavigationDrawerDestination`, `NavigationDrawerTheme`, `NavigationDrawerThemeData`, `NavigationIndicator`, `NavigationRailDestination`, `NavigationRailLabelType`, `NavigationRailTheme`, `NavigationRailThemeData`, `NoSplash`, `OutlinedButtonTheme`, `OutlinedButtonThemeData`, `PaddleRangeSliderValueIndicatorShape`, `PaddleSliderValueIndicatorShape`, `PageTransitionsTheme`, `PaginatedDataTable`, `PaginatedDataTableState`, `PaintRangeValueIndicator`, `PaintValueIndicator`, `PersistentBottomSheetController`, `PlatformAdaptiveIcons`, `PopupMenuButtonState`, `PopupMenuCanceled`, `PopupMenuItemBuilder`, `PopupMenuItemSelected`, `PopupMenuItemState`, `PopupMenuPosition`, `PopupMenuPositionBuilder`, `PopupMenuTheme`, `PopupMenuThemeData`, `PredictiveBackFullscreenPageTransitionsBuilder`, `PredictiveBackPageTransitionsBuilder`, `ProgressIndicator`, `ProgressIndicatorTheme`, `RadioMenuButton`, `RadioTheme`, `RadioThemeData`, `RangeLabels`, `RangeSliderThumbShape`, `RangeSliderTickMarkShape`, `RangeSliderTrackShape`, `RangeSliderValueIndicatorShape`, `RangeThumbSelector`, `RangeValues`, `RawChip`, `RawMaterialButton`, `RectCallback`, `RectangularRangeSliderTrackShape`, `RectangularRangeSliderValueIndicatorShape`, `RectangularSliderTrackShape`, `RectangularSliderValueIndicatorShape`, `RefreshCallback`, `RefreshIndicatorState`, `RefreshIndicatorStatus`, `RefreshIndicatorTriggerMode`, `RefreshProgressIndicator`, `RestorableTimeOfDay`, `RoundRangeSliderThumbShape`, `RoundRangeSliderTickMarkShape`, `RoundSliderOverlayShape`, `RoundSliderThumbShape`, `RoundSliderTickMarkShape`, `RoundedRectRangeSliderTrackShape`, `RoundedRectRangeSliderValueIndicatorShape`, `RoundedRectSliderTrackShape`, `RoundedRectSliderValueIndicatorShape`, `ScaffoldFeatureController`, `ScaffoldGeometry`, `ScaffoldMessengerState`, `ScaffoldPrelayoutGeometry`, `ScaffoldState`, `ScriptCategory`, `ScrollbarTheme`, `SearchAnchor`, `SearchAnchorChildBuilder`, `SearchBarTheme`, `SearchBarThemeData`, `SearchCallback`, `SearchController`, `SearchDelegate`, `SearchViewTheme`, `SearchViewThemeData`, `SegmentedButtonState`, `SegmentedButtonTheme`, `SegmentedButtonThemeData`, `SelectableChipAttributes`, `SelectableDayForRangePredicate`, `SelectionAreaState`, `SemanticFormatterCallback`, `ShapeBorderTween`, `ShapedInputBorder`, `ShowValueIndicator`, `SimpleDialogOption`, `SliderComponentShape`, `SliderInteraction`, `SliderTheme`, `SliderThemeData`, `SliderTickMarkShape`, `SliderTrackShape`, `SnackBarAction`, `SnackBarBehavior`, `SnackBarClosedReason`, `SnackBarTheme`, `SnackBarThemeData`, `SpellCheckSuggestionsToolbar`, `SpellCheckSuggestionsToolbarLayoutDelegate`, `StandardFabLocation`, `Step`, `StepIconBuilder`, `StepState`, `StepStyle`, `StepperType`, `StretchMode`, `SuggestionsBuilder`, `SwitchTheme`, `SwitchThemeData`, `TabAlignment`, `TabBarIndicatorSize`, `TabBarScrollController`, `TabBarTheme`, `TabBarThemeData`, `TabIndicatorAnimation`, `TabPageSelector`, `TabPageSelectorIndicator`, `TabValueChanged`, `TableRowInkWell`, `TappableChipAttributes`, `TextButtonTheme`, `TextButtonThemeData`, `TextMagnifier`, `TextSelectionTheme`, `TextSelectionThemeData`, `TextSelectionToolbar`, `TextSelectionToolbarTextButton`, `ThemeDataTween`, `ThemeExtension`, `ThemeMode`, `Thumb`, `TimeOfDayFormat`, `TimePickerDialog`, `TimePickerEntryMode`, `TimePickerTheme`, `TimePickerThemeData`, `ToggleButtons`, `ToggleButtonsTheme`, `ToggleButtonsThemeData`, `TooltipState`, `TooltipTheme`, `TooltipThemeData`, `TooltipVisibility`, `Typography`, `UnderlineTabIndicator`, `UserAccountsDrawerHeader`, `ViewBuilder`, `VisualDensity`, `WidgetStateInputBorder`, `YearPicker`, `ZoomPageTransitionsBuilder`, `accelerateEasing`, `decelerateEasing`, `desktopTextSelectionControls`, `desktopTextSelectionHandleControls`, `hourFormat`, `kBottomNavigationBarHeight`, `kElevationToShadow`, `kFloatingActionButtonMargin`, `kFloatingActionButtonSegue`, `kFloatingActionButtonTurnInterval`, `kMaterialEdges`, `kMaterialListPadding`, `kMiniButtonOffsetAdjustment`, `kRadialReactionAlpha`, `kRadialReactionDuration`, `kRadialReactionRadius`, `kTabLabelPadding`, `kTabScrollDuration`, `kTextTabBarHeight`, `kThemeAnimationDuration`, `kThemeChangeDuration`, `kToolbarHeight`, `materialTextSelectionControls`, `materialTextSelectionHandleControls`, `showAboutDialog`, `showAdaptiveAboutDialog`, `showAdaptiveDialog`, `showBottomSheet`, `showDateRangePicker`, `showLicensePage`, `showSearch`, `standardEasing`

🟡 `InputDecorator`: the label floats without animation

✅ `CollapseMode`, `FlexibleSpaceBar`, `FlexibleSpaceBarSettings`, `FloatingLabelBehavior`, `InputBorder`, `MenuAcceleratorLabel`, `PopupMenuDivider`, `PopupMenuEntry`, `ProgressIndicatorThemeData`, `ScrollbarThemeData`, `TimeOfDay`, `UnderlineInputBorder`, `VerticalDivider`, `kMinInteractiveDimension`

### `painting` (28%)

❌ `Accumulator`, `AssetBundleImageKey`, `AssetBundleImageProvider`, `AutomaticNotchedShape`, `BeveledRectangleBorder`, `CircularNotchedRectangle`, `ClipContext`, `ColorProperty`, `ColorSwatch`, `ContinuousRectangleBorder`, `DecoderBufferCallback`, `DecorationImage`, `DecorationImagePainter`, `ExactAssetImage`, `FlutterLogoDecoration`, `FlutterLogoStyle`, `FractionalOffset`, `GradientRotation`, `GradientTransform`, `HSLColor`, `HSVColor`, `HttpClientProvider`, `ImageCache`, `ImageCacheStatus`, `ImageChunkEvent`, `ImageChunkListener`, `ImageConfiguration`, `ImageDecoderCallback`, `ImageErrorListener`, `ImageInfo`, `ImageListener`, `ImageRepeat`, `ImageSizeInfo`, `ImageStream`, `ImageStreamCompleter`, `ImageStreamCompleterHandle`, `ImageStreamListener`, `InlineSpanSemanticsInformation`, `InlineSpanVisitor`, `LinearBorder`, `LinearBorderEdge`, `MatrixUtils`, `MultiFrameImageStreamCompleter`, `NetworkImageLoadException`, `NotchedShape`, `OneFrameImageStreamCompleter`, `OvalBorder`, `PaintImageCallback`, `PaintingBinding`, `RenderComparison`, `ResizeImage`, `ResizeImageKey`, `ResizeImagePolicy`, `RoundedSuperellipseBorder`, `ShaderWarmUp`, `ShaderWarmUpImageCallback`, `ShaderWarmUpPictureCallback`, `StarBorder`, `StrutStyle`, `TextAlignVertical`, `TextScaler`, `TextWidthBasis`, `TransformProperty`, `VerticalDirection`, `WordBoundary`, `combineSemanticsInfo`, `decodeImageFromList`, `flipAxis`, `kDefaultFontSize`, `lerpFontVariations`, `paintImage`, `paintZigZag`, `positionDependentBox`

🟡 `TextRange`: `TextRange(start, end)` is positional

✅ `AlignmentGeometry`, `Axis`, `AxisDirection`, `BorderDirectional`, `BorderRadiusDirectional`, `BorderRadiusGeometry`, `BorderStyle`, `BoxBorder`, `BoxPainter`, `BoxShape`, `CircleBorder`, `Decoration`, `EdgeInsetsGeometry`, `FittedSizes`, `Gradient`, `InlineSpan`, `OutlinedBorder`, `PlaceholderDimensions`, `PlaceholderSpan`, `RoundedRectangleBorder`, `ShapeBorder`, `StadiumBorder`, `TextPainter`, `applyBoxFit`, `axisDirectionIsReversed`, `axisDirectionToAxis`, `flipAxisDirection`, `paintBorder`, `textDirectionToAxisDirection`

### `physics` (40%)

❌ `BoundedFrictionSimulation`, `ClampedSimulation`, `GravitySimulation`, `ScrollSpringSimulation`, `nearEqual`, `nearZero`

✅ `FrictionSimulation`, `SpringSimulation`, `SpringType`, `Tolerance`

### `rendering` (33%)

❌ `AlignmentGeometryTween`, `AlignmentTween`, `AnnotatedRegionLayer`, `AnnotationEntry`, `AnnotationResult`, `BackdropFilterLayer`, `BackdropKey`, `BoxConstraintsTransform`, `BoxHitTest`, `BoxHitTestEntry`, `BoxHitTestResult`, `BoxHitTestWithOutOfBandPosition`, `CacheExtentStyle`, `ChildBaselineGetter`, `ChildLayoutHelper`, `ChildLayouter`, `ClearSelectionEvent`, `ClipPathLayer`, `ClipRRectLayer`, `ClipRSuperellipseLayer`, `ClipRectLayer`, `ColorFilterLayer`, `CompositionCallback`, `Constraints`, `ContainerBoxParentData`, `ContainerLayer`, `ContainerParentDataMixin`, `ContainerRenderObjectMixin`, `CustomPainterSemantics`, `DirectionallyExtendSelectionEvent`, `FloatingHeaderSnapConfiguration`, `FollowerLayer`, `FractionalOffsetTween`, `GranularlyExtendSelectionEvent`, `GrowthDirection`, `ImageFilterConfig`, `ImageFilterContext`, `ImageFilterLayer`, `ItemExtentBuilder`, `KeepAliveParentDataMixin`, `Layer`, `LayerHandle`, `LayerLink`, `LayoutCallback`, `LeaderLayer`, `ListBodyParentData`, `ListWheelChildManager`, `ListWheelParentData`, `MouseTracker`, `MouseTrackerHitTest`, `OffsetLayer`, `OpacityLayer`, `OverScrollHeaderStretchConfiguration`, `OverflowBoxFit`, `PaintingContext`, `PaintingContextCallback`, `ParentData`, `PerformanceOverlayLayer`, `PerformanceOverlayOption`, `PersistentHeaderShowOnScreenConfiguration`, `PictureLayer`, `PipelineManifold`, `PipelineOwnerVisitor`, `PlaceholderSpanIndexSemanticsTag`, `ProfilePaintCallback`, `RelayoutWhenSystemFontsChangeMixin`, `RenderAbstractViewport`, `RenderAligningShiftedBox`, `RenderAnimatedOpacity`, `RenderAnimatedOpacityMixin`, `RenderAnimatedSizeState`, `RenderAnnotatedRegion`, `RenderBackdropFilter`, `RenderBlockSemantics`, `RenderBoxContainerDefaultsMixin`, `RenderClipRSuperellipse`, `RenderConstrainedOverflowBox`, `RenderConstraintsTransformBox`, `RenderCustomSingleChildLayoutBox`, `RenderDecoratedSliver`, `RenderEditable`, `RenderEditablePainter`, `RenderErrorBox`, `RenderExcludeSemantics`, `RenderFollowerLayer`, `RenderFractionallySizedOverflowBox`, `RenderIgnoreBaseline`, `RenderIndexedSemantics`, `RenderIndexedStack`, `RenderInlineChildrenContainerDefaults`, `RenderLeaderLayer`, `RenderListBody`, `RenderListWheelViewport`, `RenderMergeSemantics`, `RenderMetaData`, `RenderObjectVisitor`, `RenderObjectWithChildMixin`, `RenderObjectWithLayoutCallbackMixin`, `RenderOffstage`, `RenderParagraph`, `RenderPerformanceOverlay`, `RenderPhysicalModel`, `RenderPhysicalShape`, `RenderPositionedBox`, `RenderProxyBoxMixin`, `RenderProxyBoxWithHitTestBehavior`, `RenderProxySliver`, `RenderSemanticsGestureHandler`, `RenderShiftedBox`, `RenderShrinkWrappingViewport`, `RenderSliverAnimatedOpacity`, `RenderSliverBoxChildManager`, `RenderSliverConstrainedCrossAxis`, `RenderSliverCrossAxisGroup`, `RenderSliverEdgeInsetsPadding`, `RenderSliverFillRemainingAndOverscroll`, `RenderSliverFillRemainingWithScrollable`, `RenderSliverFillViewport`, `RenderSliverFixedExtentBoxAdaptor`, `RenderSliverFixedExtentList`, `RenderSliverFloatingPersistentHeader`, `RenderSliverFloatingPinnedPersistentHeader`, `RenderSliverHelpers`, `RenderSliverIgnorePointer`, `RenderSliverMainAxisGroup`, `RenderSliverOffstage`, `RenderSliverOpacity`, `RenderSliverPinnedPersistentHeader`, `RenderSliverScrollingPersistentHeader`, `RenderSliverSemanticsAnnotations`, `RenderSliverSingleBoxAdapter`, `RenderSliverVariedExtentList`, `RenderSliverWithKeepAliveMixin`, `RenderTreeSliver`, `RenderView`, `RenderViewportBase`, `RendererBinding`, `RenderingFlutterBinding`, `RenderingServiceExtensions`, `RevealedOffset`, `ScrollCacheExtent`, `SelectAllSelectionEvent`, `SelectParagraphSelectionEvent`, `SelectWordSelectionEvent`, `Selectable`, `SelectedContent`, `SelectedContentRange`, `SelectionEdgeUpdateEvent`, `SelectionEvent`, `SelectionEventType`, `SelectionExtendDirection`, `SelectionGeometry`, `SelectionHandler`, `SelectionPoint`, `SelectionRegistrant`, `SelectionRegistrar`, `SelectionResult`, `SelectionStatus`, `SelectionUtils`, `SemanticsAnnotationsMixin`, `SemanticsBuilderCallback`, `ShaderMaskLayer`, `SingleChildLayoutDelegate`, `SliverGridGeometry`, `SliverGridParentData`, `SliverGridRegularTileLayout`, `SliverHitTest`, `SliverHitTestEntry`, `SliverHitTestResult`, `SliverLayoutDimensions`, `SliverLogicalContainerParentData`, `SliverLogicalParentData`, `SliverPaintOrder`, `SliverPhysicalContainerParentData`, `SliverPhysicalParentData`, `TextGranularity`, `TextParentData`, `TextSelectionHandleType`, `TextSelectionPoint`, `TextureBox`, `TextureLayer`, `TransformLayer`, `TreeSliverIndentationType`, `TreeSliverNodeParentData`, `TreeSliverNodesAnimation`, `VerticalCaretMovementRun`, `ViewConfiguration`, `ViewportOffset`, `WrapAlignment`, `applyGrowthDirectionToAxisDirection`, `applyGrowthDirectionToScrollDirection`, `const`

✅ `BoxConstraints`, `BoxParentData`, `CrossAxisAlignment`, `DecorationPosition`, `FixedColumnWidth`, `FlexColumnWidth`, `FlexFit`, `FlexParentData`, `FlowDelegate`, `FlowPaintingContext`, `FlowParentData`, `FractionColumnWidth`, `HitTestBehavior`, `IntrinsicColumnWidth`, `MainAxisAlignment`, `MainAxisSize`, `MaxColumnWidth`, `MinColumnWidth`, `MultiChildLayoutDelegate`, `MultiChildLayoutParentData`, `PipelineOwner`, `PointerCancelEventListener`, `PointerDownEventListener`, `PointerMoveEventListener`, `PointerPanZoomEndEventListener`, `PointerPanZoomStartEventListener`, `PointerPanZoomUpdateEventListener`, `PointerSignalEventListener`, `PointerUpEventListener`, `RelativeRect`, `RenderAbsorbPointer`, `RenderAnimatedSize`, `RenderAspectRatio`, `RenderBaseline`, `RenderBox`, `RenderClipOval`, `RenderClipPath`, `RenderClipRRect`, `RenderClipRect`, `RenderConstrainedBox`, `RenderCustomMultiChildLayoutBox`, `RenderCustomPaint`, `RenderDecoratedBox`, `RenderFittedBox`, `RenderFlex`, `RenderFlow`, `RenderFractionalTranslation`, `RenderIgnorePointer`, `RenderImage`, `RenderIntrinsicHeight`, `RenderIntrinsicWidth`, `RenderLimitedBox`, `RenderMouseRegion`, `RenderObject`, `RenderOpacity`, `RenderPadding`, `RenderPointerListener`, `RenderProxyBox`, `RenderRepaintBoundary`, `RenderRotatedBox`, `RenderSemanticsAnnotations`, `RenderShaderMask`, `RenderSizedOverflowBox`, `RenderSliver`, `RenderSliverFillRemaining`, `RenderSliverGrid`, `RenderSliverList`, `RenderSliverMultiBoxAdaptor`, `RenderSliverPadding`, `RenderSliverPersistentHeader`, `RenderSliverToBoxAdapter`, `RenderStack`, `RenderTable`, `RenderTransform`, `RenderViewport`, `RenderWrap`, `ScrollDirection`, `ShaderCallback`, `ShapeBorderClipper`, `SliverConstraints`, `SliverGeometry`, `SliverGridDelegate`, `SliverGridDelegateWithFixedCrossAxisCount`, `SliverGridDelegateWithMaxCrossAxisExtent`, `SliverGridLayout`, `SliverMultiBoxAdaptorParentData`, `StackFit`, `StackParentData`, `TableBorder`, `TableCellParentData`, `TableCellVerticalAlignment`, `TableColumnWidth`, `WrapCrossAlignment`, `WrapParentData`, `flipScrollDirection`

### `scheduler` (18%)

❌ `PerformanceModeRequestHandle`, `Priority`, `SchedulerPhase`, `SchedulerServiceExtensions`, `SchedulingStrategy`, `TaskCallback`, `TickerCallback`, `defaultSchedulingStrategy`, `timeDilation`

✅ `FrameCallback`, `SchedulerBinding`

### `semantics` (10%)

❌ `AccessibilityFocusBlockType`, `AnnounceSemanticsEvent`, `Assertiveness`, `AttributedString`, `AttributedStringProperty`, `ChildSemanticsConfigurationsDelegate`, `ChildSemanticsConfigurationsResult`, `ChildSemanticsConfigurationsResultBuilder`, `CustomSemanticsAction`, `FocusSemanticEvent`, `LongPressSemanticsEvent`, `MoveCursorHandler`, `OrdinalSortKey`, `ScrollToOffsetHandler`, `SemanticsActionHandler`, `SemanticsBinding`, `SemanticsData`, `SemanticsEvent`, `SemanticsHandle`, `SemanticsHintOverrides`, `SemanticsLabelBuilder`, `SemanticsNodeVisitor`, `SemanticsProperties`, `SemanticsService`, `SemanticsSortKey`, `SemanticsTag`, `SemanticsUpdateCallback`, `SetSelectionHandler`, `SetTextHandler`, `TapSemanticEvent`, `TooltipSemanticsEvent`

🟡 `TextSelection`: `TextSelection.collapsed(offset)` is positional

✅ `SemanticsConfiguration`, `SemanticsNode`, `SemanticsOwner`

### `services` (8%)

❌ `AndroidMotionEvent`, `AndroidPointerCoords`, `AndroidPointerProperties`, `ApplicationSwitcherDescription`, `AssetManifest`, `AssetMetadata`, `AutofillClient`, `AutofillConfiguration`, `AutofillHints`, `AutofillScope`, `AutofillScopeMixin`, `BackgroundIsolateBinaryMessenger`, `BasicMessageChannel`, `BinaryCodec`, `BinaryMessenger`, `BrowserContextMenu`, `CachingAssetBundle`, `CharacterBoundary`, `ContentSensitivity`, `DefaultProcessTextService`, `DefaultSpellCheckService`, `DeferredComponent`, `DeltaTextInputClient`, `DeviceOrientation`, `DocumentBoundary`, `EventChannel`, `FloatingCursorDragState`, `FlutterVersion`, `FontLoader`, `GLFWKeyHelper`, `GtkKeyHelper`, `IOSSystemContextMenuItemData`, `IOSSystemContextMenuItemDataCopy`, `IOSSystemContextMenuItemDataCustom`, `IOSSystemContextMenuItemDataCut`, `IOSSystemContextMenuItemDataLiveText`, `IOSSystemContextMenuItemDataLookUp`, `IOSSystemContextMenuItemDataPaste`, `IOSSystemContextMenuItemDataSelectAll`, `IOSSystemContextMenuItemDataShare`, `JSONMessageCodec`, `JSONMethodCodec`, `KeyDataTransitMode`, `KeyEventManager`, `KeyHelper`, `KeyMessage`, `KeyMessageHandler`, `KeyRepeatEvent`, `KeyboardInsertedContent`, `KeyboardKey`, `KeyboardLockMode`, `KeyboardSide`, `LineBoundary`, `LiveText`, `MessageCodec`, `MessageHandler`, `MethodCall`, `MethodChannel`, `MethodCodec`, `MissingPluginException`, `ModifierKey`, `MouseCursor`, `MouseCursorManager`, `MouseCursorSession`, `MouseTrackerAnnotation`, `NetworkAssetBundle`, `OptionalMethodChannel`, `ParagraphBoundary`, `PhysicalKeyboardKey`, `PlatformAssetBundle`, `PlatformException`, `PointTransformer`, `PointerEnterEventListener`, `PointerExitEventListener`, `PredictiveBackEvent`, `ProcessTextAction`, `ProcessTextService`, `RawFloatingCursorPoint`, `RawKeyDownEvent`, `RawKeyEvent`, `RawKeyEventData`, `RawKeyEventDataAndroid`, `RawKeyEventDataFuchsia`, `RawKeyEventDataIos`, `RawKeyEventDataLinux`, `RawKeyEventDataMacOs`, `RawKeyEventDataWindows`, `RawKeyEventHandler`, `RawKeyUpEvent`, `RawKeyboard`, `RestorationBucket`, `RestorationManager`, `ScribbleClient`, `Scribe`, `SelectionRect`, `SensitiveContentService`, `ServicesBinding`, `ServicesServiceExtensions`, `SmartDashesType`, `SmartQuotesType`, `SpellCheckResults`, `SpellCheckService`, `StandardMessageCodec`, `StandardMethodCodec`, `StringCodec`, `SuggestionSpan`, `SwipeEdge`, `SystemChannels`, `SystemContextMenuClient`, `SystemContextMenuController`, `SystemMouseCursor`, `SystemMouseCursors`, `SystemSound`, `SystemSoundType`, `SystemUiChangeCallback`, `SystemUiMode`, `SystemUiOverlay`, `SystemUiOverlayStyle`, `TextBoundary`, `TextEditingDelta`, `TextEditingDeltaDeletion`, `TextEditingDeltaInsertion`, `TextEditingDeltaNonTextUpdate`, `TextEditingDeltaReplacement`, `TextInput`, `TextInputControl`, `TextInputStyle`, `TextLayoutMetrics`, `TextSelectionDelegate`, `UndoDirection`, `UndoManager`, `UndoManagerClient`, `UntilPredicate`, `appBuildName`, `appBuildNumber`, `appFlavor`, `kAndroidNumPadMap`, `kAndroidToLogicalKey`, `kAndroidToPhysicalKey`, `kFuchsiaToLogicalKey`, `kFuchsiaToPhysicalKey`, `kGlfwNumpadMap`, `kGlfwToLogicalKey`, `kGtkNumpadMap`, `kGtkToLogicalKey`, `kIosNumPadMap`, `kIosSpecialLogicalMap`, `kIosToLogicalKey`, `kIosToPhysicalKey`, `kLinuxToPhysicalKey`, `kMacOsFunctionKeyMap`, `kMacOsNumPadMap`, `kMacOsToLogicalKey`, `kMacOsToPhysicalKey`, `kProfilePlatformChannels`, `kWindowsNumPadMap`, `kWindowsToLogicalKey`, `kWindowsToPhysicalKey`, `platformViewsRegistry`, `runeToLowerCase`

✅ `HardwareKeyboard`, `KeyDownEvent`, `KeyEvent`, `KeyEventCallback`, `KeyUpEvent`, `MaxLengthEnforcement`, `PointerHoverEventListener`, `SelectionChangedCause`, `TextCapitalization`, `TextEditingValue`, `TextInputClient`, `TextInputConfiguration`, `TextInputConnection`, `TextInputFormatFunction`

### `widgets` (20%)

❌ `AbstractLayoutBuilder`, `AccessibilityServiceExtensions`, `ActionListener`, `AlignTransition`, `AndroidOverscrollIndicator`, `AnimatedCrossFadeBuilder`, `AnimatedFractionallySizedBox`, `AnimatedGrid`, `AnimatedGridState`, `AnimatedItemBuilder`, `AnimatedModalBarrier`, `AnimatedPhysicalModel`, `AnimatedPositionedDirectional`, `AnimatedRemovedItemBuilder`, `AnimatedSwitcherLayoutBuilder`, `AnimatedSwitcherTransitionBuilder`, `AnimatedTransitionBuilder`, `AnimatedWidgetBaseState`, `AnnotatedRegion`, `AppExitRequestCallback`, `AppLifecycleListener`, `AppPrivateCommandCallback`, `AsyncWidgetBuilder`, `AutocompleteFieldViewBuilder`, `AutocompleteFirstOptionIntent`, `AutocompleteHighlightedOption`, `AutocompleteLastOptionIntent`, `AutocompleteNextOptionIntent`, `AutocompleteNextPageOptionIntent`, `AutocompleteOnSelected`, `AutocompleteOptionToString`, `AutocompleteOptionsBuilder`, `AutocompleteOptionsViewBuilder`, `AutocompletePreviousOptionIntent`, `AutocompletePreviousPageOptionIntent`, `AutofillContextAction`, `AutofillGroup`, `AutofillGroupState`, `AutomaticKeepAlive`, `BackButtonDispatcher`, `BackButtonListener`, `BackdropGroup`, `BallisticScrollActivity`, `Banner`, `BannerLocation`, `BannerPainter`, `BlockSemantics`, `BorderRadiusTween`, `BorderTween`, `BoxConstraintsTween`, `BoxScrollView`, `BuildScope`, `CapturedThemes`, `ChangeReportingBehavior`, `ChildBackButtonDispatcher`, `ChildIndexGetter`, `ChildVicinity`, `ClipRSuperellipse`, `ClipboardStatus`, `ClipboardStatusNotifier`, `CompositedTransformFollower`, `CompositedTransformTarget`, `ConditionalElementVisitor`, `ConstrainedLayoutBuilder`, `ConstraintsTransformBox`, `ContentInsertionConfiguration`, `ContextMenuButtonItem`, `ContextMenuButtonType`, `CopySelectionTextIntent`, `CreateRectTween`, `CrossFadeState`, `DecoratedBoxTransition`, `DecoratedSliver`, `DecorationTween`, `DefaultAssetBundle`, `DefaultPlatformMenuDelegate`, `DefaultSelectionStyle`, `DefaultTextEditingShortcuts`, `DefaultTextHeightBehavior`, `DefaultTextStyleTransition`, `DefaultTransitionDelegate`, `DefaultWidgetsLocalizations`, `DelegatedTransitionBuilder`, `DeleteCharacterIntent`, `DeleteToLineBreakIntent`, `DeleteToNextWordBoundaryIntent`, `DesktopTextSelectionToolbarLayoutDelegate`, `DeviceOrientationBuilder`, `DiagonalDragBehavior`, `DidRemovePageCallback`, `DirectionalCaretMovementIntent`, `DirectionalFocusTraversalPolicyMixin`, `DirectionalTextEditingIntent`, `DismissMenuAction`, `DisplayFeatureSubScreen`, `DisposableBuildContext`, `DoNothingAndStopPropagationTextIntent`, `DragBoundary`, `DragBoundaryDelegate`, `DragScrollActivity`, `DraggableScrollableActuator`, `DraggableScrollableController`, `DraggableScrollableNotification`, `DraggableScrollableSheet`, `DrivenScrollActivity`, `DualTransitionBuilder`, `EdgeDraggingAutoScroller`, `EdgeInsetsGeometryTween`, `EdgeInsetsTween`, `EditableTextContextMenuBuilder`, `EditableTextState`, `EditableTextTapOutsideIntent`, `EditableTextTapUpOutsideIntent`, `ElementCreatedCallback`, `ElementVisitor`, `EmptyTextSelectionControls`, `ExcludeFocusTraversal`, `ExcludeSemantics`, `ExpandSelectionToDocumentBoundaryIntent`, `ExpandSelectionToLineBreakIntent`, `Expansible`, `ExpansibleBuilder`, `ExpansibleComponentBuilder`, `ExpansibleController`, `ExtendSelectionByCharacterIntent`, `ExtendSelectionToDocumentBoundaryIntent`, `ExtendSelectionToLineBreakIntent`, `ExtendSelectionToNextParagraphBoundaryIntent`, `ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent`, `ExtendSelectionToNextWordBoundaryIntent`, `ExtendSelectionToNextWordBoundaryOrCaretLocationIntent`, `ExtendSelectionVerticallyToAdjacentLineIntent`, `ExtendSelectionVerticallyToAdjacentPageIntent`, `FadeInImage`, `FadeUpwardsPageTransitionsBuilder`, `Feedback`, `FixedExtentMetrics`, `FixedExtentScrollController`, `FixedExtentScrollPhysics`, `FloatingHeaderSnapMode`, `FocusHighlightMode`, `FocusHighlightStrategy`, `FocusOnKeyCallback`, `FocusableActionDetector`, `GestureRecognizerFactory`, `GestureRecognizerFactoryConstructor`, `GestureRecognizerFactoryInitializer`, `GestureRecognizerFactoryWithHandlers`, `GlowingOverscrollIndicator`, `GridPaper`, `HeroController`, `HeroControllerScope`, `HeroFlightDirection`, `HeroFlightShuttleBuilder`, `HeroMode`, `HeroPlaceholderBuilder`, `HoldScrollActivity`, `IOSSystemContextMenuItem`, `IOSSystemContextMenuItemCopy`, `IOSSystemContextMenuItemCustom`, `IOSSystemContextMenuItemCut`, `IOSSystemContextMenuItemLiveText`, `IOSSystemContextMenuItemLookUp`, `IOSSystemContextMenuItemPaste`, `IOSSystemContextMenuItemSelectAll`, `IOSSystemContextMenuItemShare`, `IconDataProperty`, `IdleScrollActivity`, `IgnoreBaseline`, `ImageErrorWidgetBuilder`, `ImageFrameBuilder`, `ImageIcon`, `ImageLoadingBuilder`, `IndexedSemantics`, `IndexedSlot`, `IndexedWidgetBuilder`, `InheritedTheme`, `InitialRouteListFactory`, `InteractiveViewerWidgetBuilder`, `KeepAlive`, `KeepAliveHandle`, `KeepAliveNotification`, `KeySet`, `LeafRenderObjectElement`, `LeafRenderObjectWidget`, `ListWheelChildBuilderDelegate`, `ListWheelChildDelegate`, `ListWheelChildListDelegate`, `ListWheelChildLoopingListDelegate`, `ListWheelElement`, `ListWheelScrollView`, `ListWheelViewport`, `LiveTextInputStatus`, `LiveTextInputStatusNotifier`, `LocalHistoryEntry`, `LocalHistoryRoute`, `LocalizationsResolver`, `LookupBoundary`, `MagnifierBuilder`, `MagnifierController`, `MagnifierDecoration`, `MagnifierInfo`, `Matrix4Tween`, `MatrixTransition`, `MenuItemSerializableIdGenerator`, `MenuSerializableShortcut`, `MetaData`, `ModalBarrier`, `MultiSelectableSelectionContainerDelegate`, `NavigationMode`, `NavigationNotification`, `NavigationToolbar`, `NavigatorFinderCallback`, `NavigatorObserver`, `NavigatorPopHandler`, `NestedScrollViewState`, `NestedScrollViewViewport`, `NextFocusAction`, `NotifiableElementMixin`, `NullableIndexedWidgetBuilder`, `OnKeyEventCallback`, `OpenUpwardsPageTransitionsBuilder`, `OptionsViewOpenDirection`, `OrientationBuilder`, `OrientationWidgetBuilder`, `OverflowBarAlignment`, `OverlayChildLayoutBuilder`, `OverlayChildLayoutInfo`, `OverlayChildLocation`, `OverlayPortalController`, `OverscrollIndicatorNotification`, `Page`, `PageMetrics`, `PageTransitionsBuilder`, `PasteTextIntent`, `PhysicalShape`, `PinnedHeaderSliver`, `PlatformMenuDelegate`, `PlatformMenuItemGroup`, `PlatformProvidedMenuItem`, `PlatformProvidedMenuItemType`, `PlatformRouteInformationProvider`, `PlatformSelectableRegionContextMenu`, `PopEntry`, `PopInvokedCallback`, `PopInvokedWithResultCallback`, `PopNavigatorRouterDelegateMixin`, `PopPageCallback`, `PopResultCallback`, `PopupRoute`, `PositionedTransition`, `PredictiveBackRoute`, `PreferredSize`, `PreferredSizeWidget`, `PreviousFocusAction`, `PrimaryScrollController`, `PrioritizedAction`, `PrioritizedIntents`, `ProxyElement`, `ProxyWidget`, `RadioBuilder`, `RadioClient`, `RadioGroup`, `RadioGroupRegistry`, `RangeMaintainingScrollPhysics`, `RawAutocomplete`, `RawDialogRoute`, `RawDialogRouteBuilder`, `RawGestureDetector`, `RawGestureDetectorState`, `RawImage`, `RawKeyboardListener`, `RawMagnifier`, `RawMenuAnchor`, `RawMenuAnchorChildBuilder`, `RawMenuAnchorCloseRequestedCallback`, `RawMenuAnchorGroup`, `RawMenuAnchorOpenRequestedCallback`, `RawMenuAnchorOverlayBuilder`, `RawMenuOverlayInfo`, `RawRadio`, `RawScrollbar`, `RawScrollbarState`, `RawTooltip`, `RawTooltipState`, `RawView`, `RebuildDirtyWidgetCallback`, `RedoTextIntent`, `RegisterServiceExtensionCallback`, `RegisterViewFactory`, `RelativePositionedTransition`, `RelativeRectTween`, `RenderAbstractLayoutBuilderMixin`, `RenderConstrainedLayoutBuilder`, `RenderNestedScrollViewViewport`, `RenderObjectToWidgetAdapter`, `RenderObjectToWidgetElement`, `RenderSliverOverlapAbsorber`, `RenderSliverOverlapInjector`, `RenderTapRegion`, `RenderTapRegionSurface`, `RenderTreeRootElement`, `RenderTwoDimensionalViewport`, `ReorderCallback`, `ReorderDragBoundaryProvider`, `ReorderItemProxyDecorator`, `ReorderableDelayedDragStartListener`, `ReorderableDragStartListener`, `ReorderableList`, `ReorderableListState`, `RepeatMode`, `RepeatingAnimationBuilder`, `ReplaceTextIntent`, `RequestFocusAction`, `RequestFocusIntent`, `RestorableBool`, `RestorableBoolN`, `RestorableChangeNotifier`, `RestorableDateTime`, `RestorableDateTimeN`, `RestorableDouble`, `RestorableDoubleN`, `RestorableEnum`, `RestorableEnumN`, `RestorableInt`, `RestorableIntN`, `RestorableListenable`, `RestorableNum`, `RestorableNumN`, `RestorableProperty`, `RestorableRouteBuilder`, `RestorableRouteFuture`, `RestorableString`, `RestorableStringN`, `RestorableTextEditingController`, `RestorableValue`, `RestorationMixin`, `RestorationScope`, `RootBackButtonDispatcher`, `RootElement`, `RootElementMixin`, `RootRenderObjectElement`, `RootRestorationScope`, `RootWidget`, `RouteAware`, `RouteBarrierBuilder`, `RouteBarrierDetails`, `RouteCompletionCallback`, `RouteInformation`, `RouteInformationParser`, `RouteInformationProvider`, `RouteInformationReportingType`, `RouteListFactory`, `RouteObserver`, `RoutePageBuilder`, `RoutePredicate`, `RoutePresentationCallback`, `RouteTransitionRecord`, `RouteTransitionsBuilder`, `Router`, `RouterConfig`, `RouterDelegate`, `ScrollAction`, `ScrollActivity`, `ScrollActivityDelegate`, `ScrollAwareImageProvider`, `ScrollBehavior`, `ScrollConfiguration`, `ScrollContext`, `ScrollDragController`, `ScrollHoldController`, `ScrollIncrementCalculator`, `ScrollIncrementDetails`, `ScrollIncrementType`, `ScrollNotificationCallback`, `ScrollNotificationObserver`, `ScrollNotificationObserverState`, `ScrollPositionAlignmentPolicy`, `ScrollPositionWithSingleContext`, `ScrollToDocumentBoundaryIntent`, `ScrollView`, `ScrollViewKeyboardDismissBehavior`, `ScrollableDetails`, `ScrollableState`, `ScrollableWidgetBuilder`, `ScrollbarOrientation`, `ScrollbarPainter`, `SelectAction`, `SelectAllTextIntent`, `SelectIntent`, `SelectableDayPredicate`, `SelectableRegion`, `SelectableRegionContextMenuBuilder`, `SelectableRegionSelectionStatus`, `SelectableRegionSelectionStatusScope`, `SelectableRegionState`, `SelectionChangedCallback`, `SelectionContainer`, `SelectionContainerDelegate`, `SelectionDetails`, `SelectionListener`, `SelectionListenerNotifier`, `SelectionOverlay`, `SelectionRegistrarScope`, `SemanticIndexCallback`, `SemanticsDebugger`, `SemanticsGestureDelegate`, `SensitiveContent`, `SensitiveContentHost`, `SharedAppData`, `SharedAppDataInitCallback`, `ShortcutMapProperty`, `ShortcutRegistrar`, `ShortcutRegistry`, `ShortcutRegistryEntry`, `ShortcutSerialization`, `ShrinkWrappingViewport`, `SizeChangedLayoutNotification`, `SizeChangedLayoutNotifier`, `SliverAnimatedGrid`, `SliverAnimatedGridState`, `SliverAnimatedList`, `SliverAnimatedListState`, `SliverAnimatedOpacity`, `SliverConstrainedCrossAxis`, `SliverCrossAxisExpanded`, `SliverCrossAxisGroup`, `SliverEnsureSemantics`, `SliverFadeTransition`, `SliverFillViewport`, `SliverFloatingHeader`, `SliverIgnorePointer`, `SliverLayoutBuilder`, `SliverLayoutWidgetBuilder`, `SliverMainAxisGroup`, `SliverOffstage`, `SliverOpacity`, `SliverOverlapAbsorber`, `SliverOverlapAbsorberHandle`, `SliverOverlapInjector`, `SliverPrototypeExtentList`, `SliverReorderableList`, `SliverReorderableListState`, `SliverResizingHeader`, `SliverSafeArea`, `SliverSemantics`, `SliverVariedExtentList`, `SliverVisibility`, `SliverWithKeepAliveWidget`, `SlottedContainerRenderObjectMixin`, `SlottedMultiChildRenderObjectWidget`, `SlottedMultiChildRenderObjectWidgetMixin`, `SlottedRenderObjectElement`, `SnapshotController`, `SnapshotMode`, `SnapshotPainter`, `SnapshotWidget`, `SpellCheckConfiguration`, `StandardComponentType`, `StateSetter`, `StatefulWidgetBuilder`, `StaticSelectionContainerDelegate`, `StatusTransitionWidget`, `StreamBuilderBase`, `StretchEffect`, `StretchingOverscrollIndicator`, `SystemContextMenu`, `SystemTextScaler`, `TapBehaviorButtonBuilder`, `TapRegion`, `TapRegionCallback`, `TapRegionRegistry`, `TapRegionSurface`, `TapRegionUpCallback`, `TextFieldTapRegion`, `TextMagnifierConfiguration`, `TextSelectionControls`, `TextSelectionGestureDetector`, `TextSelectionGestureDetectorBuilder`, `TextSelectionGestureDetectorBuilderDelegate`, `TextSelectionHandleControls`, `TextSelectionOverlay`, `TextSelectionToolbarAnchors`, `TextSelectionToolbarLayoutDelegate`, `TextStyleTween`, `Texture`, `TickerMode`, `TickerModeData`, `Title`, `ToggleablePainter`, `ToggleableStateMixin`, `ToolbarBuilder`, `ToolbarItemsParentData`, `ToolbarOptions`, `TooltipComponentBuilder`, `TooltipPositionContext`, `TooltipPositionDelegate`, `TooltipTriggeredCallback`, `TrackingScrollController`, `TransformCallback`, `TransitionDelegate`, `TransposeCharactersIntent`, `TraversalEdgeBehavior`, `TraversalRequestFocusCallback`, `TreeSliver`, `TreeSliverController`, `TreeSliverNode`, `TreeSliverNodeBuilder`, `TreeSliverNodeCallback`, `TreeSliverRowExtentBuilder`, `TreeSliverStateMixin`, `TweenConstructor`, `TweenVisitor`, `TwoDimensionalChildBuilderDelegate`, `TwoDimensionalChildDelegate`, `TwoDimensionalChildListDelegate`, `TwoDimensionalChildManager`, `TwoDimensionalIndexedWidgetBuilder`, `TwoDimensionalScrollView`, `TwoDimensionalScrollable`, `TwoDimensionalScrollableState`, `TwoDimensionalViewport`, `TwoDimensionalViewportBuilder`, `TwoDimensionalViewportParentData`, `UndoHistory`, `UndoHistoryController`, `UndoHistoryState`, `UndoHistoryValue`, `UndoTextIntent`, `UnfocusDisposition`, `UniqueWidget`, `UnmanagedRestorationScope`, `UpdateSelectionIntent`, `ValueWidgetBuilder`, `View`, `ViewAnchor`, `ViewCollection`, `Viewport`, `ViewportBuilder`, `ViewportElementMixin`, `WeakMap`, `WidgetPropertyResolver`, `WidgetState`, `WidgetStateBorderSide`, `WidgetStateColor`, `WidgetStateMap`, `WidgetStateMapper`, `WidgetStateMouseCursor`, `WidgetStateOutlinedBorder`, `WidgetStateProperty`, `WidgetStatePropertyAll`, `WidgetStateTextStyle`, `WidgetStatesConstraint`, `WidgetStatesController`, `WidgetToRenderBoxAdapter`, `WidgetsLocalizations`, `WidgetsServiceExtensions`, `WillPopCallback`, `WillPopScope`, `basicLocaleListResolution`, `buildTextSpanWithSpellCheckSuggestions`, `combineKeyEventResults`, `createLocalImageConfiguration`, `emptyTextSelectionControls`, `getAxisDirectionFromAxisReverseAndDirectionality`, `intentForMacOSSelector`, `kDefaultContentInsertionMimeTypes`, `kDefaultRouteDirectionalTraversalEdgeBehavior`, `kDefaultRouteTraversalEdgeBehavior`, `precacheImage`, `runWidget`, `showRawDialog`, `staticIconProvider`, `widgetFactory`

🟡 `CharacterActivator`: the character is derived from the key as on a US layout

🟡 `PageStorage`: scroll views do not save their offset in it yet

🟡 `TransformationController`: holds a `Transform2D`

🟡 `WidgetsBindingObserver`: `didPopRoute`, `didPushRoute`, `didChangeLocales` and `didHaveMemoryPressure` never fire

✅ `ActionDispatcher`, `ActionListenerCallback`, `ActivateAction`, `ActivateIntent`, `AnimatedDefaultTextStyle`, `AnimatedList`, `AnimatedListState`, `AnimatedWidget`, `BouncingScrollSimulation`, `BuildOwner`, `ButtonActivateIntent`, `CallbackAction`, `ClampingScrollSimulation`, `ComponentElement`, `ConfirmDismissCallback`, `ContextAction`, `ContextMenuController`, `DirectionalFocusAction`, `DirectionalFocusIntent`, `DismissAction`, `DismissDirection`, `DismissDirectionCallback`, `DismissIntent`, `DismissUpdateCallback`, `DismissUpdateDetails`, `DoNothingAction`, `DoNothingAndStopPropagationIntent`, `DoNothingIntent`, `DragAnchorStrategy`, `DragEndCallback`, `DragTargetAccept`, `DragTargetAcceptWithDetails`, `DragTargetBuilder`, `DragTargetDetails`, `DragTargetLeave`, `DragTargetMove`, `DragTargetWillAccept`, `DragTargetWillAcceptWithDetails`, `DragUpdateCallback`, `DraggableCanceledCallback`, `DraggableDetails`, `Element`, `ErrorWidgetBuilder`, `ExcludeFocus`, `FixedScrollMetrics`, `FocusAttachment`, `FocusManager`, `FocusOnKeyEventCallback`, `FocusOrder`, `FocusTraversalOrder`, `FocusTraversalPolicy`, `FormFieldBuilder`, `FormFieldErrorBuilder`, `FormFieldSetter`, `FormFieldState`, `FormFieldValidator`, `FractionalTranslation`, `GenerateAppTitle`, `ImplicitlyAnimatedWidget`, `ImplicitlyAnimatedWidgetState`, `InheritedElement`, `InheritedModelElement`, `KeyEventResult`, `LabeledGlobalKey`, `LayoutChangedNotification`, `LayoutId`, `LayoutWidgetBuilder`, `LexicalFocusOrder`, `LocaleListResolutionCallback`, `LocaleResolutionCallback`, `LocalizationsDelegate`, `LockState`, `LogicalKeySet`, `MenuController`, `MergeSemantics`, `MultiChildRenderObjectElement`, `MultiChildRenderObjectWidget`, `NestedScrollViewHeaderSliversBuilder`, `NextFocusIntent`, `Notification`, `NotificationListenerCallback`, `NumericFocusOrder`, `OnInvokeCallback`, `OrderedTraversalPolicy`, `Orientation`, `OverlayRoute`, `OverlayState`, `OverscrollNotification`, `PageRouteFactory`, `PageScrollPhysics`, `PageStorageBucket`, `PanAxis`, `ParentDataElement`, `ParentDataWidget`, `PlatformMenu`, `PlatformMenuBar`, `PlatformMenuItem`, `PreviousFocusIntent`, `ReadingOrderTraversalPolicy`, `RenderObjectElement`, `RenderObjectWidget`, `RepaintBoundary`, `RouteFactory`, `RoutePopDisposition`, `RouteSettings`, `ScrollControllerCallback`, `ScrollDecelerationRate`, `ScrollEndNotification`, `ScrollIntent`, `ScrollMetrics`, `ScrollMetricsNotification`, `ScrollNotificationPredicate`, `ScrollStartNotification`, `ScrollUpdateNotification`, `Scrollable`, `Semantics`, `ShortcutActivator`, `ShortcutManager`, `SingleChildRenderObjectElement`, `SingleChildRenderObjectWidget`, `SizedOverflowBox`, `SliverChildBuilderDelegate`, `SliverChildDelegate`, `SliverChildListDelegate`, `SliverFixedExtentList`, `SliverMultiBoxAdaptorElement`, `SliverMultiBoxAdaptorWidget`, `SliverPersistentHeaderDelegate`, `StatefulElement`, `StatelessElement`, `TableCell`, `TooltipTriggerMode`, `TransitionBuilder`, `TransitionRoute`, `TraversalDirection`, `UserScrollNotification`, `ViewportNotificationMixin`, `VoidCallbackAction`, `VoidCallbackIntent`, `WidgetBuilder`, `WidgetOrderTraversalPolicy`, `childDragAnchorStrategy`, `defaultScrollNotificationPredicate`, `pointerDragAnchorStrategy`


## P2 por biblioteca

### `cupertino` (0%)

❌ `CupertinoActionSheet`, `CupertinoActionSheetAction`, `CupertinoActivityIndicator`, `CupertinoAdaptiveTextSelectionToolbar`, `CupertinoAlertDialog`, `CupertinoApp`, `CupertinoButton`, `CupertinoButtonSize`, `CupertinoCheckbox`, `CupertinoColors`, `CupertinoContextMenu`, `CupertinoContextMenuAction`, `CupertinoContextMenuBuilder`, `CupertinoDatePicker`, `CupertinoDatePickerMode`, `CupertinoDesktopTextSelectionControls`, `CupertinoDesktopTextSelectionToolbar`, `CupertinoDesktopTextSelectionToolbarButton`, `CupertinoDialogAction`, `CupertinoDialogRoute`, `CupertinoDynamicColor`, `CupertinoExpansionTile`, `CupertinoFocusHalo`, `CupertinoFormRow`, `CupertinoFormSection`, `CupertinoFullscreenDialogTransition`, `CupertinoIconThemeData`, `CupertinoIcons`, `CupertinoLinearActivityIndicator`, `CupertinoListSection`, `CupertinoListSectionType`, `CupertinoListTile`, `CupertinoListTileChevron`, `CupertinoLocalizations`, `CupertinoMagnifier`, `CupertinoMenuAnchor`, `CupertinoMenuAnimationStatusChangedCallback`, `CupertinoMenuDivider`, `CupertinoMenuEntry`, `CupertinoMenuItem`, `CupertinoModalPopupRoute`, `CupertinoNavigationBar`, `CupertinoNavigationBarBackButton`, `CupertinoPage`, `CupertinoPageRoute`, `CupertinoPageScaffold`, `CupertinoPageScaffoldBackgroundColor`, `CupertinoPageTransition`, `CupertinoPageTransitionsBuilder`, `CupertinoPicker`, `CupertinoPickerDefaultSelectionOverlay`, `CupertinoPopupSurface`, `CupertinoRadio`, `CupertinoRouteTransitionMixin`, `CupertinoScrollBehavior`, `CupertinoScrollbar`, `CupertinoSearchTextField`, `CupertinoSegmentedControl`, `CupertinoSheetRoute`, `CupertinoSheetTransition`, `CupertinoSlider`, `CupertinoSlidingSegmentedControl`, `CupertinoSliverNavigationBar`, `CupertinoSliverRefreshControl`, `CupertinoSpellCheckSuggestionsToolbar`, `CupertinoSwitch`, `CupertinoTabBar`, `CupertinoTabController`, `CupertinoTabScaffold`, `CupertinoTabView`, `CupertinoTextField`, `CupertinoTextFormFieldRow`, `CupertinoTextMagnifier`, `CupertinoTextSelectionControls`, `CupertinoTextSelectionHandleControls`, `CupertinoTextSelectionToolbar`, `CupertinoTextSelectionToolbarButton`, `CupertinoTextThemeData`, `CupertinoTheme`, `CupertinoThemeData`, `CupertinoThumbPainter`, `CupertinoTimerPicker`, `CupertinoTimerPickerMode`, `CupertinoToolbarBuilder`, `CupertinoUserInterfaceLevel`, `CupertinoUserInterfaceLevelData`, `DatePickerDateOrder`, `DatePickerDateTimeOrder`, `DefaultCupertinoLocalizations`, `ExpansionTileTransitionMode`, `InheritedCupertinoTheme`, `NavigationBarBottomMode`, `NoDefaultCupertinoThemeData`, `ObstructingPreferredSizeWidget`, `OverlayVisibilityMode`, `RefreshControlIndicatorBuilder`, `RefreshIndicatorMode`, `RestorableCupertinoTabController`, `SelectionOverlayBuilder`, `createCupertinoColorProperty`, `cupertinoDesktopTextSelectionControls`, `cupertinoDesktopTextSelectionHandleControls`, `cupertinoTextSelectionControls`, `cupertinoTextSelectionHandleControls`, `kCupertinoButtonDefaultIconSize`, `kCupertinoButtonMinSize`, `kCupertinoButtonPadding`, `kCupertinoButtonSizeBorderRadius`, `kCupertinoButtonTapMoveSlop`, `kCupertinoButtonTintedOpacityLight`, `kCupertinoFocusColorOpacity`, `kCupertinoModalBarrierColor`, `kMinInteractiveDimensionCupertino`, `showCupertinoDialog`, `showCupertinoModalPopup`, `showCupertinoSheet`

## Não se aplica

- Flutter DevTools: `DevToolsDeepLinkProperty`, `DisableWidgetInspectorScope`, `EnableWidgetInspectorScope`, `ExitWidgetSelectionButtonBuilder`, `InspectorButton`, `InspectorButtonVariant`, `InspectorReferenceData`, `InspectorSelection`, `InspectorSelectionChangedCallback`, `InspectorSerializationDelegate`, `MoveExitWidgetSelectionButtonBuilder`, `WidgetInspector`, `WidgetInspectorService`, `WidgetInspectorServiceExtensions`
- Flutter's debug banner: `CheckedModeBanner`
- Flutter's debug hooks: `debugAssertAllFoundationVarsUnset`, `debugAssertAllGesturesVarsUnset`, `debugAssertAllPaintingVarsUnset`, `debugAssertAllRenderVarsUnset`, `debugAssertAllSchedulerVarsUnset`, `debugAssertAllServicesVarsUnset`, `debugAssertAllWidgetVarsUnset`, `debugCheckCanResolveTextDirection`, `debugCheckHasBoundedAxis`, `debugCheckHasCupertinoLocalizations`, `debugCheckHasDirectionality`, `debugCheckHasMaterial`, `debugCheckHasMaterialLocalizations`, `debugCheckHasMediaQuery`, `debugCheckHasOverlay`, `debugCheckHasScaffold`, `debugCheckHasScaffoldMessenger`, `debugCheckHasTable`, `debugCheckHasWidgetsLocalizations`, `debugChildrenHaveDuplicateKeys`, `debugDefaultTargetPlatformOverride`, `debugDescribeFocusTree`, `debugDescribeTransform`, `debugDumpApp`, `debugDumpFocusTree`, `debugDumpLayerTree`, `debugDumpPipelineOwnerTree`, `debugDumpRenderObjectSemanticsTree`, `debugDumpRenderTree`, `debugDumpSemanticsTree`, `debugFlushLastFrameImageSizeInfo`, `debugFormatDouble`, `debugInstrumentAction`, `debugIsLocalCreationLocation`, `debugIsSerializableForRestoration`, `debugIsWidgetLocalCreation`, `debugItemsHaveDuplicateKeys`, `debugMaybeDispatchCreated`, `debugMaybeDispatchDisposed`, `debugPaintPadding`, `debugPrint`, `debugPrintStack`, `debugPrintSynchronously`, `debugPrintThrottled`, `debugResetSemanticsIdCounter`, `debugTransformDebugCreator`, `debugWidgetBuilderValue`, `debugWordWrap`
- Flutter's diagnostics tree: `DebugCreator`, `DebugOverflowIndicatorMixin`, `DebugPaintCallback`, `DebugPrintCallback`, `DebugSemanticsDumpOrder`, `DiagnosticLevel`, `DiagnosticPropertiesBuilder`, `DiagnosticPropertiesTransformer`, `Diagnosticable`, `DiagnosticableNode`, `DiagnosticableTree`, `DiagnosticableTreeMixin`, `DiagnosticableTreeNode`, `DiagnosticsBlock`, `DiagnosticsDebugCreator`, `DiagnosticsNode`, `DiagnosticsProperty`, `DiagnosticsSerializationDelegate`, `DiagnosticsStackTrace`, `DiagnosticsTreeStyle`, `ErrorDescription`, `ErrorHint`, `ErrorSpacer`, `ErrorSummary`, `FlutterError`, `FlutterErrorDetails`, `FlutterErrorDetailsForPointerEventDispatcher`
- Flutter's trademark: `FlutterLogo`
- a macOS platform view; the framework has no platform views: `AppKitView`
- an Android platform view; the framework has no platform views: `AndroidView`
- an iOS platform view; the framework has no platform views: `UiKitView`
- from the Dart SDK or a package, the same for both: `ByteData`, `Endian`, `Float32List`, `Float64List`, `HttpClientResponse`, `Int32List`, `Int64List`, `Uint8List`
- platform views: `AndroidViewSurface`, `PlatformViewLink`, `PlatformViewSurface`
- platform views and the web: `AndroidViewController`, `AppKitViewController`, `CreatePlatformViewCallback`, `DarwinPlatformViewController`, `ExpensiveAndroidViewController`, `HybridAndroidViewController`, `IOSSystemContextMenuItemDataSearchWeb`, `IOSSystemContextMenuItemSearchWeb`, `PlatformViewController`, `PlatformViewCreatedCallback`, `PlatformViewCreationParams`, `PlatformViewHitTestBehavior`, `PlatformViewLayer`, `PlatformViewRenderBox`, `PlatformViewSurfaceFactory`, `PlatformViewsRegistry`, `PlatformViewsService`, `RawKeyEventDataWeb`, `RenderAndroidView`, `RenderAppKitView`, `RenderDarwinPlatformView`, `RenderUiKitView`, `SurfaceAndroidViewController`, `TextureAndroidViewController`, `UiKitViewController`, `UiKitViewGestureBlockingPolicy`, `WebHtmlElementStrategy`, `kIsWeb`, `kWebLocationMap`, `kWebNumPadMap`, `kWebToLogicalKey`, `kWebToPhysicalKey`
- reads the Flutter engine's raster statistics: `PerformanceOverlay`
- the Flutter engine's window model: `FlutterView`, `FrameTiming`, `PlatformDispatcher`, `PointerData`, `SingletonFlutterWindow`, `TimingsCallback`
- web only: `HtmlElementView`
