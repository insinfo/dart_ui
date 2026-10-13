/// What a text field tells the platform about itself: the kind of text it
/// holds ([TextInputType]), what Enter means ([TextInputAction]) and how a
/// soft keyboard should capitalise ([TextCapitalization]) - Flutter's
/// `services` names, with Flutter's values.
///
/// On a desktop with a hardware keyboard most of this is a hint and not a
/// behaviour, exactly as in Flutter: Flutter's desktop embedders do not
/// capitalise for `TextCapitalization.words` either. What *is* behaviour here:
///
///  * [TextInputAction] decides what Enter does in a field that names one -
///    move to the next field, the previous one, or leave the field - see
///    `TextField.textInputAction`.
///  * [TextInputType] and [TextCapitalization] reach the platform's input
///    method as the field's `TextInputConfiguration` (content purpose and
///    hints), which is what an IME on Wayland or a touch keyboard reads.
library;

import '../platform/text_input_types.dart';

/// The kind of text a field holds - Flutter's `TextInputType`.
///
/// A class with constant instances rather than an enum, as in Flutter,
/// because [TextInputType.numberWithOptions] carries two flags.
final class TextInputType {
  const TextInputType._(this.index)
      : signed = null,
        decimal = null;

  /// A number, optionally signed and with a decimal separator.
  const TextInputType.numberWithOptions({
    this.signed = false,
    this.decimal = false,
  }) : index = 2;

  /// Which kind this is: the position in [values].
  final int index;

  /// For a number: whether a sign may be typed. Null for the other kinds.
  final bool? signed;

  /// For a number: whether a decimal separator may be typed. Null for the
  /// other kinds.
  final bool? decimal;

  /// Plain text.
  static const TextInputType text = TextInputType._(0);

  /// Text of several lines: Enter is a new line.
  static const TextInputType multiline = TextInputType._(1);

  /// A whole unsigned number.
  static const TextInputType number = TextInputType.numberWithOptions();

  /// A telephone number.
  static const TextInputType phone = TextInputType._(3);

  /// A date and time.
  static const TextInputType datetime = TextInputType._(4);

  /// An e-mail address.
  static const TextInputType emailAddress = TextInputType._(5);

  /// A URL.
  static const TextInputType url = TextInputType._(6);

  /// A password typed in the clear.
  static const TextInputType visiblePassword = TextInputType._(7);

  /// A person's name.
  static const TextInputType name = TextInputType._(8);

  /// A postal address.
  static const TextInputType streetAddress = TextInputType._(9);

  /// No on-screen keyboard: the field takes only hardware keys.
  static const TextInputType none = TextInputType._(10);

  /// A web search query.
  static const TextInputType webSearch = TextInputType._(11);

  /// A short social-media post.
  static const TextInputType twitter = TextInputType._(12);

  /// Every kind, in [index] order.
  static const List<TextInputType> values = <TextInputType>[
    text,
    multiline,
    number,
    phone,
    datetime,
    emailAddress,
    url,
    visiblePassword,
    name,
    streetAddress,
    none,
    webSearch,
    twitter,
  ];

  static const List<String> _names = <String>[
    'text',
    'multiline',
    'number',
    'phone',
    'datetime',
    'emailAddress',
    'url',
    'visiblePassword',
    'name',
    'streetAddress',
    'none',
    'webSearch',
    'twitter',
  ];

  /// The input method's name for this kind, from the `zwp_text_input_v3`
  /// vocabulary the platform layer speaks.
  ///
  /// A number that admits a decimal separator or a sign is
  /// [ImeContentPurpose.number]; a bare one is [ImeContentPurpose.digits],
  /// which is what a numeric keypad layout is for.
  ImeContentPurpose get imeContentPurpose => switch (index) {
        2 => (decimal ?? false) || (signed ?? false)
            ? ImeContentPurpose.number
            : ImeContentPurpose.digits,
        3 => ImeContentPurpose.phone,
        4 => ImeContentPurpose.datetime,
        5 => ImeContentPurpose.email,
        6 => ImeContentPurpose.url,
        8 => ImeContentPurpose.name,
        _ => ImeContentPurpose.normal,
      };

  /// Flutter's wire form of this kind.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': 'TextInputType.${_names[index]}',
        'signed': signed,
        'decimal': decimal,
      };

  @override
  bool operator ==(Object other) =>
      other is TextInputType &&
      other.index == index &&
      other.signed == signed &&
      other.decimal == decimal;

  @override
  int get hashCode => Object.hash(index, signed, decimal);

  @override
  String toString() => 'TextInputType(name: TextInputType.${_names[index]}, '
      'signed: $signed, decimal: $decimal)';
}

/// What the action key - Enter on a desktop - means in a field: Flutter's
/// `TextInputAction`.
///
/// On a desktop a field acts on the ones that move focus or finish editing:
/// [next] and [previous] move focus through the tab order, [newline] in a
/// text area inserts a line break, and every other value finishes editing and
/// gives focus up. See `TextField.textInputAction`. The rest of the values are
/// labels for an on-screen keyboard's action key and are carried as given.
enum TextInputAction {
  none,
  unspecified,
  done,
  go,
  search,
  send,
  next,
  previous,
  continueAction,
  join,
  route,
  emergencyCall,
  newline,
}

/// How a soft keyboard should capitalise what is typed - Flutter's
/// `TextCapitalization`.
///
/// A hint and not a transformation, as on Flutter's desktop embedders: the
/// field never changes the case of a typed character. It reaches the input
/// method as a content hint ([imeContentHint]).
enum TextCapitalization {
  /// The first letter of each word.
  words,

  /// The first letter of each sentence.
  sentences,

  /// Every character.
  characters,

  /// No capitalisation.
  none;

  /// The input-method hint this asks for, or null for [none].
  ImeContentHint? get imeContentHint => switch (this) {
        words => ImeContentHint.titlecase,
        sentences => ImeContentHint.autoCapitalization,
        characters => ImeContentHint.uppercase,
        none => null,
      };
}
