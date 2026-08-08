// Backend 3 - the minimal Objective-C host that owns thread 0 by definition.
//
// main() is native, so NSApplication gets the first thread of the process the
// way AppKit requires. Dart runs as a worker on the other side of a stdin/
// stdout protocol. Loading a .m as a dylib from the Dart executable would NOT
// give the same guarantee: the code would still not own thread 0.
//
// Protocol version 2 adds the two pieces the conformance suite needs:
//   * FRAME <w> <h> <bytes>\n followed by exactly <bytes> raw BGRA octets,
//     so a real CPU framebuffer crosses the process boundary (base64 would
//     inflate a 480x320 frame past any sane line buffer);
//   * INPUT= lines, so NSEvents the host dequeues reach Dart.
//
// Protocol version 3 adds the two transports that skip the pipe for pixels, so
// the cost of the process boundary can be measured instead of argued about:
//   * SHM <name> <bytes> maps a POSIX shared segment read-only, and
//     PRESENT <seq> <w> <h> wraps those same pages in a CGImage;
//   * SURFACE <id> looks up an IOSurface, and PRESENT <seq> hands it to the
//     layer once - later frames only mark the contents changed, because the
//     compositor is already scanning out those pages.
// FRAME stays in for comparison: it is the only one that copies.
//
// SURFACE <id> is the deprecated global-surface path (kIOSurfaceIsGlobal +
// IOSurfaceLookup). The supported replacement is IOSurfaceLookupFromMachPort,
// and the hard part is not the surface API: a mach port right cannot travel
// through a pipe, so the port has to arrive some other way. Three ways are
// implemented, because which of them a plain unsigned command-line binary is
// still allowed to use on macOS 14/15 is exactly what this spike is measuring:
//
//   * PORT_SERVER <name> checks a receive right in with launchd under <name>.
//     The parent can then look that name up and send the host a message. This
//     is the direction that costs nothing to try: the child publishes, the
//     parent looks up, and no port has to cross before the channel exists.
//   * SURFACE_PORT REGISTERED <slot> reads slot <slot> of this task's
//     registered-port array (mach_ports_lookup). The parent put the surface
//     port there before spawning; the kernel copies the array into every child
//     task. libxpc is documented to overwrite that array from its atfork
//     handler, so this may well come back empty - the command reports the
//     whole array so an empty slot can be told apart from a port that never
//     arrived.
//   * SURFACE_PORT BOOTSTRAP <name> looks <name> up in the bootstrap
//     namespace, where the parent published the surface port itself with the
//     long-deprecated bootstrap_register.
//   * SURFACE_PORT RENDEZVOUS waits on the PORT_SERVER port for one message
//     carrying the surface port. This is the only one of the three with no
//     ordering constraint - the parent can hand over a new surface at any
//     time, which is what a resize needs.
//
// All of them end in IOSurfaceLookupFromMachPort and print
// SURFACE_PORT_OK <mechanism> <WxH>; every failure prints
// ERROR=SURFACE_PORT:<mechanism>:<stage>:<kern_return_t> and returns, because
// this host cannot be run on the machine it is written on and a log line is
// the only debugger available. SURFACE <id> is deliberately
// left in place as the fallback - none of this is proven until CI says so -
// and PRESENT tags the transport "surface-port" instead of "surface" once a
// port mechanism won, so a benchmark cannot measure the fallback and report it
// as the new path.
//
// PROTOCOL stays at 3 on purpose: existing clients compare that line for
// equality, and adding a command does not invalidate any of them. The new
// surface is advertised separately as PROTOCOL_FEATURES.
//
// Input is reported twice on purpose. The local NSEvent monitor sees every
// event the application dequeues and is the gate; VIEW_INPUT= comes from the
// responder chain and proves the event was routed to a view, not merely
// received.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// -setContentsChanged is CALayer's private "the pages under this surface moved
// on, re-read them" call, and it is how every compositor drives an IOSurface
// layer. Declaring it here only satisfies the compiler; the code still checks
// respondsToSelector: at runtime and falls back to the public reassignment, and
// reports which path ran so the benchmark cannot silently measure the wrong one.
@interface CALayer (DartUiContentsChanged)
- (void)setContentsChanged;
@end

