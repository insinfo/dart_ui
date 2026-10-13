# Paridade de API com o Flutter

Gerado por `dart run tool/flutter_parity.dart`; não edite à mão. As regras estão em [AGENTS_FLUTTER.md](AGENTS_FLUTTER.md) e o histórico em [DIARIO_FLUTTER.md](DIARIO_FLUTTER.md).

Cada nome público do Flutter (`packages/flutter/lib`) é procurado na API pública do `dart_ui` (`lib/*.dart`). ✅ existe com o mesmo nome; 🟡 existe mas difere (a nota diz em quê) e conta metade; ❌ falta; — não se aplica, com o motivo. O nome existir não prova a mesma assinatura: divergências conhecidas ficam em `tool/flutter_parity/catalog.dart`, e na dúvida se marca para baixo.

## Por prioridade

| Prioridade | ✅ | 🟡 | ❌ | total | paridade |
|---|---|---|---|---|---|
| P0 | 167 | 11 | 143 | 321 | 53% |
| P1 | 252 | 0 | 1922 | 2174 | 11% |
| P2 | 0 | 0 | 116 | 116 | 0% |
| **todas** | 419 | 11 | 2181 | 2611 | 16% |

P0: o que um app ou pacote típico usa primeiro. P1: o resto do núcleo e do Material. P2: Cupertino. Fora da conta: 144 nomes que não se aplicam.

## Por biblioteca

| Biblioteca | ✅ | 🟡 | ❌ | total | paridade |
|---|---|---|---|---|---|
| `animation` | 16 | 0 | 43 | 59 | 27% |
| `cupertino` | 0 | 0 | 116 | 116 | 0% |
| `dart:io` | 0 | 0 | 0 | 0 | - |
| `dart:typed_data` | 0 | 0 | 0 | 0 | - |
| `dart:ui` | 22 | 0 | 45 | 67 | 32% |
| `foundation` | 7 | 0 | 107 | 114 | 6% |
| `gestures` | 43 | 0 | 144 | 187 | 22% |
| `material` | 39 | 1 | 474 | 514 | 7% |
| `painting` | 25 | 0 | 99 | 124 | 20% |
| `physics` | 4 | 0 | 6 | 10 | 40% |
| `rendering` | 81 | 0 | 208 | 289 | 28% |
| `scheduler` | 1 | 0 | 10 | 11 | 9% |
| `semantics` | 4 | 0 | 31 | 35 | 11% |
| `services` | 8 | 0 | 179 | 187 | 4% |
| `widgets` | 169 | 10 | 719 | 898 | 19% |

## P0, nome a nome

| | Nome | Biblioteca | Tipo | Nota |
|---|---|---|---|---|
| ✅ | `AbsorbPointer` | widgets | class |  |
| ✅ | `Action` | widgets | class |  |
| ✅ | `Align` | widgets | class |  |
| ✅ | `Alignment` | painting | class |  |
| ✅ | `AlignmentDirectional` | painting | class |  |
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
| ✅ | `Badge` | material | class |  |
| ✅ | `Baseline` | widgets | class |  |
| ✅ | `BorderSide` | painting | class |  |
| ✅ | `BoxDecoration` | painting | class |  |
| ✅ | `BoxFit` | painting | enum |  |
| ✅ | `BuildContext` | widgets | class |  |
| ✅ | `Builder` | widgets | class |  |
| ✅ | `CallbackShortcuts` | widgets | class |  |
| ✅ | `Card` | material | class |  |
| ✅ | `Center` | widgets | class |  |
| ✅ | `ChangeNotifier` | foundation | class |  |
| ✅ | `Chip` | material | class |  |
| ✅ | `CircularProgressIndicator` | material | class |  |
| ✅ | `ClipRRect` | widgets | class |  |
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
| ✅ | `CustomMultiChildLayout` | widgets | class |  |
| ✅ | `CustomPaint` | widgets | class |  |
| ✅ | `DecoratedBox` | widgets | class |  |
| ✅ | `DefaultTextStyle` | widgets | class |  |
| ✅ | `Dialog` | material | class |  |
| ✅ | `Directionality` | widgets | class |  |
| ✅ | `Divider` | material | class |  |
| ✅ | `EdgeInsets` | painting | class |  |
| ✅ | `EdgeInsetsDirectional` | painting | class |  |
| ✅ | `Expanded` | widgets | class |  |
| ✅ | `FadeTransition` | widgets | class |  |
| ✅ | `FittedBox` | widgets | class |  |
| ✅ | `Flex` | widgets | class |  |
| ✅ | `Flexible` | widgets | class |  |
| ✅ | `FocusNode` | widgets | class |  |
| ✅ | `FocusScope` | widgets | class |  |
| ✅ | `FocusScopeNode` | widgets | class |  |
| ✅ | `FontWeight` | dart:ui | class |  |
| ✅ | `FractionallySizedBox` | widgets | class |  |
| ✅ | `FutureBuilder` | widgets | class |  |
| ✅ | `GestureDetector` | widgets | class |  |
| ✅ | `GlobalKey` | widgets | class |  |
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
| ✅ | `InheritedWidget` | widgets | class |  |
| ✅ | `Intent` | widgets | class |  |
| ✅ | `IntrinsicHeight` | widgets | class |  |
| ✅ | `IntrinsicWidth` | widgets | class |  |
| ✅ | `Key` | foundation | class |  |
| ✅ | `LayoutBuilder` | widgets | class |  |
| ✅ | `LimitedBox` | widgets | class |  |
| ✅ | `LinearGradient` | painting | class |  |
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
| ✅ | `Offset` | dart:ui | class |  |
| ✅ | `Offstage` | widgets | class |  |
| ✅ | `Opacity` | widgets | class |  |
| ✅ | `OverflowBox` | widgets | class |  |
| ✅ | `Overlay` | widgets | class |  |
| ✅ | `OverlayEntry` | widgets | class |  |
| ✅ | `Padding` | widgets | class |  |
| ✅ | `PageRoute` | widgets | class |  |
| ✅ | `PageRouteBuilder` | widgets | class |  |
| ✅ | `Path` | dart:ui | class |  |
| ✅ | `Placeholder` | widgets | class |  |
| ✅ | `PopScope` | widgets | class |  |
| ✅ | `PopupMenuButton` | material | class |  |
| ✅ | `PopupMenuItem` | material | class |  |
| ✅ | `Positioned` | widgets | class |  |
| ✅ | `RadialGradient` | painting | class |  |
| ✅ | `Radio` | material | class |  |
| ✅ | `Rect` | dart:ui | class |  |
| ✅ | `RichText` | widgets | class |  |
| ✅ | `RotatedBox` | widgets | class |  |
| ✅ | `RotationTransition` | widgets | class |  |
| ✅ | `Route` | widgets | class |  |
| ✅ | `Row` | widgets | class |  |
| ✅ | `SafeArea` | widgets | class |  |
| ✅ | `ScaleTransition` | widgets | class |  |
| ✅ | `Scrollbar` | material | class |  |
| ✅ | `ShaderMask` | widgets | class |  |
| ✅ | `Shortcuts` | widgets | class |  |
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
| ✅ | `TextEditingController` | widgets | class |  |
| ✅ | `TextField` | material | class |  |
| ✅ | `TextOverflow` | painting | enum |  |
| ✅ | `TextSpan` | painting | class |  |
| ✅ | `TextStyle` | painting | class |  |
| ✅ | `TextTheme` | material | class |  |
| ✅ | `Theme` | material | class |  |
| ✅ | `ThemeData` | material | class |  |
| ✅ | `Tooltip` | material | class |  |
| ✅ | `Tween` | animation | class |  |
| ✅ | `UnconstrainedBox` | widgets | class |  |
| ✅ | `ValueKey` | foundation | class |  |
| ✅ | `ValueListenableBuilder` | widgets | class |  |
| ✅ | `ValueNotifier` | foundation | class |  |
| ✅ | `Visibility` | widgets | class |  |
| ✅ | `Widget` | widgets | class |  |
| ✅ | `WidgetSpan` | widgets | class |  |
| ✅ | `Wrap` | widgets | class |  |
| ✅ | `showDialog` | material | function |  |
| ✅ | `showMenu` | material | function |  |
| 🟡 | `CustomScrollView` | widgets | class | `axis:` instead of `scrollDirection:`; no `center`, no `shrinkWrap` |
| 🟡 | `Flow` | widgets | class | `paintChild` takes `Transform2D`, not `Matrix4`; no `clipBehavior` |
| 🟡 | `GridView` | widgets | class | `axis:` instead of `scrollDirection:`; `controller` is a `ScrollPosition` |
| 🟡 | `ListView` | widgets | class | `axis:` instead of `scrollDirection:`; `controller` is a `ScrollPosition` |
| 🟡 | `NestedScrollView` | widgets | class | no `SliverOverlapAbsorber`/`Injector` (not needed: the body is measured below the pinned headers) |
| 🟡 | `ScrollPosition` | widgets | class | plays the part of `ScrollController` too, and has neither `ScrollActivity` nor `ScrollContext` |
| 🟡 | `SingleChildScrollView` | widgets | class | `axis:` instead of `scrollDirection:` |
| 🟡 | `SliverAppBar` | material | class | no `snap`, `stretch` or `automaticallyImplyLeading`; `bottom` is a widget plus `bottomHeight` |
| 🟡 | `SliverList` | widgets | class | its delegate needs a `childCount`; rows are estimated by `estimatedItemExtent` |
| 🟡 | `Transform` | widgets | class | a 2D affine `Transform2D`, no perspective |
| 🟡 | `TweenAnimationBuilder` | widgets | class | resumes from the current value only for types it knows how to interpolate |
| ❌ | `Actions` | widgets | class |  |
| ❌ | `AlertDialog` | material | class |  |
| ❌ | `AlwaysScrollableScrollPhysics` | widgets | class |  |
| ❌ | `AnimatedCrossFade` | widgets | class |  |
| ❌ | `AnimatedRotation` | widgets | class |  |
| ❌ | `AnimatedScale` | widgets | class |  |
| ❌ | `AnimatedSlide` | widgets | class |  |
| ❌ | `AppBar` | material | class |  |
| ❌ | `AssetBundle` | services | class |  |
| ❌ | `AssetImage` | painting | class |  |
| ❌ | `AutomaticKeepAliveClientMixin` | widgets | mixin |  |
| ❌ | `AutovalidateMode` | widgets | enum |  |
| ❌ | `BackdropFilter` | widgets | class |  |
| ❌ | `BlendMode` | dart:ui | class |  |
| ❌ | `Border` | painting | class |  |
| ❌ | `BorderRadius` | painting | class |  |
| ❌ | `BottomNavigationBar` | material | class |  |
| ❌ | `BottomNavigationBarItem` | widgets | class |  |
| ❌ | `BouncingScrollPhysics` | widgets | class |  |
| ❌ | `BoxShadow` | painting | class |  |
| ❌ | `ButtonStyle` | material | class |  |
| ❌ | `Canvas` | dart:ui | class |  |
| ❌ | `Checkbox` | material | class |  |
| ❌ | `CheckboxListTile` | material | class |  |
| ❌ | `CircleAvatar` | material | class |  |
| ❌ | `ClampingScrollPhysics` | widgets | class |  |
| ❌ | `Clip` | dart:ui | class |  |
| ❌ | `ClipOval` | widgets | class |  |
| ❌ | `ClipPath` | widgets | class |  |
| ❌ | `ClipboardData` | services | class |  |
| ❌ | `ColorFiltered` | widgets | class |  |
| ❌ | `CustomClipper` | rendering | class |  |
| ❌ | `CustomPainter` | rendering | class |  |
| ❌ | `CustomSingleChildLayout` | widgets | class |  |
| ❌ | `DataTable` | material | class |  |
| ❌ | `DefaultTabController` | material | class |  |
| ❌ | `Dismissible` | widgets | class |  |
| ❌ | `DragTarget` | widgets | class |  |
| ❌ | `Draggable` | widgets | class |  |
| ❌ | `Drawer` | material | class |  |
| ❌ | `DropdownButton` | material | class |  |
| ❌ | `DropdownMenuItem` | material | class |  |
| ❌ | `EditableText` | widgets | class |  |
| ❌ | `ElevatedButton` | material | class |  |
| ❌ | `ErrorWidget` | widgets | class |  |
| ❌ | `ExpansionTile` | material | class |  |
| ❌ | `FileImage` | painting | class |  |
| ❌ | `FilledButton` | material | class |  |
| ❌ | `FilteringTextInputFormatter` | services | class |  |
| ❌ | `FloatingActionButton` | material | class |  |
| ❌ | `Focus` | widgets | class |  |
| ❌ | `FocusTraversalGroup` | widgets | class |  |
| ❌ | `Form` | widgets | class |  |
| ❌ | `FormField` | widgets | class |  |
| ❌ | `FormState` | widgets | class |  |
| ❌ | `GlobalObjectKey` | widgets | class |  |
| ❌ | `HapticFeedback` | services | class |  |
| ❌ | `ImageFiltered` | widgets | class |  |
| ❌ | `ImageProvider` | painting | class |  |
| ❌ | `InheritedModel` | widgets | class |  |
| ❌ | `InheritedNotifier` | widgets | class |  |
| ❌ | `InkResponse` | material | class |  |
| ❌ | `InkWell` | material | class |  |
| ❌ | `InputDecoration` | material | class |  |
| ❌ | `InteractiveViewer` | widgets | class |  |
| ❌ | `KeyboardListener` | widgets | class |  |
| ❌ | `KeyedSubtree` | widgets | class |  |
| ❌ | `LengthLimitingTextInputFormatter` | services | class |  |
| ❌ | `ListBody` | widgets | class |  |
| ❌ | `ListTile` | material | class |  |
| ❌ | `Listener` | widgets | class |  |
| ❌ | `LogicalKeyboardKey` | services | class |  |
| ❌ | `LongPressDraggable` | widgets | class |  |
| ❌ | `Material` | material | class |  |
| ❌ | `MaterialApp` | material | class |  |
| ❌ | `MaterialPageRoute` | material | class |  |
| ❌ | `Matrix4` | gestures | class |  |
| ❌ | `MemoryImage` | painting | class |  |
| ❌ | `ModalRoute` | widgets | class |  |
| ❌ | `NavigationBar` | material | class |  |
| ❌ | `NavigationRail` | material | class |  |
| ❌ | `NetworkImage` | painting | class |  |
| ❌ | `NeverScrollableScrollPhysics` | widgets | class |  |
| ❌ | `NotificationListener` | widgets | class |  |
| ❌ | `ObjectKey` | widgets | class |  |
| ❌ | `OutlineInputBorder` | material | class |  |
| ❌ | `OutlinedButton` | material | class |  |
| ❌ | `OverflowBar` | widgets | class |  |
| ❌ | `OverlayPortal` | widgets | class |  |
| ❌ | `PageController` | widgets | class |  |
| ❌ | `PageStorageKey` | widgets | class |  |
| ❌ | `PageView` | widgets | class |  |
| ❌ | `Paint` | dart:ui | class |  |
| ❌ | `PhysicalModel` | widgets | class |  |
| ❌ | `PositionedDirectional` | widgets | class |  |
| ❌ | `RRect` | dart:ui | class |  |
| ❌ | `RadioListTile` | material | class |  |
| ❌ | `Radius` | dart:ui | class |  |
| ❌ | `RangeSlider` | material | class |  |
| ❌ | `RefreshIndicator` | material | class |  |
| ❌ | `ReorderableListView` | material | class |  |
| ❌ | `Scaffold` | material | class |  |
| ❌ | `ScaffoldMessenger` | material | class |  |
| ❌ | `ScrollController` | widgets | class |  |
| ❌ | `ScrollNotification` | widgets | class |  |
| ❌ | `ScrollPhysics` | widgets | class |  |
| ❌ | `SearchBar` | material | class |  |
| ❌ | `SegmentedButton` | material | class |  |
| ❌ | `SelectableText` | material | class |  |
| ❌ | `SelectionArea` | material | class |  |
| ❌ | `ShapeDecoration` | painting | class |  |
| ❌ | `SimpleDialog` | material | class |  |
| ❌ | `SingleActivator` | widgets | class |  |
| ❌ | `SingleTickerProviderStateMixin` | widgets | mixin |  |
| ❌ | `SnackBar` | material | class |  |
| ❌ | `Stepper` | material | class |  |
| ❌ | `SweepGradient` | painting | class |  |
| ❌ | `SwitchListTile` | material | class |  |
| ❌ | `SystemChrome` | services | class |  |
| ❌ | `SystemNavigator` | services | class |  |
| ❌ | `Tab` | material | class |  |
| ❌ | `TabBar` | material | class |  |
| ❌ | `TabBarView` | material | class |  |
| ❌ | `TabController` | material | class |  |
| ❌ | `TextButton` | material | class |  |
| ❌ | `TextFormField` | material | class |  |
| ❌ | `TextInputAction` | services | enum |  |
| ❌ | `TextInputFormatter` | services | class |  |
| ❌ | `TextInputType` | services | class |  |
| ❌ | `Ticker` | scheduler | class |  |
| ❌ | `TickerProviderStateMixin` | widgets | mixin |  |
| ❌ | `UniqueKey` | foundation | class |  |
| ❌ | `ValueChanged` | foundation | typedef |  |
| ❌ | `VoidCallback` | dart:ui | class |  |
| ❌ | `WidgetsApp` | widgets | class |  |
| ❌ | `WidgetsBinding` | widgets | mixin |  |
| ❌ | `WidgetsFlutterBinding` | widgets | class |  |
| ❌ | `rootBundle` | services | variable |  |
| ❌ | `runApp` | widgets | function |  |
| ❌ | `showDatePicker` | material | function |  |
| ❌ | `showGeneralDialog` | widgets | function |  |
| ❌ | `showModalBottomSheet` | material | function |  |
| ❌ | `showTimePicker` | material | function |  |

