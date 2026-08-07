import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Minimal hand-written Win32 bindings.
///
/// Deliberately self-contained: this POC measures runtime behaviour, so it
/// avoids depending on a binding package whose version could change what is
/// being measured.
const int qsAllInput = 0x04FF;
const int mwmoInputAvailable = 0x0004;
const int pmRemove = 0x0001;
const int waitObject0 = 0x0000;
const int waitTimeout = 0x0102;
const int waitFailed = 0xFFFFFFFF;
const int infinite = 0xFFFFFFFF;

/// `MSG`, laid out by the Dart FFI ABI rules for the host platform.
final class Msg extends Struct {
  external Pointer<Void> hwnd;

  @Uint32()
  external int message;

  @UintPtr()
  external int wParam;

  @IntPtr()
  external int lParam;

  @Uint32()
  external int time;

  @Int32()
  external int ptX;

  @Int32()
  external int ptY;
}

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');

/// `timeBeginPeriod` raises the global system timer resolution. It is a
/// process-wide *and* system-wide change with a real power cost, which is why
/// a UI framework should not be forced to call it just to compensate for a
/// missing scheduling API.
final int Function(int) timeBeginPeriod =
    _winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
  'timeBeginPeriod',
);

final int Function(int) timeEndPeriod =
    _winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>(
  'timeEndPeriod',
);

final int Function(int, Pointer<IntPtr>, int, int, int)
    msgWaitForMultipleObjectsEx = _user32.lookupFunction<
        Uint32 Function(Uint32, Pointer<IntPtr>, Uint32, Uint32, Uint32),
        int Function(int, Pointer<IntPtr>, int, int, int)>(
  'MsgWaitForMultipleObjectsEx',
);

final int Function(Pointer<Msg>, Pointer<Void>, int, int, int) peekMessage =
    _user32.lookupFunction<
        Int32 Function(Pointer<Msg>, Pointer<Void>, Uint32, Uint32, Uint32),
        int Function(Pointer<Msg>, Pointer<Void>, int, int, int)>(
  'PeekMessageW',
);

final int Function(Pointer<Msg>) translateMessage = _user32
    .lookupFunction<Int32 Function(Pointer<Msg>), int Function(Pointer<Msg>)>(
  'TranslateMessage',
);

final int Function(Pointer<Msg>) dispatchMessage = _user32
    .lookupFunction<IntPtr Function(Pointer<Msg>), int Function(Pointer<Msg>)>(
  'DispatchMessageW',
);

final int Function(Pointer<Int64>) queryPerformanceCounter =
    _kernel32.lookupFunction<Int32 Function(Pointer<Int64>),
        int Function(Pointer<Int64>)>('QueryPerformanceCounter');

final int Function(Pointer<Int64>) queryPerformanceFrequency =
    _kernel32.lookupFunction<Int32 Function(Pointer<Int64>),
        int Function(Pointer<Int64>)>('QueryPerformanceFrequency');

final int Function(Pointer<Void>, int, int, Pointer<Utf16>) createEvent =
    _kernel32.lookupFunction<
        IntPtr Function(Pointer<Void>, Int32, Int32, Pointer<Utf16>),
        int Function(Pointer<Void>, int, int, Pointer<Utf16>)>('CreateEventW');

final int Function(int) setEvent = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetEvent');

final int Function(int) closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final int Function() getCurrentProcess = _kernel32
    .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');

final int Function() getCurrentThreadId = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');

final int Function(int, Pointer<Uint64>) queryProcessCycleTime =
    _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>)>('QueryProcessCycleTime');

final int Function(
        int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
    getProcessTimes = _kernel32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>)>('GetProcessTimes');
