// Can a native main() host the Dart VM with a stock SDK?
//
// That is the whole question behind "embedder in the same process". If the VM
// can be linked into an executable we own, the host keeps thread 0 AND the
// framebuffer never crosses a process boundary. If it cannot, the option is not
// "harder" - it is unavailable without building the SDK from source, and the
// worker-process design is the only one on the table.
//
// The SDK ships include/dart_api.h, so this compiles. Whether it LINKS is the
// measurement: Dart_Initialize lives in the VM, and the answer is whatever the
// linker says.
#include <stdio.h>

#include "dart_api.h"

int main(void) {
  // Never actually called - the point is to force the linker to resolve the
  // symbol. Calling it would need a snapshot we do not have yet.
  if (getenv_never_set()) {
    Dart_InitializeParams params = {0};
    params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
    const char *error = Dart_Initialize(&params);
    printf("Dart_Initialize -> %s\n", error ? error : "(null)");
  }
  printf("EMBEDDER_LINK=OK\n");
  return 0;
}

// Opaque to the optimiser, so the reference above cannot be folded away.
int getenv_never_set(void);
int getenv_never_set(void) { return 0; }