## P1 por biblioteca

### `animation` (18%)

❌ `AlwaysStoppedAnimation`, `Animatable`, `AnimatableCallback`, `AnimationBehavior`, `AnimationEagerListenerMixin`, `AnimationLazyListenerMixin`, `AnimationLocalListenersMixin`, `AnimationLocalStatusListenersMixin`, `AnimationMax`, `AnimationMean`, `AnimationMin`, `AnimationStatusListener`, `AnimationStyle`, `AnimationWithParentMixin`, `CatmullRomCurve`, `CatmullRomSpline`, `CompoundAnimation`, `ConstantTween`, `Curve2D`, `Curve2DSample`, `CurveTween`, `ElasticInCurve`, `ElasticInOutCurve`, `ElasticOutCurve`, `FlippedTweenSequence`, `IntTween`, `ParametricCurve`, `ProxyAnimation`, `ReverseAnimation`, `ReverseTween`, `SawTooth`, `Split`, `StepTween`, `ThreePointCubic`, `TickerCanceled`, `TickerFuture`, `TickerProvider`, `TrainHoppingAnimation`, `TweenSequence`, `TweenSequenceItem`, `ValueListenableTransformer`, `kAlwaysCompleteAnimation`, `kAlwaysDismissedAnimation`

✅ `AnimationStatus`, `Cubic`, `Curve`, `FlippedCurve`, `Interval`, `RectTween`, `Simulation`, `SizeTween`, `SpringDescription`, `Threshold`

### `dart:ui` (28%)

❌ `AccessibilityFeatures`, `AppLifecycleState`, `BlurStyle`, `ChannelBuffers`, `ColorFilter`, `FilterQuality`, `FontFeature`, `FontVariation`, `GlyphInfo`, `ImageShader`, `ImmutableBuffer`, `KeyData`, `LineMetrics`, `LocaleStringAttribute`, `MaskFilter`, `PaintingStyle`, `PathFillType`, `PathOperation`, `PlatformMessageResponseCallback`, `PointerDeviceKind`, `RSTransform`, `RSuperellipse`, `RootIsolateToken`, `SemanticsActionEvent`, `SemanticsFlag`, `SemanticsFlags`, `SemanticsUpdateBuilder`, `SemanticsValidationResult`, `Shader`, `Shadow`, `SpellOutStringAttribute`, `StringAttribute`, `TextHeightBehavior`, `TextLeadingDistribution`, `TileMode`, `VertexMode`, `clampDouble`, `kTextHeightNone`

✅ `Brightness`, `FontStyle`, `Locale`, `PlaceholderAlignment`, `SemanticsAction`, `SemanticsRole`, `StrokeCap`, `StrokeJoin`, `TextAffinity`, `TextBaseline`, `TextBox`, `TextDecoration`, `TextDecorationStyle`, `TextDirection`, `TextPosition`

### `foundation` (1%)

❌ `AbstractNode`, `AggregatedTimedBlock`, `AggregatedTimings`, `AsyncCallback`, `AsyncValueGetter`, `AsyncValueSetter`, `BindingBase`, `BitField`, `BytesReceivedCallback`, `CachingIterable`, `Category`, `ComputeImpl`, `ComputePropertyValueCallback`, `DocumentationIcon`, `DoubleProperty`, `EnumProperty`, `ErrorToConsoleDumper`, `Factory`, `FlagProperty`, `FlagsSummary`, `FlutterExceptionHandler`, `FlutterMemoryAllocations`, `FlutterTimeline`, `FoundationServiceExtensions`, `HashedObserverList`, `InformationCollector`, `IntProperty`, `IterableFilter`, `IterableProperty`, `LicenseEntry`, `LicenseEntryCollector`, `LicenseEntryWithLineBreaks`, `LicenseParagraph`, `LicenseRegistry`, `LocalKey`, `MemoryAllocations`, `MessageProperty`, `ObjectCreated`, `ObjectDisposed`, `ObjectEvent`, `ObjectEventListener`, `ObjectFlagProperty`, `ObserverList`, `PartialStackFrame`, `PercentProperty`, `PersistentHashMap`, `ReadBuffer`, `RecordUse`, `RepetitiveStackFrameFilter`, `ServiceExtensionCallback`, `StackFilter`, `StackFrame`, `StackTraceDemangler`, `StringProperty`, `Summary`, `SynchronousFuture`, `TargetPlatform`, `TextTreeConfiguration`, `TextTreeRenderer`, `TimedBlock`, `Unicode`, `ValueGetter`, `ValueListenable`, `ValueSetter`, `WriteBuffer`, `awaitNotRequired`, `binarySearch`, `consolidateHttpClientResponseBytes`, `dashedTextConfiguration`, `denseTextConfiguration`, `describeEnum`, `describeIdentity`, `errorPropertyTextConfiguration`, `errorTextConfiguration`, `factory`, `flatTextConfiguration`, `immutable`, `internal`, `kDebugMode`, `kFlutterMemoryAllocationsEnabled`, `kIsWasm`, `kMaxUnsignedSMI`, `kNoDefaultValue`, `kProfileMode`, `kReleaseMode`, `lerpDuration`, `listEquals`, `mapEquals`, `mergeSort`, `mustBeConst`, `mustCallSuper`, `nonVirtual`, `objectRuntimeType`, `optionalTypeArgs`, `protected`, `required`, `setEquals`, `shallowTextConfiguration`, `shortHash`, `singleLineTextConfiguration`, `sparseTextConfiguration`, `transitionTextConfiguration`, `visibleForOverriding`, `visibleForTesting`, `whitespaceTextConfiguration`

