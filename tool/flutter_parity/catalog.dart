/// What the Flutter parity table cannot read from source: which names
/// matter most, which names exist here with a different shape, and which do
/// not apply to this framework at all.
///
/// Honest parity: a name that exists here but does not take the same
/// arguments or mean the same thing is listed in [kPartial] with what
/// differs, and counts as half. When in doubt, mark it down.
library;

/// The names a typical Flutter app or package touches first. Missing one of
/// these blocks a migration; they are worked on before anything else.
const Set<String> kP0 = <String>{
  // Running an app.
  'runApp', 'WidgetsApp', 'MaterialApp', 'WidgetsBinding',
  'WidgetsFlutterBinding', 'BuildContext', 'Widget', 'StatelessWidget',
  'StatefulWidget', 'State', 'InheritedWidget', 'InheritedNotifier',
  'InheritedModel', 'Key', 'ValueKey', 'ObjectKey', 'UniqueKey', 'GlobalKey',
  'GlobalObjectKey', 'KeyedSubtree', 'Builder', 'StatefulBuilder',
  'LayoutBuilder', 'MediaQuery', 'MediaQueryData', 'Directionality',
  'Localizations', 'ErrorWidget',
  // Layout.
  'Container', 'Padding', 'Align', 'Center', 'SizedBox', 'ConstrainedBox',
  'UnconstrainedBox', 'LimitedBox', 'OverflowBox', 'FractionallySizedBox',
  'AspectRatio', 'FittedBox', 'Row', 'Column', 'Flex', 'Expanded', 'Flexible',
  'Spacer', 'Wrap', 'Stack', 'Positioned', 'PositionedDirectional',
  'IndexedStack', 'Table', 'TableRow', 'CustomMultiChildLayout',
  'CustomSingleChildLayout', 'Flow', 'ListBody', 'Offstage', 'Visibility',
  'IntrinsicHeight', 'IntrinsicWidth', 'Baseline', 'SafeArea', 'Placeholder',
  'OverflowBar',
  // Painting and decoration.
  'DecoratedBox', 'BoxDecoration', 'ShapeDecoration', 'BorderRadius',
  'Border', 'BorderSide', 'BoxShadow', 'LinearGradient', 'RadialGradient',
  'SweepGradient', 'EdgeInsets', 'EdgeInsetsDirectional', 'Alignment',
  'AlignmentDirectional', 'Color', 'Colors', 'Offset', 'Size', 'Rect',
  'Radius', 'RRect', 'Canvas', 'Paint', 'Path', 'CustomPaint',
  'CustomPainter', 'ClipRect', 'ClipRRect', 'ClipOval', 'ClipPath',
  'CustomClipper', 'Opacity', 'Transform', 'RotatedBox', 'ColoredBox',
  'ColorFiltered', 'ImageFiltered', 'BackdropFilter', 'ShaderMask',
  'PhysicalModel', 'Matrix4', 'BoxFit', 'Clip', 'BlendMode',
  // Text and images.
  'Text', 'RichText', 'TextSpan', 'WidgetSpan', 'TextStyle', 'DefaultTextStyle',
  'TextAlign', 'TextOverflow', 'FontWeight', 'TextTheme', 'SelectableText',
  'SelectionArea', 'EditableText', 'TextEditingController', 'TextField',
  'TextFormField', 'Image', 'ImageProvider', 'AssetImage', 'NetworkImage',
  'FileImage', 'MemoryImage', 'Icon', 'IconData', 'Icons', 'IconTheme',
  'IconThemeData',
  // Input.
  'GestureDetector', 'Listener', 'MouseRegion', 'InkWell', 'AbsorbPointer',
  'IgnorePointer', 'Draggable', 'LongPressDraggable', 'DragTarget',
  'Dismissible', 'InteractiveViewer', 'Focus', 'FocusNode', 'FocusScope',
  'FocusScopeNode', 'FocusTraversalGroup', 'KeyboardListener', 'Shortcuts',
  'Actions', 'Action', 'Intent', 'CallbackShortcuts', 'SingleActivator',
  'LogicalKeyboardKey', 'Form', 'FormField', 'FormState', 'AutovalidateMode',
  // Scrolling.
  'ListView', 'GridView', 'SingleChildScrollView', 'CustomScrollView',
  'PageView', 'PageController', 'ScrollController', 'ScrollPosition',
  'ScrollPhysics', 'BouncingScrollPhysics', 'ClampingScrollPhysics',
  'NeverScrollableScrollPhysics', 'AlwaysScrollableScrollPhysics',
  'Scrollbar', 'NotificationListener', 'ScrollNotification',
  'SliverList', 'SliverGrid', 'SliverToBoxAdapter', 'SliverAppBar',
  'SliverPadding', 'SliverFillRemaining', 'SliverPersistentHeader',
  'NestedScrollView', 'RefreshIndicator', 'ReorderableListView',
  'AutomaticKeepAliveClientMixin', 'PageStorageKey',
  // Navigation and overlays.
  'Navigator', 'NavigatorState', 'Route', 'PageRoute', 'MaterialPageRoute',
  'PageRouteBuilder', 'ModalRoute', 'Overlay', 'OverlayEntry',
  'OverlayPortal', 'Hero', 'PopScope', 'showDialog', 'showGeneralDialog',
  'showModalBottomSheet', 'showMenu', 'Tooltip',
  // Animation.
  'AnimationController', 'Animation', 'Tween', 'ColorTween', 'CurvedAnimation',
  'Curves', 'AnimatedBuilder', 'AnimatedContainer', 'AnimatedOpacity',
  'AnimatedPositioned', 'AnimatedAlign', 'AnimatedPadding', 'AnimatedSwitcher',
  'AnimatedCrossFade', 'AnimatedSize', 'AnimatedScale', 'AnimatedRotation',
  'AnimatedSlide', 'FadeTransition', 'SlideTransition', 'ScaleTransition',
  'RotationTransition', 'SizeTransition', 'TweenAnimationBuilder',
  'SingleTickerProviderStateMixin', 'TickerProviderStateMixin', 'Ticker',
  // State helpers.
  'ValueNotifier', 'ValueListenableBuilder', 'ChangeNotifier', 'Listenable',
  'ListenableBuilder', 'FutureBuilder', 'StreamBuilder', 'AsyncSnapshot',
  'ConnectionState', 'VoidCallback', 'ValueChanged',
  // Services an app reaches for.
  'Clipboard', 'ClipboardData', 'HapticFeedback', 'SystemChrome',
  'SystemNavigator', 'rootBundle', 'AssetBundle', 'TextInputType',
  'TextInputAction', 'TextInputFormatter', 'FilteringTextInputFormatter',
  'LengthLimitingTextInputFormatter',
  // Material most apps use.
  'Theme', 'ThemeData', 'ColorScheme', 'Scaffold', 'ScaffoldMessenger',
  'SnackBar', 'AppBar', 'Drawer', 'BottomNavigationBar',
  'BottomNavigationBarItem', 'NavigationBar', 'NavigationRail', 'TabBar',
  'TabBarView', 'Tab', 'TabController', 'DefaultTabController',
  'FloatingActionButton', 'ElevatedButton', 'FilledButton', 'OutlinedButton',
  'TextButton', 'IconButton', 'ButtonStyle', 'Card', 'ListTile', 'Divider',
  'Chip', 'Checkbox', 'CheckboxListTile', 'Radio', 'RadioListTile', 'Switch',
  'SwitchListTile', 'Slider', 'RangeSlider', 'DropdownButton',
  'DropdownMenuItem', 'PopupMenuButton', 'PopupMenuItem', 'AlertDialog',
  'SimpleDialog', 'Dialog', 'CircularProgressIndicator',
  'LinearProgressIndicator', 'InputDecoration', 'OutlineInputBorder',
  'Material', 'InkResponse', 'ExpansionTile', 'DataTable', 'Stepper',
  'showDatePicker', 'showTimePicker', 'SearchBar', 'SegmentedButton',
  'Badge', 'CircleAvatar', 'MenuAnchor', 'MenuBar', 'SubmenuButton',
  'MenuItemButton',
};