// The one message shape the rendezvous channel accepts: a complex message
// carrying exactly one port descriptor plus a token the parent echoes back, so
// a message from something other than our parent is rejected on content rather
// than assumed to be the surface.
typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint32_t token;
} DartUiSurfaceMessage;

// mach_msg appends a trailer of a size the kernel chooses; the receive buffer
// has to have room for the largest one or the receive fails with
// MACH_RCV_TOO_LARGE and the message is dropped.
typedef struct {
  DartUiSurfaceMessage message;
  mach_msg_max_trailer_t trailer;
} DartUiSurfaceMessageBuffer;

static const mach_msg_id_t kDartUiSurfaceMessageId = 0x64756930;  // 'dui0'

// mach_ports_lookup has been deprecated since 10.5 and has moved between
// headers more than once. Resolving it at runtime means a missing symbol is a
// diagnostic line instead of a build failure - and this file cannot be built
// on the machine it is written on, so a build failure costs a whole CI round
// trip.
typedef kern_return_t (*DartUiMachPortsLookup)(task_t, mach_port_array_t *,
                                               mach_msg_type_number_t *);

@interface DartUiHostView : NSView
@end

@implementation DartUiHostView

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (void)reportEvent:(NSString *)kind of:(NSEvent *)event {
  NSPoint point = event.locationInWindow;
  printf("VIEW_INPUT=%s:%.0f:%.0f\n", kind.UTF8String, point.x, point.y);
  fflush(stdout);
}

- (void)keyDown:(NSEvent *)event {
  [self reportEvent:@"keyDown" of:event];
}

- (void)keyUp:(NSEvent *)event {
  [self reportEvent:@"keyUp" of:event];
}

- (void)mouseDown:(NSEvent *)event {
  [self reportEvent:@"pointerDown" of:event];
}

- (void)mouseUp:(NSEvent *)event {
  [self reportEvent:@"pointerUp" of:event];
}

- (void)mouseMoved:(NSEvent *)event {
  [self reportEvent:@"pointerMove" of:event];
}

@end

@interface DartUiMinimalAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) DartUiHostView *hostView;
@property(nonatomic, strong) id eventMonitor;
@property(nonatomic, assign) NSTimeInterval smokeDuration;
@property(nonatomic, assign) BOOL commandStdin;
@property(nonatomic, assign) NSUInteger frameCount;
// Transport 2: a shared mapping plus the one data provider that covers it. The
// provider is built once, not per frame - that is the whole point.
@property(nonatomic, assign) void *shmMapping;
@property(nonatomic, assign) size_t shmLength;
@property(nonatomic, assign) CGDataProviderRef shmProvider;
// Transport 3: the surface the compositor can scan out directly.
@property(nonatomic, assign) IOSurfaceRef surface;
@property(nonatomic, assign) BOOL surfaceAttached;
// A pool, for double buffering. Presenting alternating surfaces is what lets
// the client write into one while the compositor is still reading the other -
// the single-surface path measured a 3.3ms window per frame in which a write
// can land mid-scan-out.
@property(nonatomic, assign) IOSurfaceRef *surfacePool;
@property(nonatomic, assign) NSUInteger surfacePoolCount;
@property(nonatomic, assign) NSInteger presentedSlot;
// nil while the surface came from the deprecated IOSurfaceLookup, otherwise
// the name of the mach-port mechanism that delivered it. PRESENT reads this,
// so the transport a benchmark measures is the transport it reports.
@property(nonatomic, copy) NSString *surfacePortOrigin;
// The receive right PORT_SERVER checked in, kept for RENDEZVOUS.
@property(nonatomic, assign) mach_port_t machServicePort;
@property(nonatomic, copy) NSString *machServiceName;
@end