✅ `ComputeCallback`, `compute`

### `gestures` (23%)

❌ `AllowedButtonsFilter`, `BaseTapAndDragGestureRecognizer`, `BaseTapGestureRecognizer`, `DelayedMultiDragGestureRecognizer`, `DeviceGestureSettings`, `DevicePixelRatioGetter`, `Drag`, `DragDownDetails`, `DragStartBehavior`, `EagerGestureRecognizer`, `ForcePressDetails`, `ForcePressGestureRecognizer`, `GestureArenaTeam`, `GestureCancelCallback`, `GestureDoubleTapCallback`, `GestureDragCancelCallback`, `GestureDragDownCallback`, `GestureDragEndCallback`, `GestureDragStartCallback`, `GestureDragUpdateCallback`, `GestureForceInterpolation`, `GestureForcePressEndCallback`, `GestureForcePressPeakCallback`, `GestureForcePressStartCallback`, `GestureForcePressUpdateCallback`, `GestureLongPressCallback`, `GestureLongPressCancelCallback`, `GestureLongPressDownCallback`, `GestureLongPressEndCallback`, `GestureLongPressMoveUpdateCallback`, `GestureLongPressStartCallback`, `GestureLongPressUpCallback`, `GestureMultiDragStartCallback`, `GestureMultiTapCallback`, `GestureMultiTapCancelCallback`, `GestureMultiTapDownCallback`, `GestureMultiTapUpCallback`, `GestureRecognizerState`, `GestureScaleEndCallback`, `GestureScaleStartCallback`, `GestureScaleUpdateCallback`, `GestureSerialTapCancelCallback`, `GestureSerialTapDownCallback`, `GestureSerialTapUpCallback`, `GestureTapCallback`, `GestureTapCancelCallback`, `GestureTapDownCallback`, `GestureTapDragDownCallback`, `GestureTapDragEndCallback`, `GestureTapDragStartCallback`, `GestureTapDragUpCallback`, `GestureTapDragUpdateCallback`, `GestureTapMoveCallback`, `GestureTapUpCallback`, `GestureVelocityTrackerBuilder`, `HandleEventCallback`, `HitTestDispatcher`, `HitTestEntry`, `HitTestResult`, `HitTestTarget`, `HitTestable`, `HorizontalMultiDragGestureRecognizer`, `IOSScrollViewFlingVelocityTracker`, `ImmediateMultiDragGestureRecognizer`, `LeastSquaresSolver`, `LongPressDownDetails`, `MacOSScrollViewFlingVelocityTracker`, `MultiDragGestureRecognizer`, `MultiDragPointerState`, `MultiTapGestureRecognizer`, `MultitouchDragStrategy`, `NativeHitTestTarget`, `OffsetPair`, `OneSequenceGestureRecognizer`, `PointerAddedEvent`, `PointerEnterEvent`, `PointerEventConverter`, `PointerEventResampler`, `PointerExitEvent`, `PointerHoverEvent`, `PointerPanZoomEndEvent`, `PointerPanZoomStartEvent`, `PointerPanZoomUpdateEvent`, `PointerRemovedEvent`, `PointerRoute`, `PointerScaleEvent`, `PointerScrollInertiaCancelEvent`, `PointerSignalEvent`, `PositionedGestureDetails`, `RecognizerCallback`, `RespondPointerEventCallback`, `SamplingClock`, `SerialTapCancelDetails`, `SerialTapDownDetails`, `SerialTapGestureRecognizer`, `SerialTapUpDetails`, `TapAndDragGestureRecognizer`, `TapAndHorizontalDragGestureRecognizer`, `TapAndPanGestureRecognizer`, `TapDownDetails`, `TapDragDownDetails`, `TapDragEndDetails`, `TapDragStartDetails`, `TapDragUpDetails`, `TapDragUpdateDetails`, `TapMoveDetails`, `TapUpDetails`, `VerticalMultiDragGestureRecognizer`, `computeHitSlop`, `computePanSlop`, `computeScaleSlop`, `isSingleButton`, `kBackMouseButton`, `kDefaultMouseScrollToScaleFactor`, `kDefaultTrackpadScrollToScaleFactor`, `kDoubleTapSlop`, `kDoubleTapTouchSlop`, `kForwardMouseButton`, `kHoverTapSlop`, `kHoverTapTimeout`, `kJumpTapTimeout`, `kMiddleMouseButton`, `kPagingTouchSlop`, `kPanSlop`, `kPrecisePointerHitSlop`, `kPrecisePointerPanSlop`, `kPrecisePointerScaleSlop`, `kPressTimeout`, `kPrimaryButton`, `kPrimaryMouseButton`, `kPrimaryStylusButton`, `kScaleSlop`, `kSecondaryButton`, `kSecondaryMouseButton`, `kSecondaryStylusButton`, `kStylusContact`, `kTertiaryButton`, `kTouchContact`, `kWindowTouchSlop`, `kZoomControlsTimeout`, `nthMouseButton`, `nthStylusButton`, `smallestButton`

✅ `DoubleTapGestureRecognizer`, `DragEndDetails`, `DragGestureRecognizer`, `DragStartDetails`, `DragUpdateDetails`, `GestureArenaEntry`, `GestureArenaManager`, `GestureArenaMember`, `GestureBinding`, `GestureDisposition`, `GestureRecognizer`, `HorizontalDragGestureRecognizer`, `LongPressEndDetails`, `LongPressGestureRecognizer`, `LongPressMoveUpdateDetails`, `LongPressStartDetails`, `PanGestureRecognizer`, `PointerCancelEvent`, `PointerDownEvent`, `PointerEvent`, `PointerMoveEvent`, `PointerRouter`, `PointerScrollEvent`, `PointerSignalResolvedCallback`, `PointerSignalResolver`, `PointerUpEvent`, `PolynomialFit`, `PrimaryPointerGestureRecognizer`, `ScaleEndDetails`, `ScaleGestureRecognizer`, `ScaleStartDetails`, `ScaleUpdateDetails`, `TapGestureRecognizer`, `Velocity`, `VelocityEstimate`, `VelocityTracker`, `VerticalDragGestureRecognizer`, `kDoubleTapMinTime`, `kDoubleTapTimeout`, `kLongPressTimeout`, `kMaxFlingVelocity`, `kMinFlingVelocity`, `kTouchSlop`

### `material` (2%)

