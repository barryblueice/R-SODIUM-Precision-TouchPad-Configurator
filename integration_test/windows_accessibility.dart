import 'dart:ffi';
import 'dart:io';

// Request the native accessibility provider as a screen reader would.
// ensureSemantics() alone enables the Dart tree, not the Windows AX bridge.
void enableWindowsAccessibility() {
  final user = DynamicLibrary.open('user32.dll');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  final allocate = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  final process = allocate(heap, 8, 4).cast<Uint32>();
  if (process == nullptr) throw StateError('HeapAlloc failed');
  final getProcess = user
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final send = user
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Uint32, IntPtr, IntPtr),
        int Function(Pointer<Void>, int, int, int)
      >('SendMessageW');
  final enumerate = user
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<NativeFunction<Int32 Function(Pointer<Void>, IntPtr)>>,
          IntPtr,
        ),
        int Function(
          Pointer<Void>,
          Pointer<NativeFunction<Int32 Function(Pointer<Void>, IntPtr)>>,
          int,
        )
      >('EnumChildWindows');
  final topLevel = user
      .lookupFunction<
        Int32 Function(
          Pointer<NativeFunction<Int32 Function(Pointer<Void>, IntPtr)>>,
          IntPtr,
        ),
        int Function(
          Pointer<NativeFunction<Int32 Function(Pointer<Void>, IntPtr)>>,
          int,
        )
      >('EnumWindows');
  var windows = 0;
  final child =
      NativeCallable<Int32 Function(Pointer<Void>, IntPtr)>.isolateLocal((
        Pointer<Void> hwnd,
        int data,
      ) {
        send(hwnd, 0x003D, 0, -4); // WM_GETOBJECT / OBJID_CLIENT
        windows++;
        return 1;
      }, exceptionalReturn: 0);
  final parent =
      NativeCallable<Int32 Function(Pointer<Void>, IntPtr)>.isolateLocal((
        Pointer<Void> hwnd,
        int data,
      ) {
        getProcess(hwnd, process);
        if (process.value == pid) enumerate(hwnd, child.nativeFunction, 0);
        return 1;
      }, exceptionalReturn: 0);
  try {
    topLevel(parent.nativeFunction, 0);
    if (windows == 0) throw StateError('No Flutter child window found');
  } finally {
    parent.close();
    child.close();
    free(heap, 0, process.cast());
  }
}