@implementation DartUiMinimalAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

  NSRect frame = NSMakeRect(200.0, 200.0, 480.0, 320.0);
  NSWindowStyleMask style = NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable;
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:style
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.title = @"dart_ui minimal AppKit host";
  self.hostView = [[DartUiHostView alloc]
      initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, frame.size.height)];
  self.hostView.wantsLayer = YES;
  self.hostView.layer.backgroundColor =
      [NSColor colorWithRed:0.10 green:0.45 blue:0.85 alpha:1.0].CGColor;
  // The layer must not resample the frame, or the witness reads a blend of
  // neighbouring pixels instead of the pixel that was sent.
  self.hostView.layer.magnificationFilter = kCAFilterNearest;
  self.hostView.layer.minificationFilter = kCAFilterNearest;
  self.window.contentView = self.hostView;
  self.window.acceptsMouseMovedEvents = YES;
  [self.window makeKeyAndOrderFront:nil];
  [self.window makeFirstResponder:self.hostView];
  [NSApp activateIgnoringOtherApps:YES];

  [self installEventMonitor];

  printf("MAIN_THREAD=%d\n", [NSThread isMainThread] ? 1 : 0);
  printf("WINDOW_ID=%ld\n", (long)self.window.windowNumber);
  printf("PROTOCOL=3\n");
  // Separate line, because clients compare PROTOCOL= for equality and a new
  // command must not make an old client think it is talking to a stranger.
  printf("PROTOCOL_FEATURES=surface-port\n");
  printf("HOST_PID=%d\n", (int)getpid());
  fflush(stdout);

  if (self.commandStdin) {
    [self startCommandReader];
  }

  if (self.smokeDuration > 0) {
    [NSTimer scheduledTimerWithTimeInterval:self.smokeDuration
                                     target:NSApp
                                   selector:@selector(terminate:)
                                   userInfo:nil
                                    repeats:NO];
  }
}

- (void)installEventMonitor {
  NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp |
                     NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
                     NSEventMaskMouseMoved | NSEventMaskScrollWheel;
  self.eventMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:mask
                                   handler:^NSEvent *(NSEvent *event) {
                                     [self reportMonitoredEvent:event];
                                     return event;
                                   }];
}

- (void)reportMonitoredEvent:(NSEvent *)event {
  const char *kind = "other";
  switch (event.type) {
    case NSEventTypeKeyDown: kind = "keyDown"; break;
    case NSEventTypeKeyUp: kind = "keyUp"; break;
    case NSEventTypeLeftMouseDown: kind = "pointerDown"; break;
    case NSEventTypeLeftMouseUp: kind = "pointerUp"; break;
    case NSEventTypeMouseMoved: kind = "pointerMove"; break;
    case NSEventTypeScrollWheel: kind = "scroll"; break;
    default: break;
  }
  NSPoint point = event.locationInWindow;
  unsigned short keyCode =
      (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp)
          ? event.keyCode
          : 0;
  // mach_absolute_time is system-wide, so a Dart process reading the same clock
  // can subtract these directly: injection -> here is WindowServer plus AppKit,
  // here -> Dart is the process boundary. Without the stamp the two are
  // indistinguishable from either end.
  printf("INPUT=%s:%.0f:%.0f:%u:%llu\n", kind, point.x, point.y,
         (unsigned)keyCode, (unsigned long long)mach_absolute_time());
  fflush(stdout);
}

- (void)startCommandReader {
  __weak DartUiMinimalAppDelegate *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), stdin) != NULL) {
      @autoreleasepool {
        NSString *line = [NSString stringWithUTF8String:buffer];
        line = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet newlineCharacterSet]];
        if ([line hasPrefix:@"FRAME "]) {
          // The payload follows the header on the same stream; read it here,
          // on the reader thread, then hand the finished buffer to main.
          NSData *frame = [weakSelf readFramePayload:line];
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyFrame:frame header:line];
          });
          continue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf handleCommand:line];
        });
      }
    }
  });
}

- (NSData *)readFramePayload:(NSString *)header {
  NSArray<NSString *> *parts = [header componentsSeparatedByString:@" "];
  if (parts.count != 4) return nil;
  long byteCount = [parts[3] integerValue];
  if (byteCount <= 0 || byteCount > 64 * 1024 * 1024) return nil;

  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)byteCount];
  size_t read = fread(data.mutableBytes, 1, (size_t)byteCount, stdin);
  if (read != (size_t)byteCount) return nil;
  return data;
}