❌ `AboutDialog`, `AboutListTile`, `ActionChip`, `ActionIconTheme`, `ActionIconThemeData`, `Adaptation`, `AdaptiveTextSelectionToolbar`, `AnimatedTheme`, `AppBarTheme`, `AppBarThemeData`, `Autocomplete`, `BackButton`, `BackButtonIcon`, `BadgeTheme`, `BadgeThemeData`, `BaseRangeSliderTrackShape`, `BaseSliderTrackShape`, `BottomAppBar`, `BottomAppBarTheme`, `BottomAppBarThemeData`, `BottomNavigationBarLandscapeLayout`, `BottomNavigationBarTheme`, `BottomNavigationBarThemeData`, `BottomNavigationBarType`, `BottomSheet`, `BottomSheetDragEndHandler`, `BottomSheetDragStartHandler`, `BottomSheetThemeData`, `ButtonBar`, `ButtonBarLayoutBehavior`, `ButtonBarTheme`, `ButtonBarThemeData`, `ButtonLayerBuilder`, `ButtonSegment`, `ButtonStyleButton`, `ButtonTextTheme`, `ButtonTheme`, `ButtonThemeData`, `CalendarDatePicker`, `CalendarDelegate`, `CardTheme`, `CardThemeData`, `CarouselController`, `CarouselScrollPhysics`, `CarouselView`, `CarouselViewTheme`, `CarouselViewThemeData`, `CheckboxMenuButton`, `CheckboxTheme`, `CheckboxThemeData`, `CheckedPopupMenuItem`, `CheckmarkableChipAttributes`, `ChipAnimationStyle`, `ChipAttributes`, `ChipTheme`, `ChipThemeData`, `ChoiceChip`, `CloseButton`, `CloseButtonIcon`, `ControlsDetails`, `ControlsWidgetBuilder`, `CupertinoBasedMaterialThemeData`, `DataCell`, `DataColumn`, `DataColumnSortCallback`, `DataRow`, `DataTableSource`, `DataTableTheme`, `DataTableThemeData`, `DatePickerDialog`, `DatePickerEntryMode`, `DatePickerMode`, `DatePickerTheme`, `DatePickerThemeData`, `DateRangePickerDialog`, `DateTimeRange`, `DateUtils`, `DayPeriod`, `DefaultMaterialLocalizations`, `DeletableChipAttributes`, `DesktopTextSelectionControls`, `DesktopTextSelectionToolbar`, `DesktopTextSelectionToolbarButton`, `DialogRoute`, `DialogTheme`, `DialogThemeData`, `DisabledChipAttributes`, `DividerTheme`, `DividerThemeData`, `DrawerAlignment`, `DrawerButton`, `DrawerButtonIcon`, `DrawerCallback`, `DrawerController`, `DrawerControllerState`, `DrawerHeader`, `DrawerTheme`, `DrawerThemeData`, `DropRangeSliderValueIndicatorShape`, `DropSliderValueIndicatorShape`, `DropdownButtonBuilder`, `DropdownButtonFormField`, `DropdownButtonHideUnderline`, `DropdownMenu`, `DropdownMenuCloseBehavior`, `DropdownMenuDecorationBuilder`, `DropdownMenuEntry`, `DropdownMenuFormField`, `DropdownMenuTheme`, `DropdownMenuThemeData`, `Durations`, `DynamicSchemeVariant`, `Easing`, `ElevatedButtonTheme`, `ElevatedButtonThemeData`, `ElevationOverlay`, `EndDrawerButton`, `EndDrawerButtonIcon`, `EntryModeChangeCallback`, `ExpandIcon`, `ExpansionPanel`, `ExpansionPanelCallback`, `ExpansionPanelHeaderBuilder`, `ExpansionPanelList`, `ExpansionPanelRadio`, `ExpansionTileController`, `ExpansionTileTheme`, `ExpansionTileThemeData`, `FabCenterOffsetX`, `FabContainedOffsetY`, `FabDockedOffsetY`, `FabEndOffsetX`, `FabFloatOffsetY`, `FabMiniOffsetAdjustment`, `FabStartOffsetX`, `FabTopOffsetY`, `FadeForwardsPageTransitionsBuilder`, `FilledButtonTheme`, `FilledButtonThemeData`, `FilterCallback`, `FilterChip`, `FloatingActionButtonAnimator`, `FloatingActionButtonLocation`, `FloatingActionButtonTheme`, `FloatingActionButtonThemeData`, `FloatingLabelAlignment`, `FloatingLabelBehavior`, `GappedRangeSliderTrackShape`, `GappedSliderTrackShape`, `GregorianCalendarDelegate`, `GridTile`, `GridTileBar`, `HandleRangeSliderThumbShape`, `HandleThumbShape`, `HourFormat`, `IconAlignment`, `IconButtonTheme`, `IconButtonThemeData`, `Ink`, `InkDecoration`, `InkFeature`, `InkHighlight`, `InkRipple`, `InkSparkle`, `InkSplash`, `InputBorder`, `InputChip`, `InputCounterWidgetBuilder`, `InputDatePickerFormField`, `InputDecorationTheme`, `InputDecorationThemeData`, `InputDecorator`, `InteractiveInkFeature`, `InteractiveInkFeatureFactory`, `LicensePage`, `ListTileControlAffinity`, `ListTileStyle`, `ListTileTheme`, `ListTileThemeData`, `ListTileTitleAlignment`, `Magnifier`, `MaterialAccentColor`, `MaterialBanner`, `MaterialBannerClosedReason`, `MaterialBannerTheme`, `MaterialBannerThemeData`, `MaterialBasedCupertinoThemeData`, `MaterialButton`, `MaterialColor`, `MaterialGap`, `MaterialInkController`, `MaterialLocalizations`, `MaterialPage`, `MaterialPointArcTween`, `MaterialPropertyResolver`, `MaterialRectArcTween`, `MaterialRectCenterArcTween`, `MaterialRouteTransitionMixin`, `MaterialScrollBehavior`, `MaterialSlice`, `MaterialState`, `MaterialStateBorderSide`, `MaterialStateColor`, `MaterialStateMixin`, `MaterialStateMouseCursor`, `MaterialStateOutlineInputBorder`, `MaterialStateOutlinedBorder`, `MaterialStateProperty`, `MaterialStatePropertyAll`, `MaterialStateTextStyle`, `MaterialStateUnderlineInputBorder`, `MaterialStatesController`, `MaterialTapTargetSize`, `MaterialTextSelectionControls`, `MaterialTextSelectionHandleControls`, `MaterialType`, `MenuAcceleratorCallbackBinding`, `MenuAcceleratorChildBuilder`, `MenuAnchorChildBuilder`, `MenuBarTheme`, `MenuBarThemeData`, `MenuButtonTheme`, `MenuButtonThemeData`, `MenuStyle`, `MenuTheme`, `MenuThemeData`, `MergeableMaterial`, `MergeableMaterialItem`, `ModalBottomSheetRoute`, `NavigationBarTheme`, `NavigationBarThemeData`, `NavigationDestination`, `NavigationDestinationLabelBehavior`, `NavigationDrawer`, `NavigationDrawerDestination`, `NavigationDrawerTheme`, `NavigationDrawerThemeData`, `NavigationIndicator`, `NavigationRailDestination`, `NavigationRailLabelType`, `NavigationRailTheme`, `NavigationRailThemeData`, `NoSplash`, `OutlinedButtonTheme`, `OutlinedButtonThemeData`, `PaddleRangeSliderValueIndicatorShape`, `PaddleSliderValueIndicatorShape`, `PageTransitionsTheme`, `PaginatedDataTable`, `PaginatedDataTableState`, `PaintRangeValueIndicator`, `PaintValueIndicator`, `PersistentBottomSheetController`, `PlatformAdaptiveIcons`, `PopupMenuButtonState`, `PopupMenuCanceled`, `PopupMenuItemBuilder`, `PopupMenuItemSelected`, `PopupMenuItemState`, `PopupMenuPosition`, `PopupMenuPositionBuilder`, `PopupMenuTheme`, `PopupMenuThemeData`, `PredictiveBackFullscreenPageTransitionsBuilder`, `PredictiveBackPageTransitionsBuilder`, `ProgressIndicator`, `ProgressIndicatorTheme`, `RadioMenuButton`, `RadioTheme`, `RadioThemeData`, `RangeLabels`, `RangeSliderThumbShape`, `RangeSliderTickMarkShape`, `RangeSliderTrackShape`, `RangeSliderValueIndicatorShape`, `RangeThumbSelector`, `RangeValues`, `RawChip`, `RawMaterialButton`, `RectCallback`, `RectangularRangeSliderTrackShape`, `RectangularRangeSliderValueIndicatorShape`, `RectangularSliderTrackShape`, `RectangularSliderValueIndicatorShape`, `RefreshCallback`, `RefreshIndicatorState`, `RefreshIndicatorStatus`, `RefreshIndicatorTriggerMode`, `RefreshProgressIndicator`, `RestorableTimeOfDay`, `RoundRangeSliderThumbShape`, `RoundRangeSliderTickMarkShape`, `RoundSliderOverlayShape`, `RoundSliderThumbShape`, `RoundSliderTickMarkShape`, `RoundedRectRangeSliderTrackShape`, `RoundedRectRangeSliderValueIndicatorShape`, `RoundedRectSliderTrackShape`, `RoundedRectSliderValueIndicatorShape`, `ScaffoldFeatureController`, `ScaffoldGeometry`, `ScaffoldMessengerState`, `ScaffoldPrelayoutGeometry`, `ScaffoldState`, `ScriptCategory`, `ScrollbarTheme`, `SearchAnchor`, `SearchAnchorChildBuilder`, `SearchBarTheme`, `SearchBarThemeData`, `SearchCallback`, `SearchController`, `SearchDelegate`, `SearchViewTheme`, `SearchViewThemeData`, `SegmentedButtonState`, `SegmentedButtonTheme`, `SegmentedButtonThemeData`, `SelectableChipAttributes`, `SelectableDayForRangePredicate`, `SelectionAreaState`, `SemanticFormatterCallback`, `ShapeBorderTween`, `ShapedInputBorder`, `ShowValueIndicator`, `SimpleDialogOption`, `SliderComponentShape`, `SliderInteraction`, `SliderTheme`, `SliderThemeData`, `SliderTickMarkShape`, `SliderTrackShape`, `SnackBarAction`, `SnackBarBehavior`, `SnackBarClosedReason`, `SnackBarTheme`, `SnackBarThemeData`, `SpellCheckSuggestionsToolbar`, `SpellCheckSuggestionsToolbarLayoutDelegate`, `StandardFabLocation`, `Step`, `StepIconBuilder`, `StepState`, `StepStyle`, `StepperType`, `StretchMode`, `SuggestionsBuilder`, `SwitchTheme`, `SwitchThemeData`, `TabAlignment`, `TabBarIndicatorSize`, `TabBarScrollController`, `TabBarTheme`, `TabBarThemeData`, `TabIndicatorAnimation`, `TabPageSelector`, `TabPageSelectorIndicator`, `TabValueChanged`, `TableRowInkWell`, `TappableChipAttributes`, `TextButtonTheme`, `TextButtonThemeData`, `TextMagnifier`, `TextSelectionTheme`, `TextSelectionThemeData`, `TextSelectionToolbar`, `TextSelectionToolbarTextButton`, `ThemeDataTween`, `ThemeExtension`, `ThemeMode`, `Thumb`, `TimeOfDayFormat`, `TimePickerDialog`, `TimePickerEntryMode`, `TimePickerTheme`, `TimePickerThemeData`, `ToggleButtons`, `ToggleButtonsTheme`, `ToggleButtonsThemeData`, `TooltipState`, `TooltipTheme`, `TooltipThemeData`, `TooltipVisibility`, `Typography`, `UnderlineInputBorder`, `UnderlineTabIndicator`, `UserAccountsDrawerHeader`, `ViewBuilder`, `VisualDensity`, `WidgetStateInputBorder`, `YearPicker`, `ZoomPageTransitionsBuilder`, `accelerateEasing`, `decelerateEasing`, `desktopTextSelectionControls`, `desktopTextSelectionHandleControls`, `hourFormat`, `kBottomNavigationBarHeight`, `kElevationToShadow`, `kFloatingActionButtonMargin`, `kFloatingActionButtonSegue`, `kFloatingActionButtonTurnInterval`, `kMaterialEdges`, `kMaterialListPadding`, `kMiniButtonOffsetAdjustment`, `kRadialReactionAlpha`, `kRadialReactionDuration`, `kRadialReactionRadius`, `kTabLabelPadding`, `kTabScrollDuration`, `kTextTabBarHeight`, `kThemeAnimationDuration`, `kThemeChangeDuration`, `kToolbarHeight`, `materialTextSelectionControls`, `materialTextSelectionHandleControls`, `showAboutDialog`, `showAdaptiveAboutDialog`, `showAdaptiveDialog`, `showBottomSheet`, `showDateRangePicker`, `showLicensePage`, `showSearch`, `standardEasing`

✅ `CollapseMode`, `FlexibleSpaceBar`, `FlexibleSpaceBarSettings`, `MenuAcceleratorLabel`, `PopupMenuDivider`, `PopupMenuEntry`, `ProgressIndicatorThemeData`, `ScrollbarThemeData`, `TimeOfDay`, `VerticalDivider`, `kMinInteractiveDimension`

### `painting` (12%)

❌ `Accumulator`, `AssetBundleImageKey`, `AssetBundleImageProvider`, `AutomaticNotchedShape`, `AxisDirection`, `BeveledRectangleBorder`, `BorderDirectional`, `BorderRadiusDirectional`, `BorderRadiusGeometry`, `BorderStyle`, `BoxShape`, `CircleBorder`, `CircularNotchedRectangle`, `ClipContext`, `ColorProperty`, `ColorSwatch`, `ContinuousRectangleBorder`, `DecoderBufferCallback`, `Decoration`, `DecorationImage`, `DecorationImagePainter`, `ExactAssetImage`, `FlutterLogoDecoration`, `FlutterLogoStyle`, `FractionalOffset`, `GradientRotation`, `GradientTransform`, `HSLColor`, `HSVColor`, `HttpClientProvider`, `ImageCache`, `ImageCacheStatus`, `ImageChunkEvent`, `ImageChunkListener`, `ImageConfiguration`, `ImageDecoderCallback`, `ImageErrorListener`, `ImageInfo`, `ImageListener`, `ImageRepeat`, `ImageSizeInfo`, `ImageStream`, `ImageStreamCompleter`, `ImageStreamCompleterHandle`, `ImageStreamListener`, `InlineSpanSemanticsInformation`, `InlineSpanVisitor`, `LinearBorder`, `LinearBorderEdge`, `MatrixUtils`, `MultiFrameImageStreamCompleter`, `NetworkImageLoadException`, `NotchedShape`, `OneFrameImageStreamCompleter`, `OutlinedBorder`, `OvalBorder`, `PaintImageCallback`, `PaintingBinding`, `RenderComparison`, `ResizeImage`, `ResizeImageKey`, `ResizeImagePolicy`, `RoundedRectangleBorder`, `RoundedSuperellipseBorder`, `ShaderWarmUp`, `ShaderWarmUpImageCallback`, `ShaderWarmUpPictureCallback`, `ShapeBorder`, `StadiumBorder`, `StarBorder`, `StrutStyle`, `TextAlignVertical`, `TextScaler`, `TextWidthBasis`, `TransformProperty`, `VerticalDirection`, `WordBoundary`, `axisDirectionIsReversed`, `axisDirectionToAxis`, `combineSemanticsInfo`, `flipAxis`, `flipAxisDirection`, `kDefaultFontSize`, `lerpFontVariations`, `paintBorder`, `paintImage`, `paintZigZag`, `positionDependentBox`, `textDirectionToAxisDirection`

✅ `AlignmentGeometry`, `Axis`, `BoxBorder`, `BoxPainter`, `EdgeInsetsGeometry`, `FittedSizes`, `Gradient`, `InlineSpan`, `PlaceholderDimensions`, `PlaceholderSpan`, `TextPainter`, `TextRange`, `applyBoxFit`

### `physics` (40%)

❌ `BoundedFrictionSimulation`, `ClampedSimulation`, `GravitySimulation`, `ScrollSpringSimulation`, `nearEqual`, `nearZero`

✅ `FrictionSimulation`, `SpringSimulation`, `SpringType`, `Tolerance`

### `rendering` (28%)