/// Names that exist here but differ from Flutter's, with what differs. They
/// count as half, and the difference is what a migration has to change.
const Map<String, String> kPartial = <String, String>{
  'Flow': '`paintChild` takes `Transform2D`, not `Matrix4`; no `clipBehavior`',
  'ListView': '`axis:` instead of `scrollDirection:`; `controller` is a '
      '`ScrollPosition`',
  'GridView': '`axis:` instead of `scrollDirection:`; `controller` is a '
      '`ScrollPosition`',
  'CustomScrollView': '`axis:` instead of `scrollDirection:`; no `center`, '
      'no `shrinkWrap`',
  'SingleChildScrollView': '`axis:` instead of `scrollDirection:`',
  'ScrollPosition': 'plays the part of `ScrollController` too, and has '
      'neither `ScrollActivity` nor `ScrollContext`',
  'SliverAppBar': 'no `snap`, `stretch` or `automaticallyImplyLeading`; '
      '`bottom` is a widget plus `bottomHeight`',
  'NestedScrollView': 'no `SliverOverlapAbsorber`/`Injector` (not needed: '
      'the body is measured below the pinned headers)',
  'SliverList': 'its delegate needs a `childCount`; rows are estimated by '
      '`estimatedItemExtent`',
  'Transform': 'a 2D affine `Transform2D`, no perspective',
  'TweenAnimationBuilder': 'resumes from the current value only for types '
      'it knows how to interpolate',
  // App and binding.
  'runApp': 'returns `Future<Application>`; window title and size through '
      '`options:`',
  'WidgetsBinding': 'a class, not a mixin, speaking for the main window; no '
      '`platformDispatcher`, `renderView` or `deferFirstFrame`',
  'WidgetsFlutterBinding': 'only `ensureInitialized`',
  'WidgetsBindingObserver': '`didPopRoute`, `didPushRoute`, '
      '`didChangeLocales` and `didHaveMemoryPressure` never fire',
  'WidgetsApp': 'no `.router`, `navigatorObservers`, `shortcuts` or '
      '`actions`; `title` names the window',
  'ErrorWidget': 'a StatelessWidget drawn in the UI font',
  'PageStorage': 'scroll views do not save their offset in it yet',
  // Text input and forms.
  'TextEditingController': 'positional `TextEditingController(\'x\')`; '
      '`value` is the text, the `TextEditingValue` is `editingValue`',
  'TextField': 'no `style`, `textAlign`, `cursor*` or `expands`',
  'TextSelection': '`TextSelection.collapsed(offset)` is positional',
  'TextRange': '`TextRange(start, end)` is positional',
  'InputDecoration': 'no `label`/`hint` widgets, '
      '`prefixIconConstraints`, `floatingLabelAlignment` or `visualDensity`',
  'InputDecorator': 'the label floats without animation',
  'Form': '`onPopInvokedWithResult` always gets a null result',
  'SelectableText': 'no touch handles or toolbar; `minLines` ignored',
  // Scrolling.
  'ScrollController': 'views take a `ScrollPositionSource`; '
      '`keepScrollOffset` has no effect',
  'PageView': '`itemCount: null` becomes a very large count; one wheel '
      'notch turns one page',
  'PageController': '`keepPage` only applies across an axis change',
  'ScrollPhysics': 'simulations take a `Duration`; no '
      '`adjustPositionForNewDimensions`',
  'BouncingScrollPhysics': '`fast` only changes the spring',
  'Scrollbar': 'needs `controller:` or `position:`: there is no '
      '`PrimaryScrollController`',
  'Rect': '`intersect` gives `Rect.zero` when there is no overlap',
  'AnimationController': 'listeners fire only when the value changes; '
      '`AnimationBehavior` has no effect',
  'Ticker': 'needs an `AnimationClock`; without one it never fires',
  'TickerMode': 'no `TickerModeData` or `valuesOf`',
  'ColorScheme': '`contrastLevel` ignored; variants beyond tonalSpot and '
      'neutral are approximations',
  'ThemeData': 'the Material subset of the app shell; no button, card or '
      'dialog themes yet',
  'Icons': '`_outlined`, `_rounded` and `_sharp` draw the filled glyph',
  'Material': 'colour, elevation and shape changes do not animate',
  // Input, focus and shortcuts.
  'Listener': 'dart_ui\'s pointer events; `translucent` is hit as `opaque`',
  'Draggable': 'primary button only; cancelled if it leaves the tree',
  'LongPressDraggable': 'needs a `GestureScope` for the long press',
  'Dismissible': 'a fling has no spring simulation',
  'InteractiveViewer': '`Transform2D` instead of `Matrix4`; no inertia, no '
      '`.builder`',
  'TransformationController': 'holds a `Transform2D`',
  'Focus': 'no `onKey`; `includeSemantics` has no effect',
  'Shortcuts': 'does not answer when nothing is focused',
  'CallbackShortcuts': 'listens across the whole window',
  'LogicalKeyboardKey': '`event.logicalKey` is still an `int`; left and '
      'right modifiers compare equal',
  'CharacterActivator': 'the character is derived from the key as on a US '
      'layout',
  // Painting.
  'BoxDecoration': 'no `image`; shadows layered, not blurred; `gradient` '
      'only a `SweepGradient`',
  'ShapeDecoration': 'no `image`; shadows layered, not blurred',
  'BoxShadow': 'layered translucent shapes, not a blur',
  'Canvas': 'non-rectangular clips are a layer and a mask; no '
      '`drawParagraph`, `drawVertices` or `drawAtlas`',
  'Paint': 'no `maskFilter`, `colorFilter`, `imageFilter` or '
      '`filterQuality`',
  'BlendMode': 'only the Porter-Duff modes are real; the rest draw as '
      '`srcOver`',
  'SweepGradient': 'no `transform`; painted in 1-degree wedges',
  'Path': 'no `combine` or `computeMetrics`; `conicTo` is a cubic',
  'CustomPaint': '`isComplex` and `willChange` ignored; no semantics',
  'CustomPainter': 'no `semanticsBuilder`',
  'ClipRRect': 'an offscreen layer; not on Direct2D or the DOM',
  'ClipOval': 'an offscreen layer; not on Direct2D or the DOM',
  'ClipPath': 'an offscreen layer; not on Direct2D or the DOM',
  'LinearGradient': 'the display list\'s absolute gradient, not '
      '`colors:` with `Alignment`',
  'RadialGradient': 'the display list\'s absolute gradient, not '
      '`colors:` with `Alignment`',
};