- (void)applyFrame:(NSData *)data header:(NSString *)header {
  NSArray<NSString *> *parts = [header componentsSeparatedByString:@" "];
  if (data == nil || parts.count != 4) {
    printf("ERROR=BAD_FRAME\n");
    fflush(stdout);
    return;
  }
  size_t width = (size_t)[parts[1] integerValue];
  size_t height = (size_t)[parts[2] integerValue];
  if (width == 0 || height == 0 || data.length < width * height * 4) {
    printf("ERROR=BAD_FRAME\n");
    fflush(stdout);
    return;
  }

  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(
      width, height, 8, 32, width * 4, colorSpace,
      (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst |
                     kCGBitmapByteOrder32Little),
      provider, NULL, NO, kCGRenderingIntentDefault);
  if (image != NULL) {
    self.hostView.layer.contents = (__bridge id)image;
    [self.hostView.layer setNeedsDisplay];
    [CATransaction flush];
    CGImageRelease(image);
    self.frameCount++;
    printf("FRAME_OK %lu\n", (unsigned long)self.frameCount);
  } else {
    printf("ERROR=FRAME_IMAGE\n");
  }
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);
  fflush(stdout);
}

// --- transport 2: shared memory --------------------------------------------
//
// Map the segment read-only once and build one CGDataProvider over it. Every
// later frame is a CGImageCreate over pages Dart already wrote: no copy
// crosses the process boundary, and only the control line goes through the
// pipe.
- (void)attachSharedMemory:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 3) {
    printf("ERROR=BAD_SHM\n");
    fflush(stdout);
    return;
  }
  const char *name = parts[1].UTF8String;
  size_t length = (size_t)[parts[2] integerValue];
  int fd = shm_open(name, O_RDONLY, 0);
  if (fd < 0) {
    printf("ERROR=SHM_OPEN:%d\n", errno);
    fflush(stdout);
    return;
  }
  void *mapping = mmap(NULL, length, PROT_READ, MAP_SHARED, fd, 0);
  close(fd);
  if (mapping == MAP_FAILED) {
    printf("ERROR=SHM_MMAP:%d\n", errno);
    fflush(stdout);
    return;
  }
  [self releaseSharedMemory];
  self.shmMapping = mapping;
  self.shmLength = length;
  // NULL release callback: the mapping outlives the provider and is unmapped
  // by releaseSharedMemory.
  self.shmProvider = CGDataProviderCreateWithData(NULL, mapping, length, NULL);
  printf("SHM_OK %zu\n", length);
  fflush(stdout);
}

- (void)releaseSharedMemory {
  if (self.shmProvider != NULL) {
    CGDataProviderRelease(self.shmProvider);
    self.shmProvider = NULL;
  }
  if (self.shmMapping != NULL) {
    munmap(self.shmMapping, self.shmLength);
    self.shmMapping = NULL;
    self.shmLength = 0;
  }
}

// --- transport 3: IOSurface -------------------------------------------------
//
// IOSurfaceLookup is the deprecated global-surface path, kept as the fallback.
// The supported replacement, IOSurfaceLookupFromMachPort, is below: the API
// change is trivial, getting the port across the boundary is not.
- (void)attachSurface:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 2) {
    printf("ERROR=BAD_SURFACE\n");
    fflush(stdout);
    return;
  }
  IOSurfaceID surfaceId = (IOSurfaceID)[parts[1] integerValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  IOSurfaceRef surface = IOSurfaceLookup(surfaceId);
#pragma clang diagnostic pop
  if (surface == NULL) {
    printf("ERROR=SURFACE_LOOKUP\n");
    fflush(stdout);
    return;
  }
  if (self.surface != NULL) CFRelease(self.surface);
  self.surface = surface;
  self.surfaceAttached = NO;
  self.surfacePortOrigin = nil;
  printf("SURFACE_OK %u %zux%zu\n", surfaceId, IOSurfaceGetWidth(surface),
         IOSurfaceGetHeight(surface));
  fflush(stdout);
}