❌ `AlignmentGeometryTween`, `AlignmentTween`, `AnnotatedRegionLayer`, `AnnotationEntry`, `AnnotationResult`, `BackdropFilterLayer`, `BackdropKey`, `BoxConstraintsTransform`, `BoxHitTest`, `BoxHitTestEntry`, `BoxHitTestResult`, `BoxHitTestWithOutOfBandPosition`, `CacheExtentStyle`, `ChildBaselineGetter`, `ChildLayoutHelper`, `ChildLayouter`, `ClearSelectionEvent`, `ClipPathLayer`, `ClipRRectLayer`, `ClipRSuperellipseLayer`, `ClipRectLayer`, `ColorFilterLayer`, `CompositionCallback`, `Constraints`, `ContainerBoxParentData`, `ContainerLayer`, `ContainerParentDataMixin`, `ContainerRenderObjectMixin`, `CustomPainterSemantics`, `DecorationPosition`, `DirectionallyExtendSelectionEvent`, `FloatingHeaderSnapConfiguration`, `FollowerLayer`, `FractionalOffsetTween`, `GranularlyExtendSelectionEvent`, `GrowthDirection`, `HitTestBehavior`, `ImageFilterConfig`, `ImageFilterContext`, `ImageFilterLayer`, `ItemExtentBuilder`, `KeepAliveParentDataMixin`, `Layer`, `LayerHandle`, `LayerLink`, `LayoutCallback`, `LeaderLayer`, `ListBodyParentData`, `ListWheelChildManager`, `ListWheelParentData`, `MouseTracker`, `MouseTrackerHitTest`, `OffsetLayer`, `OpacityLayer`, `OverScrollHeaderStretchConfiguration`, `OverflowBoxFit`, `PaintingContext`, `PaintingContextCallback`, `ParentData`, `PerformanceOverlayLayer`, `PerformanceOverlayOption`, `PersistentHeaderShowOnScreenConfiguration`, `PictureLayer`, `PipelineManifold`, `PipelineOwnerVisitor`, `PlaceholderSpanIndexSemanticsTag`, `PointerCancelEventListener`, `PointerDownEventListener`, `PointerMoveEventListener`, `PointerPanZoomEndEventListener`, `PointerPanZoomStartEventListener`, `PointerPanZoomUpdateEventListener`, `PointerSignalEventListener`, `PointerUpEventListener`, `ProfilePaintCallback`, `RelayoutWhenSystemFontsChangeMixin`, `RenderAbstractViewport`, `RenderAligningShiftedBox`, `RenderAnimatedOpacity`, `RenderAnimatedOpacityMixin`, `RenderAnimatedSizeState`, `RenderAnnotatedRegion`, `RenderBackdropFilter`, `RenderBlockSemantics`, `RenderBoxContainerDefaultsMixin`, `RenderClipOval`, `RenderClipPath`, `RenderClipRSuperellipse`, `RenderConstrainedOverflowBox`, `RenderConstraintsTransformBox`, `RenderCustomSingleChildLayoutBox`, `RenderDecoratedSliver`, `RenderEditable`, `RenderEditablePainter`, `RenderErrorBox`, `RenderExcludeSemantics`, `RenderFollowerLayer`, `RenderFractionallySizedOverflowBox`, `RenderIgnoreBaseline`, `RenderIndexedSemantics`, `RenderIndexedStack`, `RenderInlineChildrenContainerDefaults`, `RenderLeaderLayer`, `RenderListBody`, `RenderListWheelViewport`, `RenderMergeSemantics`, `RenderMetaData`, `RenderObjectVisitor`, `RenderObjectWithChildMixin`, `RenderObjectWithLayoutCallbackMixin`, `RenderOffstage`, `RenderParagraph`, `RenderPerformanceOverlay`, `RenderPhysicalModel`, `RenderPhysicalShape`, `RenderPositionedBox`, `RenderProxyBoxMixin`, `RenderProxyBoxWithHitTestBehavior`, `RenderProxySliver`, `RenderSemanticsGestureHandler`, `RenderShiftedBox`, `RenderShrinkWrappingViewport`, `RenderSliverAnimatedOpacity`, `RenderSliverBoxChildManager`, `RenderSliverConstrainedCrossAxis`, `RenderSliverCrossAxisGroup`, `RenderSliverEdgeInsetsPadding`, `RenderSliverFillRemainingAndOverscroll`, `RenderSliverFillRemainingWithScrollable`, `RenderSliverFillViewport`, `RenderSliverFixedExtentBoxAdaptor`, `RenderSliverFixedExtentList`, `RenderSliverFloatingPersistentHeader`, `RenderSliverFloatingPinnedPersistentHeader`, `RenderSliverHelpers`, `RenderSliverIgnorePointer`, `RenderSliverMainAxisGroup`, `RenderSliverOffstage`, `RenderSliverOpacity`, `RenderSliverPinnedPersistentHeader`, `RenderSliverScrollingPersistentHeader`, `RenderSliverSemanticsAnnotations`, `RenderSliverSingleBoxAdapter`, `RenderSliverVariedExtentList`, `RenderSliverWithKeepAliveMixin`, `RenderTreeSliver`, `RenderView`, `RenderViewportBase`, `RendererBinding`, `RenderingFlutterBinding`, `RenderingServiceExtensions`, `RevealedOffset`, `ScrollCacheExtent`, `ScrollDirection`, `SelectAllSelectionEvent`, `SelectParagraphSelectionEvent`, `SelectWordSelectionEvent`, `Selectable`, `SelectedContent`, `SelectedContentRange`, `SelectionEdgeUpdateEvent`, `SelectionEvent`, `SelectionEventType`, `SelectionExtendDirection`, `SelectionGeometry`, `SelectionHandler`, `SelectionPoint`, `SelectionRegistrant`, `SelectionRegistrar`, `SelectionResult`, `SelectionStatus`, `SelectionUtils`, `SemanticsAnnotationsMixin`, `SemanticsBuilderCallback`, `ShaderMaskLayer`, `ShapeBorderClipper`, `SingleChildLayoutDelegate`, `SliverGridGeometry`, `SliverGridParentData`, `SliverGridRegularTileLayout`, `SliverHitTest`, `SliverHitTestEntry`, `SliverHitTestResult`, `SliverLayoutDimensions`, `SliverLogicalContainerParentData`, `SliverLogicalParentData`, `SliverPaintOrder`, `SliverPhysicalContainerParentData`, `SliverPhysicalParentData`, `TextGranularity`, `TextParentData`, `TextSelectionHandleType`, `TextSelectionPoint`, `TextureBox`, `TextureLayer`, `TransformLayer`, `TreeSliverIndentationType`, `TreeSliverNodeParentData`, `TreeSliverNodesAnimation`, `VerticalCaretMovementRun`, `ViewConfiguration`, `ViewportOffset`, `WrapAlignment`, `applyGrowthDirectionToAxisDirection`, `applyGrowthDirectionToScrollDirection`, `flipScrollDirection`

✅ `BoxConstraints`, `BoxParentData`, `CrossAxisAlignment`, `FixedColumnWidth`, `FlexColumnWidth`, `FlexFit`, `FlexParentData`, `FlowDelegate`, `FlowPaintingContext`, `FlowParentData`, `FractionColumnWidth`, `IntrinsicColumnWidth`, `MainAxisAlignment`, `MainAxisSize`, `MaxColumnWidth`, `MinColumnWidth`, `MultiChildLayoutDelegate`, `MultiChildLayoutParentData`, `PipelineOwner`, `RelativeRect`, `RenderAbsorbPointer`, `RenderAnimatedSize`, `RenderAspectRatio`, `RenderBaseline`, `RenderBox`, `RenderClipRRect`, `RenderClipRect`, `RenderConstrainedBox`, `RenderCustomMultiChildLayoutBox`, `RenderCustomPaint`, `RenderDecoratedBox`, `RenderFittedBox`, `RenderFlex`, `RenderFlow`, `RenderFractionalTranslation`, `RenderIgnorePointer`, `RenderImage`, `RenderIntrinsicHeight`, `RenderIntrinsicWidth`, `RenderLimitedBox`, `RenderMouseRegion`, `RenderObject`, `RenderOpacity`, `RenderPadding`, `RenderPointerListener`, `RenderProxyBox`, `RenderRepaintBoundary`, `RenderRotatedBox`, `RenderSemanticsAnnotations`, `RenderShaderMask`, `RenderSizedOverflowBox`, `RenderSliver`, `RenderSliverFillRemaining`, `RenderSliverGrid`, `RenderSliverList`, `RenderSliverMultiBoxAdaptor`, `RenderSliverPadding`, `RenderSliverPersistentHeader`, `RenderSliverToBoxAdapter`, `RenderStack`, `RenderTable`, `RenderTransform`, `RenderViewport`, `RenderWrap`, `ShaderCallback`, `SliverConstraints`, `SliverGeometry`, `SliverGridDelegate`, `SliverGridDelegateWithFixedCrossAxisCount`, `SliverGridDelegateWithMaxCrossAxisExtent`, `SliverGridLayout`, `SliverMultiBoxAdaptorParentData`, `StackFit`, `StackParentData`, `TableBorder`, `TableCellParentData`, `TableCellVerticalAlignment`, `TableColumnWidth`, `WrapCrossAlignment`, `WrapParentData`, `const`

### `scheduler` (10%)

❌ `PerformanceModeRequestHandle`, `Priority`, `SchedulerBinding`, `SchedulerPhase`, `SchedulerServiceExtensions`, `SchedulingStrategy`, `TaskCallback`, `TickerCallback`, `defaultSchedulingStrategy`

✅ `FrameCallback`

### `semantics` (11%)

❌ `AccessibilityFocusBlockType`, `AnnounceSemanticsEvent`, `Assertiveness`, `AttributedString`, `AttributedStringProperty`, `ChildSemanticsConfigurationsDelegate`, `ChildSemanticsConfigurationsResult`, `ChildSemanticsConfigurationsResultBuilder`, `CustomSemanticsAction`, `FocusSemanticEvent`, `LongPressSemanticsEvent`, `MoveCursorHandler`, `OrdinalSortKey`, `ScrollToOffsetHandler`, `SemanticsActionHandler`, `SemanticsBinding`, `SemanticsData`, `SemanticsEvent`, `SemanticsHandle`, `SemanticsHintOverrides`, `SemanticsLabelBuilder`, `SemanticsNodeVisitor`, `SemanticsProperties`, `SemanticsService`, `SemanticsSortKey`, `SemanticsTag`, `SemanticsUpdateCallback`, `SetSelectionHandler`, `SetTextHandler`, `TapSemanticEvent`, `TooltipSemanticsEvent`

✅ `SemanticsConfiguration`, `SemanticsNode`, `SemanticsOwner`, `TextSelection`

### `services` (4%)

