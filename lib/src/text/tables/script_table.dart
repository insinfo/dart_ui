// GENERATED FILE - DO NOT EDIT.
//
// Source:     referencias/unicode/ucd.nounihan.flat.xml
// UCD:        17.0.0
// Regenerate: dart run tool/generate_unicode_tables.dart

/// Script (`sc`) and Script_Extensions (`scx`), UAX #24.
///
/// Script is what turns a string into runs a shaper can act on. Nothing else in
/// the text stack can: `cmap` says which glyphs a font has, not which language
/// system to shape them with, and a shaper handed Arabic text under the `latn`
/// script tag applies no joining and no mark positioning and draws a row of
/// disconnected isolated forms - text that is legible to no one.
///
/// ## Two properties, not one
///
/// [scriptOf] answers Script, which is a single value per code point and is
/// `Zyyy` (Common) or `Zinh` (Inherited) for everything shared between scripts:
/// digits, punctuation, most combining marks. Those two values are not answers,
/// they are "ask the context", which is why itemization in `script.dart` exists
/// at all.
///
/// [scriptExtensionsOf] answers Script_Extensions, the set of scripts a shared
/// character actually occurs in. U+0640 ARABIC TATWEEL has Script=Common but
/// Script_Extensions={Adlm, Arab, Mand, Mani, Ougr, Phlp, Rohg, Sogd, Syrc},
/// which is what lets an itemizer refuse to hand it to a Latin run. For a code
/// point whose Script is a real script the set is that one script, so the two
/// functions agree and a caller can use the set unconditionally.
///
/// ## Coverage
///
/// Total over U+0000..U+10FFFF. Unassigned code points read as `Zzzz`
/// (Unknown), which is a real value rather than a failure: an itemizer treats
/// it as its own script, so a code point assigned after 17.0.0
/// becomes its own run and is shaped with the default script rather than being
/// silently swept into whatever ran before it.
library;

import 'packed_table.dart';