// --- transport 3b: the surface arrives as a mach port right ------------------
//
// Everything below converges here. The port is whatever the mechanism dug up;
// this is the only place that turns one into a surface, so a mechanism that
// hands over the wrong port fails the same visible way as one that hands over
// nothing.
- (void)adoptSurfacePort:(mach_port_t)port origin:(NSString *)origin {
  if (!MACH_PORT_VALID(port)) {
    printf("ERROR=SURFACE_PORT:%s:NULL_PORT:0\n", origin.UTF8String);
    fflush(stdout);
    return;
  }
  IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
  if (surface == NULL) {
    // A non-null port that is not an IOSurface port lands here, which is the
    // expected outcome if something else overwrote the slot we were told to
    // read. That is a finding, not a crash.
    printf("ERROR=SURFACE_PORT:%s:LOOKUP_FROM_PORT:0\n", origin.UTF8String);
    fflush(stdout);
    return;
  }
  // The send right is deliberately not deallocated. Apple's own samples do
  // deallocate it, but this host cannot be run locally, and leaking one port
  // name per attach has no failure mode while dropping the last right to a
  // surface the compositor is scanning out has an ugly one.
  if (self.surface != NULL) CFRelease(self.surface);
  self.surface = surface;
  self.surfaceAttached = NO;
  self.surfacePortOrigin = origin;
  printf("SURFACE_PORT_OK %s %zux%zu\n", origin.UTF8String,
         IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface));
  fflush(stdout);
}

// Mechanism (a): the registered-port array the kernel copies into every child
// task at creation. Costs one call and no launchd involvement - if it survives
// the parent's fork it is by far the cheapest of the three.
- (void)attachSurfacePortRegistered:(NSString *)slotText {
  long slot = [slotText integerValue];
  if (slot < 0 || slot > 2) {
    printf("ERROR=SURFACE_PORT:REGISTERED:BAD_SLOT:%ld\n", slot);
    fflush(stdout);
    return;
  }
  DartUiMachPortsLookup lookup =
      (DartUiMachPortsLookup)dlsym(RTLD_DEFAULT, "mach_ports_lookup");
  if (lookup == NULL) {
    printf("ERROR=SURFACE_PORT:REGISTERED:NO_SYMBOL:0\n");
    fflush(stdout);
    return;
  }
  mach_port_array_t ports = NULL;
  mach_msg_type_number_t count = 0;
  kern_return_t status = lookup(mach_task_self(), &ports, &count);
  if (status != KERN_SUCCESS) {
    printf("ERROR=SURFACE_PORT:REGISTERED:PORTS_LOOKUP:%d\n", (int)status);
    fflush(stdout);
    return;
  }
  // The occupancy of the whole array is the actual measurement here: libxpc is
  // documented to overwrite it during fork(), and "slot 0 full, slot 2 empty"
  // says exactly that happened, where a bare failure would not.
  unsigned mask = 0;
  for (mach_msg_type_number_t index = 0; index < count; index++) {
    if (MACH_PORT_VALID(ports[index])) mask |= (1u << index);
  }
  printf("SURFACE_PORT_SLOTS=%u:%u\n", (unsigned)count, mask);
  fflush(stdout);

  mach_port_t port = MACH_PORT_NULL;
  if ((mach_msg_type_number_t)slot < count) port = ports[slot];
  // vm_deallocate frees the array's memory, not the rights it named, so the
  // port we picked stays valid.
  if (ports != NULL) {
    vm_deallocate(mach_task_self(), (vm_address_t)ports,
                  (vm_size_t)(count * sizeof(mach_port_t)));
  }
  [self adoptSurfacePort:port origin:@"registered"];
}

// Mechanism (b): the parent published the surface port under a name with
// bootstrap_register. One call on each side and no message passing at all -
// if launchd still allows the registration.
- (void)attachSurfacePortBootstrap:(NSString *)name {
  if (name.length == 0) {
    printf("ERROR=SURFACE_PORT:BOOTSTRAP:NO_NAME:0\n");
    fflush(stdout);
    return;
  }
  mach_port_t port = MACH_PORT_NULL;
  kern_return_t status =
      bootstrap_look_up(bootstrap_port, (char *)name.UTF8String, &port);
  if (status != KERN_SUCCESS) {
    // 1102 is BOOTSTRAP_UNKNOWN_SERVICE, which is what a refused
    // bootstrap_register in the parent looks like from this side.
    printf("ERROR=SURFACE_PORT:BOOTSTRAP:LOOK_UP:%d\n", (int)status);
    fflush(stdout);
    return;
  }
  [self adoptSurfacePort:port origin:@"bootstrap"];
}