❌ `AndroidMotionEvent`, `AndroidPointerCoords`, `AndroidPointerProperties`, `ApplicationSwitcherDescription`, `AssetManifest`, `AssetMetadata`, `AutofillClient`, `AutofillConfiguration`, `AutofillHints`, `AutofillScope`, `AutofillScopeMixin`, `BackgroundIsolateBinaryMessenger`, `BasicMessageChannel`, `BinaryCodec`, `BinaryMessenger`, `BrowserContextMenu`, `CachingAssetBundle`, `CharacterBoundary`, `ContentSensitivity`, `DefaultProcessTextService`, `DefaultSpellCheckService`, `DeferredComponent`, `DeltaTextInputClient`, `DeviceOrientation`, `DocumentBoundary`, `EventChannel`, `FloatingCursorDragState`, `FlutterVersion`, `FontLoader`, `GLFWKeyHelper`, `GtkKeyHelper`, `HardwareKeyboard`, `IOSSystemContextMenuItemData`, `IOSSystemContextMenuItemDataCopy`, `IOSSystemContextMenuItemDataCustom`, `IOSSystemContextMenuItemDataCut`, `IOSSystemContextMenuItemDataLiveText`, `IOSSystemContextMenuItemDataLookUp`, `IOSSystemContextMenuItemDataPaste`, `IOSSystemContextMenuItemDataSelectAll`, `IOSSystemContextMenuItemDataShare`, `JSONMessageCodec`, `JSONMethodCodec`, `KeyDataTransitMode`, `KeyEventCallback`, `KeyEventManager`, `KeyHelper`, `KeyMessage`, `KeyMessageHandler`, `KeyRepeatEvent`, `KeyboardInsertedContent`, `KeyboardKey`, `KeyboardLockMode`, `KeyboardSide`, `LineBoundary`, `LiveText`, `MaxLengthEnforcement`, `MessageCodec`, `MessageHandler`, `MethodCall`, `MethodChannel`, `MethodCodec`, `MissingPluginException`, `ModifierKey`, `MouseCursor`, `MouseCursorManager`, `MouseCursorSession`, `MouseTrackerAnnotation`, `NetworkAssetBundle`, `OptionalMethodChannel`, `ParagraphBoundary`, `PhysicalKeyboardKey`, `PlatformAssetBundle`, `PlatformException`, `PointTransformer`, `PointerEnterEventListener`, `PointerExitEventListener`, `PointerHoverEventListener`, `PredictiveBackEvent`, `ProcessTextAction`, `ProcessTextService`, `RawFloatingCursorPoint`, `RawKeyDownEvent`, `RawKeyEvent`, `RawKeyEventData`, `RawKeyEventDataAndroid`, `RawKeyEventDataFuchsia`, `RawKeyEventDataIos`, `RawKeyEventDataLinux`, `RawKeyEventDataMacOs`, `RawKeyEventDataWindows`, `RawKeyEventHandler`, `RawKeyUpEvent`, `RawKeyboard`, `RestorationBucket`, `RestorationManager`, `ScribbleClient`, `Scribe`, `SelectionChangedCause`, `SelectionRect`, `SensitiveContentService`, `ServicesBinding`, `ServicesServiceExtensions`, `SmartDashesType`, `SmartQuotesType`, `SpellCheckResults`, `SpellCheckService`, `StandardMessageCodec`, `StandardMethodCodec`, `StringCodec`, `SuggestionSpan`, `SwipeEdge`, `SystemChannels`, `SystemContextMenuClient`, `SystemContextMenuController`, `SystemMouseCursor`, `SystemMouseCursors`, `SystemSound`, `SystemSoundType`, `SystemUiChangeCallback`, `SystemUiMode`, `SystemUiOverlay`, `SystemUiOverlayStyle`, `TextBoundary`, `TextCapitalization`, `TextEditingDelta`, `TextEditingDeltaDeletion`, `TextEditingDeltaInsertion`, `TextEditingDeltaNonTextUpdate`, `TextEditingDeltaReplacement`, `TextInput`, `TextInputControl`, `TextInputFormatFunction`, `TextInputStyle`, `TextLayoutMetrics`, `TextSelectionDelegate`, `UndoDirection`, `UndoManager`, `UndoManagerClient`, `UntilPredicate`, `appBuildName`, `appBuildNumber`, `appFlavor`, `kAndroidNumPadMap`, `kAndroidToLogicalKey`, `kAndroidToPhysicalKey`, `kFuchsiaToLogicalKey`, `kFuchsiaToPhysicalKey`, `kGlfwNumpadMap`, `kGlfwToLogicalKey`, `kGtkNumpadMap`, `kGtkToLogicalKey`, `kIosNumPadMap`, `kIosSpecialLogicalMap`, `kIosToLogicalKey`, `kIosToPhysicalKey`, `kLinuxToPhysicalKey`, `kMacOsFunctionKeyMap`, `kMacOsNumPadMap`, `kMacOsToLogicalKey`, `kMacOsToPhysicalKey`, `kProfilePlatformChannels`, `kWindowsNumPadMap`, `kWindowsToLogicalKey`, `kWindowsToPhysicalKey`, `platformViewsRegistry`, `runeToLowerCase`

✅ `KeyDownEvent`, `KeyEvent`, `KeyUpEvent`, `TextEditingValue`, `TextInputClient`, `TextInputConfiguration`, `TextInputConnection`

### `widgets` (8%)