/// A Unicode script, named by its ISO 15924 code in lower case.
///
/// The member order is the one the generated table encodes. Reordering the
/// members silently re-labels every code point, so the enum and the table
/// are generated together and have to be regenerated together.
///
/// The three values that are not scripts are spelled the same way as the
/// rest: [Script.zyyy] is Common, [Script.zinh] is Inherited and
/// [Script.zzzz] is Unknown.
enum Script {
  adlm('Adlm'),
  aghb('Aghb'),
  ahom('Ahom'),
  arab('Arab'),
  armi('Armi'),
  armn('Armn'),
  avst('Avst'),
  bali('Bali'),
  bamu('Bamu'),
  bass('Bass'),
  batk('Batk'),
  beng('Beng'),
  berf('Berf'),
  bhks('Bhks'),
  bopo('Bopo'),
  brah('Brah'),
  brai('Brai'),
  bugi('Bugi'),
  buhd('Buhd'),
  cakm('Cakm'),
  cans('Cans'),
  cari('Cari'),
  cham('Cham'),
  cher('Cher'),
  chrs('Chrs'),
  copt('Copt'),
  cpmn('Cpmn'),
  cprt('Cprt'),
  cyrl('Cyrl'),
  deva('Deva'),
  diak('Diak'),
  dogr('Dogr'),
  dsrt('Dsrt'),
  dupl('Dupl'),
  egyp('Egyp'),
  elba('Elba'),
  elym('Elym'),
  ethi('Ethi'),
  gara('Gara'),
  geor('Geor'),
  glag('Glag'),
  gong('Gong'),
  gonm('Gonm'),
  goth('Goth'),
  gran('Gran'),
  grek('Grek'),
  gujr('Gujr'),
  gukh('Gukh'),
  guru('Guru'),
  hang('Hang'),
  hani('Hani'),
  hano('Hano'),
  hatr('Hatr'),
  hebr('Hebr'),
  hira('Hira'),
  hluw('Hluw'),
  hmng('Hmng'),
  hmnp('Hmnp'),
  hung('Hung'),
  ital('Ital'),
  java('Java'),
  kali('Kali'),
  kana('Kana'),
  kawi('Kawi'),
  khar('Khar'),
  khmr('Khmr'),
  khoj('Khoj'),
  kits('Kits'),
  knda('Knda'),
  krai('Krai'),
  kthi('Kthi'),
  lana('Lana'),
  laoo('Laoo'),
  latn('Latn'),
  lepc('Lepc'),
  limb('Limb'),
  lina('Lina'),
  linb('Linb'),
  lisu('Lisu'),
  lyci('Lyci'),
  lydi('Lydi'),
  mahj('Mahj'),
  maka('Maka'),
  mand('Mand'),
  mani('Mani'),
  marc('Marc'),
  medf('Medf'),
  mend('Mend'),
  merc('Merc'),
  mero('Mero'),
  mlym('Mlym'),
  modi('Modi'),
  mong('Mong'),
  mroo('Mroo'),
  mtei('Mtei'),
  mult('Mult'),
  mymr('Mymr'),
  nagm('Nagm'),
  nand('Nand'),
  narb('Narb'),
  nbat('Nbat'),
  newa('Newa'),
  nkoo('Nkoo'),
  nshu('Nshu'),
  ogam('Ogam'),
  olck('Olck'),
  onao('Onao'),
  orkh('Orkh'),
  orya('Orya'),
  osge('Osge'),
  osma('Osma'),
  ougr('Ougr'),
  palm('Palm'),
  pauc('Pauc'),
  perm('Perm'),
  phag('Phag'),
  phli('Phli'),
  phlp('Phlp'),
  phnx('Phnx'),
  plrd('Plrd'),
  prti('Prti'),
  rjng('Rjng'),
  rohg('Rohg'),
  runr('Runr'),
  samr('Samr'),
  sarb('Sarb'),
  saur('Saur'),
  sgnw('Sgnw'),
  shaw('Shaw'),
  shrd('Shrd'),
  sidd('Sidd'),
  sidt('Sidt'),
  sind('Sind'),
  sinh('Sinh'),
  sogd('Sogd'),
  sogo('Sogo'),
  sora('Sora'),
  soyo('Soyo'),
  sund('Sund'),
  sunu('Sunu'),
  sylo('Sylo'),
  syrc('Syrc'),
  tagb('Tagb'),
  takr('Takr'),
  tale('Tale'),
  talu('Talu'),
  taml('Taml'),
  tang('Tang'),
  tavt('Tavt'),
  tayo('Tayo'),
  telu('Telu'),
  tfng('Tfng'),
  tglg('Tglg'),
  thaa('Thaa'),
  thai('Thai'),
  tibt('Tibt'),
  tirh('Tirh'),
  tnsa('Tnsa'),
  todr('Todr'),
  tols('Tols'),
  toto('Toto'),
  tutg('Tutg'),
  ugar('Ugar'),
  vaii('Vaii'),
  vith('Vith'),
  wara('Wara'),
  wcho('Wcho'),
  xpeo('Xpeo'),
  xsux('Xsux'),
  yezi('Yezi'),
  yiii('Yiii'),
  zanb('Zanb'),
  zinh('Zinh'),
  zyyy('Zyyy'),
  zzzz('Zzzz');

  const Script(this.code);

  /// The ISO 15924 four-letter code, capitalised as the UCD writes it.
  final String code;

  /// Whether this is Common or Inherited - a value that defers to context
  /// rather than naming a script.
  bool get isContextual => this == Script.zyyy || this == Script.zinh;
}

final RangeTable _scripts = RangeTable(_scriptTable);
final RangeTable _extensionIndex = RangeTable(_scriptExtensionIndexTable);
final SetTable _extensionSets = SetTable(_extensionIndex, _scriptExtensionSets);

List<List<Script>>? _extensionCache;

/// The Script of [codePoint].
Script scriptOf(int codePoint) => Script.values[_scripts.lookup(codePoint)];

/// The Script_Extensions of [codePoint], ascending by enum index.
///
/// Never empty: a code point with no extensions of its own reports the set
/// containing its own Script. The returned list is a shared, unmodifiable view
/// and is not rebuilt per call, so this is safe to call once per character.
List<Script> scriptExtensionsOf(int codePoint) =>
    (_extensionCache ??= _buildExtensionCache())[_extensionIndex.lookup(
      codePoint,
    )];