// PORT_SERVER: the host publishes a receive right and the parent looks it up.
// Publishing from the child is what makes the rendezvous work without the
// parent being a launchd job - launchd hands out a fresh receive right for a
// name nobody has claimed, and the name carries our pid so nobody else can.
- (void)startPortServer:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 2 || parts[1].length == 0) {
    printf("ERROR=SURFACE_PORT:PORT_SERVER:BAD_COMMAND:0\n");
    fflush(stdout);
    return;
  }
  NSString *name = parts[1];
  mach_port_t service = MACH_PORT_NULL;
  kern_return_t status =
      bootstrap_check_in(bootstrap_port, (char *)name.UTF8String, &service);
  if (status != KERN_SUCCESS) {
    // 1100 is BOOTSTRAP_NOT_PRIVILEGED - the sandbox denying mach-register.
    // A plain unsigned binary should not see it; if CI does, this mechanism is
    // dead for unentitled processes and the log should say so plainly.
    printf("ERROR=SURFACE_PORT:PORT_SERVER:CHECK_IN:%d\n", (int)status);
    fflush(stdout);
    return;
  }
  self.machServicePort = service;
  self.machServiceName = name;
  printf("PORT_SERVER_OK %s\n", name.UTF8String);
  fflush(stdout);
}

// Mechanism (c): one message on the PORT_SERVER port carrying the surface
// port. The only mechanism with no ordering constraint, because the channel
// outlives any one surface - a resize is another message, not another process.
- (void)attachSurfacePortRendezvous {
  if (!MACH_PORT_VALID(self.machServicePort)) {
    printf("ERROR=SURFACE_PORT:RENDEZVOUS:NO_PORT_SERVER:0\n");
    fflush(stdout);
    return;
  }
  mach_port_t service = self.machServicePort;
  __weak DartUiMinimalAppDelegate *weakSelf = self;
  // A blocking receive holds its thread for the whole timeout, so it never
  // runs on main: AppKit has to keep pumping while the parent gets around to
  // sending, or the window stops responding for five seconds.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    DartUiSurfaceMessageBuffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    mach_msg_return_t status =
        mach_msg(&buffer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                 (mach_msg_size_t)sizeof(buffer), service, 5000,
                 MACH_PORT_NULL);
    if (status != MACH_MSG_SUCCESS) {
      dispatch_async(dispatch_get_main_queue(), ^{
        printf("ERROR=SURFACE_PORT:RENDEZVOUS:RECV:0x%x\n", (unsigned)status);
        fflush(stdout);
      });
      return;
    }
    BOOL shaped = MACH_MSGH_BITS_IS_COMPLEX(buffer.message.header.msgh_bits) &&
                  buffer.message.body.msgh_descriptor_count == 1 &&
                  buffer.message.port.type == MACH_MSG_PORT_DESCRIPTOR &&
                  buffer.message.header.msgh_id == kDartUiSurfaceMessageId;
    if (!shaped) {
      // Anything can send to a name it can look up, so a message that is not
      // the one shape we accept gets destroyed rather than interpreted.
      mach_msg_destroy(&buffer.message.header);
      dispatch_async(dispatch_get_main_queue(), ^{
        printf("ERROR=SURFACE_PORT:RENDEZVOUS:BAD_MESSAGE:%d\n",
               (int)buffer.message.header.msgh_id);
        fflush(stdout);
      });
      return;
    }
    mach_port_t port = buffer.message.port.name;
    uint32_t token = buffer.message.token;
    dispatch_async(dispatch_get_main_queue(), ^{
      printf("SURFACE_PORT_TOKEN=%u\n", (unsigned)token);
      [weakSelf adoptSurfacePort:port origin:@"rendezvous"];
    });
  });
}

- (void)attachSurfacePort:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count < 2) {
    printf("ERROR=SURFACE_PORT:DISPATCH:BAD_COMMAND:0\n");
    fflush(stdout);
    return;
  }
  NSString *mechanism = parts[1];
  NSString *argument = parts.count > 2 ? parts[2] : @"";
  if ([mechanism isEqualToString:@"REGISTERED"]) {
    [self attachSurfacePortRegistered:argument];
  } else if ([mechanism isEqualToString:@"BOOTSTRAP"]) {
    [self attachSurfacePortBootstrap:argument];
  } else if ([mechanism isEqualToString:@"RENDEZVOUS"]) {
    [self attachSurfacePortRendezvous];
  } else {
    printf("ERROR=SURFACE_PORT:DISPATCH:UNKNOWN_MECHANISM:0\n");
    fflush(stdout);
  }
}

