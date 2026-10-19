/// The logical key codes - what a `KeyEvent.logicalKey` holds.
///
/// In the platform layer because they are the backends' numbering, not a
/// widget's: a shortcut, a command and an engine with no window name keys.
library;

/// Virtual-key codes the framework interprets itself.
///
/// These are the Windows virtual-key values, which every backend normalizes
/// to; a physical-to-logical key table is a Fase 7 concern, and inventing a
/// second numbering before that table exists would only have to be undone.
const int logicalKeyBackspace = 0x08;
const int logicalKeyTab = 0x09;
const int logicalKeyEnter = 0x0D;
const int logicalKeyEscape = 0x1B;
const int logicalKeySpace = 0x20;
const int logicalKeyEnd = 0x23;
const int logicalKeyHome = 0x24;
const int logicalKeyArrowLeft = 0x25;
const int logicalKeyArrowUp = 0x26;
const int logicalKeyArrowRight = 0x27;
const int logicalKeyArrowDown = 0x28;
const int logicalKeyDelete = 0x2E;
const int logicalKeyPageUp = 0x21;
const int logicalKeyPageDown = 0x22;
const int logicalKeyInsert = 0x2D;

/// OEM comma key, normalized to the same value on every backend.
const int logicalKeyComma = 0xBC;

/// Letters and digits are their uppercase ASCII codes, as virtual keys are.
const int logicalKeyA = 0x41;
const int logicalKeyB = 0x42;
const int logicalKeyC = 0x43;
const int logicalKeyD = 0x44;
const int logicalKeyE = 0x45;
const int logicalKeyF = 0x46;
const int logicalKeyG = 0x47;
const int logicalKeyH = 0x48;
const int logicalKeyI = 0x49;
const int logicalKeyJ = 0x4A;
const int logicalKeyK = 0x4B;
const int logicalKeyL = 0x4C;
const int logicalKeyM = 0x4D;
const int logicalKeyN = 0x4E;
const int logicalKeyO = 0x4F;
const int logicalKeyP = 0x50;
const int logicalKeyQ = 0x51;
const int logicalKeyR = 0x52;
const int logicalKeyS = 0x53;
const int logicalKeyT = 0x54;
const int logicalKeyU = 0x55;
const int logicalKeyV = 0x56;
const int logicalKeyW = 0x57;
const int logicalKeyX = 0x58;
const int logicalKeyY = 0x59;
const int logicalKeyZ = 0x5A;
const int logicalKeyDigit0 = 0x30;
const int logicalKeyDigit1 = 0x31;
const int logicalKeyDigit2 = 0x32;
const int logicalKeyDigit3 = 0x33;
const int logicalKeyDigit4 = 0x34;
const int logicalKeyDigit5 = 0x35;
const int logicalKeyDigit6 = 0x36;
const int logicalKeyDigit7 = 0x37;
const int logicalKeyDigit8 = 0x38;
const int logicalKeyDigit9 = 0x39;

/// Function keys F1 to F12.
const int logicalKeyF1 = 0x70;
const int logicalKeyF2 = 0x71;
const int logicalKeyF3 = 0x72;
const int logicalKeyF4 = 0x73;
const int logicalKeyF5 = 0x74;
const int logicalKeyF6 = 0x75;
const int logicalKeyF7 = 0x76;
const int logicalKeyF8 = 0x77;
const int logicalKeyF9 = 0x78;
const int logicalKeyF10 = 0x79;
const int logicalKeyF11 = 0x7A;
const int logicalKeyF12 = 0x7B;