/// Names that have no meaning here, by name or by pattern, with why.
const Map<String, String> kNotApplicable = <String, String>{
  'AndroidView': 'an Android platform view; the framework has no platform '
      'views',
  'UiKitView': 'an iOS platform view; the framework has no platform views',
  'AppKitView': 'a macOS platform view; the framework has no platform views',
  'HtmlElementView': 'web only',
  'PlatformViewLink': 'platform views',
  'PlatformViewSurface': 'platform views',
  'AndroidViewSurface': 'platform views',
  'PerformanceOverlay': 'reads the Flutter engine\'s raster statistics',
  'WidgetInspector': 'Flutter DevTools',
  'FlutterLogo': 'Flutter\'s trademark',
  'CheckedModeBanner': 'Flutter\'s debug banner',
};

/// Patterns of names that do not apply: debugging hooks of the Flutter
/// tools, the web, platform views, and the engine's internals.
final List<(RegExp, String)> kNotApplicablePatterns = <(RegExp, String)>[
  (RegExp(r'^debug'), 'Flutter\'s debug hooks'),
  (RegExp(r'Inspector|DevTools|WidgetSelection'), 'Flutter DevTools'),
  (
    RegExp(r'PlatformView|AndroidView|UiKit|AppKitView|Html|Web(?!Socket)'),
    'platform views and the web'
  ),
  (
    RegExp(r'^(Debug|Diagnostic|Diagnosticable|ErrorDescription|ErrorHint|'
        r'ErrorSummary|ErrorSpacer|FlutterError)'),
    'Flutter\'s diagnostics tree'
  ),
  (
    RegExp(r'^(SingletonFlutterWindow|FlutterView|PlatformDispatcher|'
        r'PointerData|FrameTiming|TimingsCallback)$'),
    'the Flutter engine\'s window model'
  ),
  (
    RegExp(r'^(Win32|Linux|MacOS).*Window|WindowRegistrar|^HWND$'),
    'Flutter\'s experimental multi-window API; the framework has its own'
  ),
];

/// Why [name] does not apply, or null.
String? notApplicable(String name) {
  final String? listed = kNotApplicable[name];
  if (listed != null) return listed;
  for (final (RegExp pattern, String why) in kNotApplicablePatterns) {
    if (pattern.hasMatch(name)) return why;
  }
  return null;
}

/// The priority of [name], declared in Flutter library [library].
String priorityOf(String library, String name) {
  if (kP0.contains(name)) return 'P0';
  return switch (library) {
    'cupertino' => 'P2',
    _ => 'P1',
  };
}