// --- double buffering -------------------------------------------------------
//
// The single-surface path leaves the client writing into pages the
// WindowServer may be scanning out. A pool makes that impossible by
// construction rather than by timing: the client writes the slot it did not
// just present.
//
// Kept alongside SURFACE rather than replacing it, so the cost of swapping
// contents every frame can be measured against holding one surface. If the
// swap turns out to cost more, that is the price of correctness and it should
// be a known number, not a surprise.
- (void)attachSurfacePool:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count < 2) {
    printf("ERROR=SURFACE_POOL:EMPTY\n");
    fflush(stdout);
    return;
  }
  NSUInteger count = parts.count - 1;
  IOSurfaceRef *pool = calloc(count, sizeof(IOSurfaceRef));
  if (pool == NULL) {
    printf("ERROR=SURFACE_POOL:ALLOC\n");
    fflush(stdout);
    return;
  }
  for (NSUInteger i = 0; i < count; i++) {
    IOSurfaceID identifier = (IOSurfaceID)[parts[i + 1] integerValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    pool[i] = IOSurfaceLookup(identifier);
#pragma clang diagnostic pop
    if (pool[i] == NULL) {
      // Release what was already looked up: a partially built pool would
      // leak every surface before the one that failed.
      for (NSUInteger j = 0; j < i; j++) CFRelease(pool[j]);
      free(pool);
      printf("ERROR=SURFACE_POOL:LOOKUP:%u\n", identifier);
      fflush(stdout);
      return;
    }
  }
  [self releaseSurfacePool];
  self.surfacePool = pool;
  self.surfacePoolCount = count;
  self.presentedSlot = -1;
  printf("SURFACES_OK %lu\n", (unsigned long)count);
  fflush(stdout);
}

- (void)releaseSurfacePool {
  if (self.surfacePool == NULL) return;
  for (NSUInteger i = 0; i < self.surfacePoolCount; i++) {
    if (self.surfacePool[i] != NULL) CFRelease(self.surfacePool[i]);
  }
  free(self.surfacePool);
  self.surfacePool = NULL;
  self.surfacePoolCount = 0;
  self.presentedSlot = -1;
}

- (void)presentSlot:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 3 || self.surfacePool == NULL) {
    printf("ERROR=SURFACE_POOL:NOT_READY\n");
    fflush(stdout);
    return;
  }
  NSInteger slot = [parts[2] integerValue];
  if (slot < 0 || (NSUInteger)slot >= self.surfacePoolCount) {
    printf("ERROR=SURFACE_POOL:SLOT:%ld\n", (long)slot);
    fflush(stdout);
    return;
  }
  // Handing the layer a different surface IS the swap. Same slot twice in a
  // row is a redraw of the same buffer, which only needs the changed flag.
  if (slot != self.presentedSlot) {
    self.hostView.layer.contents = (__bridge id)self.surfacePool[slot];
    self.presentedSlot = slot;
  } else if ([self.hostView.layer
                 respondsToSelector:@selector(setContentsChanged)]) {
    [self.hostView.layer setContentsChanged];
  }
  [CATransaction flush];
  self.frameCount++;
  printf("PRESENT_OK %s slot%ld\n", parts[1].UTF8String, (long)slot);
  fflush(stdout);
}

// One entry point for both zero-copy transports, so the measured difference is
// the transport and not the surrounding code.
- (void)present:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count < 2) {
    printf("ERROR=BAD_PRESENT\n");
    fflush(stdout);
    return;
  }
  NSString *sequence = parts[1];

  if (self.surface != NULL) {
    if (!self.surfaceAttached) {
      // Handing the layer the surface is a one-off; later frames only need to
      // say the contents changed.
      self.hostView.layer.contents = (__bridge id)self.surface;
      self.surfaceAttached = YES;
    } else {
      [self.hostView.layer setContentsChanged];
    }
    [CATransaction flush];
    self.frameCount++;
    // Two distinct tags, not one tag plus a detail field: a client that pins
    // "surface" times out instead of quietly measuring the other path, which
    // is the failure mode worth designing for.
    printf("PRESENT_OK %s %s\n", sequence.UTF8String,
           self.surfacePortOrigin != nil ? "surface-port" : "surface");
    fflush(stdout);
    return;
  }

  if (self.shmProvider == NULL || parts.count != 4) {
    printf("ERROR=NO_TRANSPORT\n");
    fflush(stdout);
    return;
  }
  size_t width = (size_t)[parts[2] integerValue];
  size_t height = (size_t)[parts[3] integerValue];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(
      width, height, 8, 32, width * 4, colorSpace,
      (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst |
                     kCGBitmapByteOrder32Little),
      self.shmProvider, NULL, NO, kCGRenderingIntentDefault);
  CGColorSpaceRelease(colorSpace);
  if (image == NULL) {
    printf("ERROR=PRESENT_IMAGE\n");
    fflush(stdout);
    return;
  }
  self.hostView.layer.contents = (__bridge id)image;
  [CATransaction flush];
  CGImageRelease(image);
  self.frameCount++;
  printf("PRESENT_OK %s shm\n", sequence.UTF8String);
  fflush(stdout);
}