/// Whether [script] is among the Script_Extensions of [codePoint].
///
/// A linear scan of a set that is almost always one element and never more than
/// a few dozen, which beats building a `Set` per code point.
bool hasScriptExtension(int codePoint, Script script) {
  final List<Script> set = scriptExtensionsOf(codePoint);
  for (int i = 0; i < set.length; i++) {
    if (set[i] == script) return true;
  }
  return false;
}

List<List<Script>> _buildExtensionCache() => List<List<Script>>.generate(
      _extensionSets.length,
      (int i) => List<Script>.unmodifiable(
        _extensionSets[i].map((int value) => Script.values[value]),
      ),
      growable: false,
    );

/// Script for the whole code space. 1717 runs.
const String _scriptTable =
    'AtFhCpCatFGpCatFvBpCBtFPpCBtFFpCXtFBpCftFBpChOtFnBpCFtFFOCtFUsFwDtBEtF'
    'BtBDuFCtBEtFBtBBuFEtBBtFBtBBtFBtBDuFBtBBuFBtBUuFBtB/BZOtBQclEsFCcpFuFB'
    'FmBuFCFyBuFCFDuFB1B3BuFI1BbuFE1BGuFLDFtFBDGtFBDOtFBDDtFBDgBtFBDKsFLDas'
    'FBDsDtFBDiBtEOuFBtE8BuFCtEDDwB5EyBuFOmD7BuFCmDD8DuBuFC8DPuFBzCcuFCzCBu'
    'FBtELuFFDiBuFFDrCtFBDddxCsFEdPtFCdaLEuFBLIuFCLCuFCLWuFBLHuFBLBuFDLEuFC'
    'LJuFCLCuFCLEuFILBuFELCuFBLFuFCLZuFCwBDuFBwBGuFEwBCuFCwBWuFBwBHuFBwBCuF'
    'BwBCuFBwBCuFCwBBuFBwBFuFEwBCuFCwBDuFDwBBuFHwBEuFBwBBuFHwBRuFKuBDuFBuBJ'
    'uFBuBDuFBuBWuFBuBHuFBuBCuFBuBFuFCuBKuFBuBDuFBuBDuFCuBBuFPuBEuFCuBMuFHu'
    'BHuFBsDDuFBsDIuFCsDCuFCsDWuFBsDHuFBsDCuFBsDFuFCsDJuFCsDCuFCsDDuFHsDDuF'
    'EsDCuFBsDFuFCsDSuFKyECuFByEGuFDyEDuFByEEuFDyECuFByEBuFByECuFDyECuFDyED'
    'uFDyEMuFEyEFuFDyEDuFByEEuFCyEBuFGyEBuFOyEVuFF2ENuFB2EDuFB2EXuFB2EQuFC2'
    'EJuFB2EDuFB2EEuFH2ECuFB2EDuFB2ECuFC2EEuFC2EKuFH2EJkCNuFBkCDuFBkCXuFBkC'
    'KuFBkCFuFCkCJuFBkCDuFBkCEuFHkCCuFFkCDuFBkCEuFCkCKuFBkCDuFM6CNuFB6CDuFB'
    '6CzBuFB6CDuFB6CGuFE6CQuFC6CauFBlEDuFBlESuFDlEYuFBlEJuFBlEBuFClEHuFDlEB'
    'uFElEGuFBlEBuFBlEIuFGlEKuFClEDuFM6E6BuFEtFB6EcuFlBoCCuFBoCBuFBoCFuFBoC'
    'YuFBoCBuFBoCXuFCoCFuFBoCBuFBoCHuFBoCKuFCoCEuFgB7EoCuFB7EkBuFE7EnBuFB7E'
    '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'
    'yBqpIuFn8yVtFBuFetFgDuFgEsFwHuF';

/// The Script_Extensions set number of every code point.
/// 1882 runs over 284 distinct sets.
const String _scriptExtensionIndexTable =
    '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';