❌ `AbstractLayoutBuilder`, `AccessibilityServiceExtensions`, `ActionDispatcher`, `ActionListener`, `ActionListenerCallback`, `ActivateAction`, `AlignTransition`, `AndroidOverscrollIndicator`, `AnimatedCrossFadeBuilder`, `AnimatedFractionallySizedBox`, `AnimatedGrid`, `AnimatedGridState`, `AnimatedItemBuilder`, `AnimatedModalBarrier`, `AnimatedPhysicalModel`, `AnimatedPositionedDirectional`, `AnimatedRemovedItemBuilder`, `AnimatedSwitcherLayoutBuilder`, `AnimatedSwitcherTransitionBuilder`, `AnimatedTransitionBuilder`, `AnimatedWidgetBaseState`, `AnnotatedRegion`, `AppExitRequestCallback`, `AppLifecycleListener`, `AppPrivateCommandCallback`, `AsyncWidgetBuilder`, `AutocompleteFieldViewBuilder`, `AutocompleteFirstOptionIntent`, `AutocompleteHighlightedOption`, `AutocompleteLastOptionIntent`, `AutocompleteNextOptionIntent`, `AutocompleteNextPageOptionIntent`, `AutocompleteOnSelected`, `AutocompleteOptionToString`, `AutocompleteOptionsBuilder`, `AutocompleteOptionsViewBuilder`, `AutocompletePreviousOptionIntent`, `AutocompletePreviousPageOptionIntent`, `AutofillContextAction`, `AutofillGroup`, `AutofillGroupState`, `AutomaticKeepAlive`, `BackButtonDispatcher`, `BackButtonListener`, `BackdropGroup`, `BallisticScrollActivity`, `Banner`, `BannerLocation`, `BannerPainter`, `BlockSemantics`, `BorderRadiusTween`, `BorderTween`, `BouncingScrollSimulation`, `BoxConstraintsTween`, `BoxScrollView`, `BuildScope`, `ButtonActivateIntent`, `CapturedThemes`, `ChangeReportingBehavior`, `CharacterActivator`, `ChildBackButtonDispatcher`, `ChildIndexGetter`, `ChildVicinity`, `ClampingScrollSimulation`, `ClipRSuperellipse`, `ClipboardStatus`, `ClipboardStatusNotifier`, `CompositedTransformFollower`, `CompositedTransformTarget`, `ConditionalElementVisitor`, `ConfirmDismissCallback`, `ConstrainedLayoutBuilder`, `ConstraintsTransformBox`, `ContentInsertionConfiguration`, `ContextAction`, `ContextMenuButtonItem`, `ContextMenuButtonType`, `CopySelectionTextIntent`, `CreateRectTween`, `CrossFadeState`, `DecoratedBoxTransition`, `DecoratedSliver`, `DecorationTween`, `DefaultAssetBundle`, `DefaultPlatformMenuDelegate`, `DefaultSelectionStyle`, `DefaultTextEditingShortcuts`, `DefaultTextHeightBehavior`, `DefaultTextStyleTransition`, `DefaultTransitionDelegate`, `DefaultWidgetsLocalizations`, `DelegatedTransitionBuilder`, `DeleteCharacterIntent`, `DeleteToLineBreakIntent`, `DeleteToNextWordBoundaryIntent`, `DesktopTextSelectionToolbarLayoutDelegate`, `DeviceOrientationBuilder`, `DiagonalDragBehavior`, `DidRemovePageCallback`, `DirectionalCaretMovementIntent`, `DirectionalFocusAction`, `DirectionalFocusIntent`, `DirectionalFocusTraversalPolicyMixin`, `DirectionalTextEditingIntent`, `DismissAction`, `DismissDirection`, `DismissDirectionCallback`, `DismissMenuAction`, `DismissUpdateCallback`, `DismissUpdateDetails`, `DisplayFeatureSubScreen`, `DisposableBuildContext`, `DoNothingAction`, `DoNothingAndStopPropagationIntent`, `DoNothingAndStopPropagationTextIntent`, `DoNothingIntent`, `DragAnchorStrategy`, `DragBoundary`, `DragBoundaryDelegate`, `DragEndCallback`, `DragScrollActivity`, `DragTargetAccept`, `DragTargetAcceptWithDetails`, `DragTargetBuilder`, `DragTargetDetails`, `DragTargetLeave`, `DragTargetMove`, `DragTargetWillAccept`, `DragTargetWillAcceptWithDetails`, `DragUpdateCallback`, `DraggableCanceledCallback`, `DraggableDetails`, `DraggableScrollableActuator`, `DraggableScrollableController`, `DraggableScrollableNotification`, `DraggableScrollableSheet`, `DrivenScrollActivity`, `DualTransitionBuilder`, `EdgeDraggingAutoScroller`, `EdgeInsetsGeometryTween`, `EdgeInsetsTween`, `EditableTextContextMenuBuilder`, `EditableTextState`, `EditableTextTapOutsideIntent`, `EditableTextTapUpOutsideIntent`, `ElementCreatedCallback`, `ElementVisitor`, `EmptyTextSelectionControls`, `ErrorWidgetBuilder`, `ExcludeFocus`, `ExcludeFocusTraversal`, `ExcludeSemantics`, `ExpandSelectionToDocumentBoundaryIntent`, `ExpandSelectionToLineBreakIntent`, `Expansible`, `ExpansibleBuilder`, `ExpansibleComponentBuilder`, `ExpansibleController`, `ExtendSelectionByCharacterIntent`, `ExtendSelectionToDocumentBoundaryIntent`, `ExtendSelectionToLineBreakIntent`, `ExtendSelectionToNextParagraphBoundaryIntent`, `ExtendSelectionToNextParagraphBoundaryOrCaretLocationIntent`, `ExtendSelectionToNextWordBoundaryIntent`, `ExtendSelectionToNextWordBoundaryOrCaretLocationIntent`, `ExtendSelectionVerticallyToAdjacentLineIntent`, `ExtendSelectionVerticallyToAdjacentPageIntent`, `FadeInImage`, `FadeUpwardsPageTransitionsBuilder`, `Feedback`, `FixedExtentMetrics`, `FixedExtentScrollController`, `FixedExtentScrollPhysics`, `FixedScrollMetrics`, `FloatingHeaderSnapMode`, `FocusHighlightMode`, `FocusHighlightStrategy`, `FocusOnKeyCallback`, `FocusOnKeyEventCallback`, `FocusOrder`, `FocusTraversalOrder`, `FocusTraversalPolicy`, `FocusableActionDetector`, `FormFieldBuilder`, `FormFieldErrorBuilder`, `FormFieldSetter`, `FormFieldState`, `FormFieldValidator`, `GenerateAppTitle`, `GestureRecognizerFactory`, `GestureRecognizerFactoryConstructor`, `GestureRecognizerFactoryInitializer`, `GestureRecognizerFactoryWithHandlers`, `GlowingOverscrollIndicator`, `GridPaper`, `HeroController`, `HeroControllerScope`, `HeroFlightDirection`, `HeroFlightShuttleBuilder`, `HeroMode`, `HeroPlaceholderBuilder`, `HoldScrollActivity`, `IOSSystemContextMenuItem`, `IOSSystemContextMenuItemCopy`, `IOSSystemContextMenuItemCustom`, `IOSSystemContextMenuItemCut`, `IOSSystemContextMenuItemLiveText`, `IOSSystemContextMenuItemLookUp`, `IOSSystemContextMenuItemPaste`, `IOSSystemContextMenuItemSelectAll`, `IOSSystemContextMenuItemShare`, `IconDataProperty`, `IdleScrollActivity`, `IgnoreBaseline`, `ImageErrorWidgetBuilder`, `ImageFrameBuilder`, `ImageIcon`, `ImageLoadingBuilder`, `IndexedSemantics`, `IndexedSlot`, `IndexedWidgetBuilder`, `InheritedModelElement`, `InheritedTheme`, `InitialRouteListFactory`, `InteractiveViewerWidgetBuilder`, `KeepAlive`, `KeepAliveHandle`, `KeepAliveNotification`, `KeyEventResult`, `KeySet`, `LabeledGlobalKey`, `LayoutChangedNotification`, `LeafRenderObjectElement`, `LeafRenderObjectWidget`, `LexicalFocusOrder`, `ListWheelChildBuilderDelegate`, `ListWheelChildDelegate`, `ListWheelChildListDelegate`, `ListWheelChildLoopingListDelegate`, `ListWheelElement`, `ListWheelScrollView`, `ListWheelViewport`, `LiveTextInputStatus`, `LiveTextInputStatusNotifier`, `LocalHistoryEntry`, `LocalHistoryRoute`, `LocaleListResolutionCallback`, `LocaleResolutionCallback`, `LocalizationsResolver`, `LockState`, `LogicalKeySet`, `LookupBoundary`, `MagnifierBuilder`, `MagnifierController`, `MagnifierDecoration`, `MagnifierInfo`, `Matrix4Tween`, `MatrixTransition`, `MenuItemSerializableIdGenerator`, `MenuSerializableShortcut`, `MetaData`, `ModalBarrier`, `MultiSelectableSelectionContainerDelegate`, `NavigationMode`, `NavigationNotification`, `NavigationToolbar`, `NavigatorFinderCallback`, `NavigatorObserver`, `NavigatorPopHandler`, `NestedScrollViewState`, `NestedScrollViewViewport`, `NextFocusAction`, `NotifiableElementMixin`, `Notification`, `NotificationListenerCallback`, `NullableIndexedWidgetBuilder`, `NumericFocusOrder`, `OnInvokeCallback`, `OnKeyEventCallback`, `OpenUpwardsPageTransitionsBuilder`, `OptionsViewOpenDirection`, `OrderedTraversalPolicy`, `OrientationBuilder`, `OrientationWidgetBuilder`, `OverflowBarAlignment`, `OverlayChildLayoutBuilder`, `OverlayChildLayoutInfo`, `OverlayChildLocation`, `OverlayPortalController`, `OverscrollIndicatorNotification`, `OverscrollNotification`, `Page`, `PageMetrics`, `PageRouteFactory`, `PageScrollPhysics`, `PageStorage`, `PageStorageBucket`, `PageTransitionsBuilder`, `PanAxis`, `PasteTextIntent`, `PhysicalShape`, `PinnedHeaderSliver`, `PlatformMenuDelegate`, `PlatformMenuItemGroup`, `PlatformProvidedMenuItem`, `PlatformProvidedMenuItemType`, `PlatformRouteInformationProvider`, `PlatformSelectableRegionContextMenu`, `PopEntry`, `PopInvokedCallback`, `PopInvokedWithResultCallback`, `PopNavigatorRouterDelegateMixin`, `PopPageCallback`, `PopResultCallback`, `PopupRoute`, `PositionedTransition`, `PredictiveBackRoute`, `PreferredSize`, `PreferredSizeWidget`, `PreviousFocusAction`, `PrimaryScrollController`, `PrioritizedAction`, `PrioritizedIntents`, `ProxyElement`, `ProxyWidget`, `RadioBuilder`, `RadioClient`, `RadioGroup`, `RadioGroupRegistry`, `RangeMaintainingScrollPhysics`, `RawAutocomplete`, `RawDialogRoute`, `RawDialogRouteBuilder`, `RawGestureDetector`, `RawGestureDetectorState`, `RawImage`, `RawKeyboardListener`, `RawMagnifier`, `RawMenuAnchor`, `RawMenuAnchorChildBuilder`, `RawMenuAnchorCloseRequestedCallback`, `RawMenuAnchorGroup`, `RawMenuAnchorOpenRequestedCallback`, `RawMenuAnchorOverlayBuilder`, `RawMenuOverlayInfo`, `RawRadio`, `RawScrollbar`, `RawScrollbarState`, `RawTooltip`, `RawTooltipState`, `RawView`, `ReadingOrderTraversalPolicy`, `RebuildDirtyWidgetCallback`, `RedoTextIntent`, `RegisterServiceExtensionCallback`, `RegisterViewFactory`, `RelativePositionedTransition`, `RelativeRectTween`, `RenderAbstractLayoutBuilderMixin`, `RenderConstrainedLayoutBuilder`, `RenderNestedScrollViewViewport`, `RenderObjectToWidgetAdapter`, `RenderObjectToWidgetElement`, `RenderSliverOverlapAbsorber`, `RenderSliverOverlapInjector`, `RenderTapRegion`, `RenderTapRegionSurface`, `RenderTreeRootElement`, `RenderTwoDimensionalViewport`, `ReorderCallback`, `ReorderDragBoundaryProvider`, `ReorderItemProxyDecorator`, `ReorderableDelayedDragStartListener`, `ReorderableDragStartListener`, `ReorderableList`, `ReorderableListState`, `RepeatMode`, `RepeatingAnimationBuilder`, `ReplaceTextIntent`, `RequestFocusAction`, `RequestFocusIntent`, `RestorableBool`, `RestorableBoolN`, `RestorableChangeNotifier`, `RestorableDateTime`, `RestorableDateTimeN`, `RestorableDouble`, `RestorableDoubleN`, `RestorableEnum`, `RestorableEnumN`, `RestorableInt`, `RestorableIntN`, `RestorableListenable`, `RestorableNum`, `RestorableNumN`, `RestorableProperty`, `RestorableRouteBuilder`, `RestorableRouteFuture`, `RestorableString`, `RestorableStringN`, `RestorableTextEditingController`, `RestorableValue`, `RestorationMixin`, `RestorationScope`, `RootBackButtonDispatcher`, `RootElement`, `RootElementMixin`, `RootRenderObjectElement`, `RootRestorationScope`, `RootWidget`, `RouteAware`, `RouteBarrierBuilder`, `RouteBarrierDetails`, `RouteCompletionCallback`, `RouteInformation`, `RouteInformationParser`, `RouteInformationProvider`, `RouteInformationReportingType`, `RouteListFactory`, `RouteObserver`, `RoutePageBuilder`, `RoutePredicate`, `RoutePresentationCallback`, `RouteTransitionRecord`, `RouteTransitionsBuilder`, `Router`, `RouterConfig`, `RouterDelegate`, `ScrollAction`, `ScrollActivity`, `ScrollActivityDelegate`, `ScrollAwareImageProvider`, `ScrollBehavior`, `ScrollConfiguration`, `ScrollContext`, `ScrollControllerCallback`, `ScrollDecelerationRate`, `ScrollDragController`, `ScrollEndNotification`, `ScrollHoldController`, `ScrollIncrementCalculator`, `ScrollIncrementDetails`, `ScrollIncrementType`, `ScrollMetrics`, `ScrollMetricsNotification`, `ScrollNotificationCallback`, `ScrollNotificationObserver`, `ScrollNotificationObserverState`, `ScrollNotificationPredicate`, `ScrollPositionAlignmentPolicy`, `ScrollPositionWithSingleContext`, `ScrollStartNotification`, `ScrollToDocumentBoundaryIntent`, `ScrollUpdateNotification`, `ScrollView`, `ScrollViewKeyboardDismissBehavior`, `ScrollableDetails`, `ScrollableState`, `ScrollableWidgetBuilder`, `ScrollbarOrientation`, `ScrollbarPainter`, `SelectAction`, `SelectAllTextIntent`, `SelectIntent`, `SelectableDayPredicate`, `SelectableRegion`, `SelectableRegionContextMenuBuilder`, `SelectableRegionSelectionStatus`, `SelectableRegionSelectionStatusScope`, `SelectableRegionState`, `SelectionChangedCallback`, `SelectionContainer`, `SelectionContainerDelegate`, `SelectionDetails`, `SelectionListener`, `SelectionListenerNotifier`, `SelectionOverlay`, `SelectionRegistrarScope`, `SemanticIndexCallback`, `SemanticsDebugger`, `SemanticsGestureDelegate`, `SensitiveContent`, `SensitiveContentHost`, `SharedAppData`, `SharedAppDataInitCallback`, `ShortcutActivator`, `ShortcutManager`, `ShortcutMapProperty`, `ShortcutRegistrar`, `ShortcutRegistry`, `ShortcutRegistryEntry`, `ShortcutSerialization`, `ShrinkWrappingViewport`, `SizeChangedLayoutNotification`, `SizeChangedLayoutNotifier`, `SliverAnimatedGrid`, `SliverAnimatedGridState`, `SliverAnimatedList`, `SliverAnimatedListState`, `SliverAnimatedOpacity`, `SliverConstrainedCrossAxis`, `SliverCrossAxisExpanded`, `SliverCrossAxisGroup`, `SliverEnsureSemantics`, `SliverFadeTransition`, `SliverFillViewport`, `SliverFloatingHeader`, `SliverIgnorePointer`, `SliverLayoutBuilder`, `SliverLayoutWidgetBuilder`, `SliverMainAxisGroup`, `SliverOffstage`, `SliverOpacity`, `SliverOverlapAbsorber`, `SliverOverlapAbsorberHandle`, `SliverOverlapInjector`, `SliverPrototypeExtentList`, `SliverReorderableList`, `SliverReorderableListState`, `SliverResizingHeader`, `SliverSafeArea`, `SliverSemantics`, `SliverVariedExtentList`, `SliverVisibility`, `SliverWithKeepAliveWidget`, `SlottedContainerRenderObjectMixin`, `SlottedMultiChildRenderObjectWidget`, `SlottedMultiChildRenderObjectWidgetMixin`, `SlottedRenderObjectElement`, `SnapshotController`, `SnapshotMode`, `SnapshotPainter`, `SnapshotWidget`, `SpellCheckConfiguration`, `StandardComponentType`, `StateSetter`, `StatefulWidgetBuilder`, `StaticSelectionContainerDelegate`, `StatusTransitionWidget`, `StreamBuilderBase`, `StretchEffect`, `StretchingOverscrollIndicator`, `SystemContextMenu`, `SystemTextScaler`, `TapBehaviorButtonBuilder`, `TapRegion`, `TapRegionCallback`, `TapRegionRegistry`, `TapRegionSurface`, `TapRegionUpCallback`, `TextFieldTapRegion`, `TextMagnifierConfiguration`, `TextSelectionControls`, `TextSelectionGestureDetector`, `TextSelectionGestureDetectorBuilder`, `TextSelectionGestureDetectorBuilderDelegate`, `TextSelectionHandleControls`, `TextSelectionOverlay`, `TextSelectionToolbarAnchors`, `TextSelectionToolbarLayoutDelegate`, `TextStyleTween`, `Texture`, `TickerMode`, `TickerModeData`, `Title`, `ToggleablePainter`, `ToggleableStateMixin`, `ToolbarBuilder`, `ToolbarItemsParentData`, `ToolbarOptions`, `TooltipComponentBuilder`, `TooltipPositionContext`, `TooltipPositionDelegate`, `TooltipTriggeredCallback`, `TrackingScrollController`, `TransformCallback`, `TransformationController`, `TransitionBuilder`, `TransitionDelegate`, `TransposeCharactersIntent`, `TraversalEdgeBehavior`, `TraversalRequestFocusCallback`, `TreeSliver`, `TreeSliverController`, `TreeSliverNode`, `TreeSliverNodeBuilder`, `TreeSliverNodeCallback`, `TreeSliverRowExtentBuilder`, `TreeSliverStateMixin`, `TweenConstructor`, `TweenVisitor`, `TwoDimensionalChildBuilderDelegate`, `TwoDimensionalChildDelegate`, `TwoDimensionalChildListDelegate`, `TwoDimensionalChildManager`, `TwoDimensionalIndexedWidgetBuilder`, `TwoDimensionalScrollView`, `TwoDimensionalScrollable`, `TwoDimensionalScrollableState`, `TwoDimensionalViewport`, `TwoDimensionalViewportBuilder`, `TwoDimensionalViewportParentData`, `UndoHistory`, `UndoHistoryController`, `UndoHistoryState`, `UndoHistoryValue`, `UndoTextIntent`, `UnfocusDisposition`, `UniqueWidget`, `UnmanagedRestorationScope`, `UpdateSelectionIntent`, `UserScrollNotification`, `ValueWidgetBuilder`, `View`, `ViewAnchor`, `ViewCollection`, `Viewport`, `ViewportBuilder`, `ViewportElementMixin`, `ViewportNotificationMixin`, `VoidCallbackAction`, `VoidCallbackIntent`, `WeakMap`, `WidgetOrderTraversalPolicy`, `WidgetPropertyResolver`, `WidgetState`, `WidgetStateBorderSide`, `WidgetStateColor`, `WidgetStateMap`, `WidgetStateMapper`, `WidgetStateMouseCursor`, `WidgetStateOutlinedBorder`, `WidgetStateProperty`, `WidgetStatePropertyAll`, `WidgetStateTextStyle`, `WidgetStatesConstraint`, `WidgetStatesController`, `WidgetToRenderBoxAdapter`, `WidgetsBindingObserver`, `WidgetsLocalizations`, `WidgetsServiceExtensions`, `WillPopCallback`, `WillPopScope`, `basicLocaleListResolution`, `buildTextSpanWithSpellCheckSuggestions`, `childDragAnchorStrategy`, `combineKeyEventResults`, `createLocalImageConfiguration`, `defaultScrollNotificationPredicate`, `emptyTextSelectionControls`, `getAxisDirectionFromAxisReverseAndDirectionality`, `intentForMacOSSelector`, `kDefaultContentInsertionMimeTypes`, `kDefaultRouteDirectionalTraversalEdgeBehavior`, `kDefaultRouteTraversalEdgeBehavior`, `pointerDragAnchorStrategy`, `precacheImage`, `runWidget`, `showRawDialog`, `staticIconProvider`, `widgetFactory`