- (void)handleCommand:(NSString *)command {
  if (![NSThread isMainThread]) {
    printf("ERROR=COMMAND_NOT_ON_MAIN_THREAD\n");
  } else if ([command isEqualToString:@"PING"]) {
    printf("PONG\n");
  } else if ([command hasPrefix:@"SET_TITLE "]) {
    self.window.title = [command substringFromIndex:10];
    printf("TITLE_OK\n");
  } else if ([command hasPrefix:@"SHM "]) {
    [self attachSharedMemory:command];
    return;
  } else if ([command hasPrefix:@"SURFACE_PORT "]) {
    [self attachSurfacePort:command];
    return;
  } else if ([command hasPrefix:@"PORT_SERVER "]) {
    [self startPortServer:command];
    return;
  } else if ([command hasPrefix:@"SURFACES "]) {
    [self attachSurfacePool:command];
    return;
  } else if ([command hasPrefix:@"PRESENT_SLOT "]) {
    [self presentSlot:command];
    return;
  } else if ([command hasPrefix:@"SURFACE "]) {
    [self attachSurface:command];
    return;
  } else if ([command hasPrefix:@"PRESENT "]) {
    [self present:command];
    return;
  } else if ([command isEqualToString:@"CLOSE"]) {
    printf("CLOSE_OK\n");
    fflush(stdout);
    [NSApp terminate:nil];
    return;
  } else {
    printf("ERROR=UNKNOWN_COMMAND\n");
  }
  fflush(stdout);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  // Reverse acquisition order, same contract the other two backends follow.
  if (self.eventMonitor != nil) {
    [NSEvent removeMonitor:self.eventMonitor];
    self.eventMonitor = nil;
  }
  self.hostView.layer.contents = nil;
  [self releaseSharedMemory];
  [self releaseSurfacePool];
  if (self.surface != NULL) {
    CFRelease(self.surface);
    self.surface = NULL;
  }
  self.surfacePortOrigin = nil;
  if (MACH_PORT_VALID(self.machServicePort)) {
    // Destroying the receive right also withdraws the bootstrap name, so a
    // rerun in the same login session is not refused for a name still held by
    // the previous host.
    mach_port_mod_refs(mach_task_self(), self.machServicePort,
                       MACH_PORT_RIGHT_RECEIVE, -1);
    self.machServicePort = MACH_PORT_NULL;
  }
  [self.window orderOut:nil];
  self.window.contentView = nil;
  self.hostView = nil;
  self.window = nil;
  printf("TEARDOWN=PASS\n");
  fflush(stdout);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
    (NSApplication *)sender {
  (void)sender;
  return YES;
}

@end

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSTimeInterval smokeDuration = 0;
    BOOL commandStdin = NO;
    for (int index = 1; index < argc; index++) {
      if (strcmp(argv[index], "--smoke-seconds") == 0 && index + 1 < argc) {
        smokeDuration = strtod(argv[++index], NULL);
      } else if (strcmp(argv[index], "--command-stdin") == 0) {
        commandStdin = YES;
      }
    }

    NSApplication *app = [NSApplication sharedApplication];
    DartUiMinimalAppDelegate *delegate =
        [[DartUiMinimalAppDelegate alloc] init];
    delegate.smokeDuration = smokeDuration;
    delegate.commandStdin = commandStdin;
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