/// The Script_Extensions sets themselves, as [Script] indices.
const String _scriptExtensionSets =
    '8I+VBACADIADmBmD6DtE5EpFDAD6BJADzC0CvD1D6DmEtEBBLBXZcrBtBpCtDtE3E+EHBX'
    'rBpCrEtE6EDBpC+EBCBDCDZHDmBmD6DtE5EpFCDmDCD6DCDtEDDtE5ECD5EDD5EpFBEBFL'
    'FchBrBtB1BpCyDtEwE3EDFnBoBBGQGVZhBjBnBoBpBrBtByBpCwCxCyDgEHGVnB6BmCwC8'
    'DCGrDBHBIBJBKBLDLTsEHLcdpCuC6EgFCLdXLdfpBqBsBuBvBwBkCrCxC6CiDqDsDkElEs'
    'EvEyE2E8EVLdfpBqBsBuBwBkCxC6CiDqDsDkElEsEvEyE2E8EPLdsBuBwBkCpC6CiDlDsD'
    'hEyE2E8ENLdsBuBwBkCpC6ClDsDyE2E8EELdsBkCLLdsBkC6CiDsDlE2E8EhFELdlDhEEL'
    'dlD2EFLdlD2E8EDLdhEDLd2EDLdhFBMBNBOFOxByB2B+BJOxByB2B+BuC8C7EqFIOxByB2'
    'B+B8CzDqFIOxByB2B+B8C7EqFHOxByB2B+B8CqFGOxByB2B+BqFCOyBCOpCBPBQBRCR8BB'
    'SESzBuE4EBTDTgDwEBUBVGVnBoB6BvCrDEVtB6B5CBWBXIXZctBpCyDrEwEIXctBpCtDrE'
    'wE+EEXcpCtDEXcpC3EGXhB+BpCtE3EEXhBpCtEDXpCtEDXpCwEBYBZJZhB1BpCyDtEwE3E'
    '+EGZjBoBrB+BpCCZtBCZpCBaDabtCBbDbsCtCCbtCBcCcoBFctBpCyD3ECcpCDcpCtEDcp'
    'C+ECcyDBdQdfuBwBiCkCmCxC6C7CiDhEkEvE8EhFPdfuBwBiCkCmCxC7CiDhEkEvE8EhFM'
    'dfuBwBiCmCxC7ChEkEvE8ELdfuBwBiCmCxC7CkEvE8EEdfmCxCCdsBDdsBkCEdsBkChFDd'
    'sBpCGdkC6CsDyE2EDdiDlDCdlDDdlDhEDdlD8ECdhECdyEBeBfBgBBhBDhBpCtEBiBBjBB'
    'kBBlBClBpCBmBBnBDnBoBpCBoBFoBpCrEtE6EBpBBqBBrBBsBCsByEBtBEtBpCyD+EBuBC'
    'uBiCBvBBwBCwB/CBxBByBDyB2B+BCyBpCCyBzEBzBB0BB1BB2BC2B+BB3BB4BB5BB6BB7B'
    'B8BB9BD9BpCgDB+BB/BBgCBhCBiCBjCBkCDkCiDhFBlCBmCBnCBoCBpCCpCuCDpC8CzDCp'
    'CtDCpCrEDpCrEtECpCtECpC3ECpC6EBqCBrCBsCBtCBuCBvCBwCBxCByCBzCB0CC0CvDB1'
    'CB2CB3CB4CB5CB6CB7CB8CC8CzDB9CB+CB/CBgDBhDBiDBjDBkDBlDBmDBnDBoDBpDBqDB'
    'rDBsDBtDBuDBvDBwDBxDByDBzDB0DB1DB2DB3DB4DB5DB6DB7DB8DB9DB+DB/DBgEBhEBi'
    'EBjEBkEBlEBmEBnEBoEBpEBqEBrEBsEBtEBuEBvEBwEBxEByEBzEB0EB1EB2EB3EB4EB5E'
    'B6EB7EB8EB9EB+EB/EBgFBhFBiFBjFBkFBlFBmFBnFBoFBpFBqFBrFBsFBtFBuF';