✅ `ActivateIntent`, `AnimatedDefaultTextStyle`, `AnimatedList`, `AnimatedListState`, `AnimatedWidget`, `BuildOwner`, `CallbackAction`, `ComponentElement`, `ContextMenuController`, `DismissIntent`, `Element`, `FocusAttachment`, `FocusManager`, `FractionalTranslation`, `ImplicitlyAnimatedWidget`, `ImplicitlyAnimatedWidgetState`, `InheritedElement`, `LayoutId`, `LayoutWidgetBuilder`, `LocalizationsDelegate`, `MenuController`, `MergeSemantics`, `MultiChildRenderObjectElement`, `MultiChildRenderObjectWidget`, `NestedScrollViewHeaderSliversBuilder`, `NextFocusIntent`, `Orientation`, `OverlayRoute`, `OverlayState`, `ParentDataElement`, `ParentDataWidget`, `PlatformMenu`, `PlatformMenuBar`, `PlatformMenuItem`, `PreviousFocusIntent`, `RenderObjectElement`, `RenderObjectWidget`, `RepaintBoundary`, `RouteFactory`, `RoutePopDisposition`, `RouteSettings`, `ScrollIntent`, `Scrollable`, `Semantics`, `SingleChildRenderObjectElement`, `SingleChildRenderObjectWidget`, `SizedOverflowBox`, `SliverChildBuilderDelegate`, `SliverChildDelegate`, `SliverChildListDelegate`, `SliverFixedExtentList`, `SliverMultiBoxAdaptorElement`, `SliverMultiBoxAdaptorWidget`, `SliverPersistentHeaderDelegate`, `StatefulElement`, `StatelessElement`, `TableCell`, `TooltipTriggerMode`, `TransitionRoute`, `TraversalDirection`, `WidgetBuilder`


## P2 por biblioteca

### `cupertino` (0%)

❌ `CupertinoActionSheet`, `CupertinoActionSheetAction`, `CupertinoActivityIndicator`, `CupertinoAdaptiveTextSelectionToolbar`, `CupertinoAlertDialog`, `CupertinoApp`, `CupertinoButton`, `CupertinoButtonSize`, `CupertinoCheckbox`, `CupertinoColors`, `CupertinoContextMenu`, `CupertinoContextMenuAction`, `CupertinoContextMenuBuilder`, `CupertinoDatePicker`, `CupertinoDatePickerMode`, `CupertinoDesktopTextSelectionControls`, `CupertinoDesktopTextSelectionToolbar`, `CupertinoDesktopTextSelectionToolbarButton`, `CupertinoDialogAction`, `CupertinoDialogRoute`, `CupertinoDynamicColor`, `CupertinoExpansionTile`, `CupertinoFocusHalo`, `CupertinoFormRow`, `CupertinoFormSection`, `CupertinoFullscreenDialogTransition`, `CupertinoIconThemeData`, `CupertinoIcons`, `CupertinoLinearActivityIndicator`, `CupertinoListSection`, `CupertinoListSectionType`, `CupertinoListTile`, `CupertinoListTileChevron`, `CupertinoLocalizations`, `CupertinoMagnifier`, `CupertinoMenuAnchor`, `CupertinoMenuAnimationStatusChangedCallback`, `CupertinoMenuDivider`, `CupertinoMenuEntry`, `CupertinoMenuItem`, `CupertinoModalPopupRoute`, `CupertinoNavigationBar`, `CupertinoNavigationBarBackButton`, `CupertinoPage`, `CupertinoPageRoute`, `CupertinoPageScaffold`, `CupertinoPageScaffoldBackgroundColor`, `CupertinoPageTransition`, `CupertinoPageTransitionsBuilder`, `CupertinoPicker`, `CupertinoPickerDefaultSelectionOverlay`, `CupertinoPopupSurface`, `CupertinoRadio`, `CupertinoRouteTransitionMixin`, `CupertinoScrollBehavior`, `CupertinoScrollbar`, `CupertinoSearchTextField`, `CupertinoSegmentedControl`, `CupertinoSheetRoute`, `CupertinoSheetTransition`, `CupertinoSlider`, `CupertinoSlidingSegmentedControl`, `CupertinoSliverNavigationBar`, `CupertinoSliverRefreshControl`, `CupertinoSpellCheckSuggestionsToolbar`, `CupertinoSwitch`, `CupertinoTabBar`, `CupertinoTabController`, `CupertinoTabScaffold`, `CupertinoTabView`, `CupertinoTextField`, `CupertinoTextFormFieldRow`, `CupertinoTextMagnifier`, `CupertinoTextSelectionControls`, `CupertinoTextSelectionHandleControls`, `CupertinoTextSelectionToolbar`, `CupertinoTextSelectionToolbarButton`, `CupertinoTextThemeData`, `CupertinoTheme`, `CupertinoThemeData`, `CupertinoThumbPainter`, `CupertinoTimerPicker`, `CupertinoTimerPickerMode`, `CupertinoToolbarBuilder`, `CupertinoUserInterfaceLevel`, `CupertinoUserInterfaceLevelData`, `DatePickerDateOrder`, `DatePickerDateTimeOrder`, `DefaultCupertinoLocalizations`, `ExpansionTileTransitionMode`, `InheritedCupertinoTheme`, `NavigationBarBottomMode`, `NoDefaultCupertinoThemeData`, `ObstructingPreferredSizeWidget`, `OverlayVisibilityMode`, `RefreshControlIndicatorBuilder`, `RefreshIndicatorMode`, `RestorableCupertinoTabController`, `SelectionOverlayBuilder`, `createCupertinoColorProperty`, `cupertinoDesktopTextSelectionControls`, `cupertinoDesktopTextSelectionHandleControls`, `cupertinoTextSelectionControls`, `cupertinoTextSelectionHandleControls`, `kCupertinoButtonDefaultIconSize`, `kCupertinoButtonMinSize`, `kCupertinoButtonPadding`, `kCupertinoButtonSizeBorderRadius`, `kCupertinoButtonTapMoveSlop`, `kCupertinoButtonTintedOpacityLight`, `kCupertinoFocusColorOpacity`, `kCupertinoModalBarrierColor`, `kMinInteractiveDimensionCupertino`, `showCupertinoDialog`, `showCupertinoModalPopup`, `showCupertinoSheet`

## Não se aplica

- Flutter DevTools: `DevToolsDeepLinkProperty`, `DisableWidgetInspectorScope`, `EnableWidgetInspectorScope`, `ExitWidgetSelectionButtonBuilder`, `InspectorButton`, `InspectorButtonVariant`, `InspectorReferenceData`, `InspectorSelection`, `InspectorSelectionChangedCallback`, `InspectorSerializationDelegate`, `MoveExitWidgetSelectionButtonBuilder`, `WidgetInspector`, `WidgetInspectorService`, `WidgetInspectorServiceExtensions`
- Flutter's debug banner: `CheckedModeBanner`
- Flutter's debug hooks: `debugAssertAllFoundationVarsUnset`, `debugAssertAllGesturesVarsUnset`, `debugAssertAllPaintingVarsUnset`, `debugAssertAllRenderVarsUnset`, `debugAssertAllSchedulerVarsUnset`, `debugAssertAllServicesVarsUnset`, `debugAssertAllWidgetVarsUnset`, `debugCheckCanResolveTextDirection`, `debugCheckHasBoundedAxis`, `debugCheckHasCupertinoLocalizations`, `debugCheckHasDirectionality`, `debugCheckHasMaterial`, `debugCheckHasMaterialLocalizations`, `debugCheckHasMediaQuery`, `debugCheckHasOverlay`, `debugCheckHasScaffold`, `debugCheckHasScaffoldMessenger`, `debugCheckHasTable`, `debugCheckHasWidgetsLocalizations`, `debugChildrenHaveDuplicateKeys`, `debugDescribeFocusTree`, `debugDescribeTransform`, `debugDumpApp`, `debugDumpFocusTree`, `debugDumpLayerTree`, `debugDumpPipelineOwnerTree`, `debugDumpRenderObjectSemanticsTree`, `debugDumpRenderTree`, `debugDumpSemanticsTree`, `debugFlushLastFrameImageSizeInfo`, `debugFormatDouble`, `debugInstrumentAction`, `debugIsLocalCreationLocation`, `debugIsSerializableForRestoration`, `debugIsWidgetLocalCreation`, `debugItemsHaveDuplicateKeys`, `debugMaybeDispatchCreated`, `debugMaybeDispatchDisposed`, `debugPaintPadding`, `debugPrint`, `debugPrintStack`, `debugPrintSynchronously`, `debugPrintThrottled`, `debugResetSemanticsIdCounter`, `debugTransformDebugCreator`, `debugWidgetBuilderValue`, `debugWordWrap`
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
