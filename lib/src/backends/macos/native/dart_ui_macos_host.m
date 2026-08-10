// Native AppKit host for dart_ui's protocol 4 macOS backend.
//
// AppKit owns this process' first thread. Dart communicates through line-based
// stdin/stdout control messages and hands IOSurfaces over a Mach rendezvous
// channel; pixel data never crosses the pipe.
#import <Cocoa/Cocoa.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface CALayer (DartUiContentsChanged)
- (void)setContentsChanged;
@end

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  uint32_t token;
} DartUiSurfaceMessage;

typedef struct {
  DartUiSurfaceMessage message;
  mach_msg_max_trailer_t trailer;
} DartUiSurfaceMessageBuffer;

static const mach_msg_id_t kDartUiSurfaceMessageId = 0x64756930;  // 'dui0'
static const size_t kDartUiMaximumLineBytes = 8192;

@class DartUiHostView;

@protocol DartUiHostViewSink <NSObject>
- (void)hostView:(DartUiHostView *)view
     reportEvent:(NSString *)kind
              of:(NSEvent *)event;
- (void)hostView:(DartUiHostView *)view exposedRect:(NSRect)rect;
@end

@interface DartUiHostView : NSView
@property(nonatomic, weak) id<DartUiHostViewSink> sink;
@end

@implementation DartUiHostView

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  [self.sink hostView:self exposedRect:dirtyRect];
}

- (void)keyDown:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"keyDown" of:event];
}

- (void)keyUp:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"keyUp" of:event];
}

- (void)mouseDown:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerDown" of:event];
}

- (void)rightMouseDown:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerDown" of:event];
}

- (void)otherMouseDown:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerDown" of:event];
}

- (void)mouseUp:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerUp" of:event];
}

- (void)rightMouseUp:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerUp" of:event];
}

- (void)otherMouseUp:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerUp" of:event];
}

- (void)mouseMoved:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerMove" of:event];
}

- (void)mouseDragged:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerMove" of:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerMove" of:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"pointerMove" of:event];
}

- (void)scrollWheel:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"scroll" of:event];
}

@end

@interface DartUiHostDelegate
    : NSObject <NSApplicationDelegate, NSWindowDelegate, DartUiHostViewSink>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) DartUiHostView *hostView;
@property(nonatomic, strong) id eventMonitor;

@property(nonatomic, copy) NSString *initialTitle;
@property(nonatomic, assign) CGFloat initialWidth;
@property(nonatomic, assign) CGFloat initialHeight;
@property(nonatomic, assign) CGFloat initialX;
@property(nonatomic, assign) CGFloat initialY;
@property(nonatomic, assign) BOOL hasInitialX;
@property(nonatomic, assign) BOOL hasInitialY;
@property(nonatomic, assign) BOOL initiallyVisible;
@property(nonatomic, assign) BOOL decorated;
@property(nonatomic, assign) BOOL resizable;
@property(nonatomic, assign) BOOL commandStdin;

@property(nonatomic, assign) IOSurfaceRef *surfacePool;
@property(nonatomic, assign) NSUInteger surfacePoolCount;
@property(nonatomic, assign) IOSurfaceRef *pendingPool;
@property(nonatomic, assign) NSUInteger pendingPoolCount;
@property(nonatomic, assign) NSUInteger pendingPoolAttached;
@property(nonatomic, assign) NSInteger presentedSlot;

@property(nonatomic, assign) mach_port_t machServicePort;
@property(nonatomic, copy) NSString *machServiceName;
@property(nonatomic, assign) BOOL receivePending;
@property(nonatomic, assign) BOOL protocolReady;
@property(nonatomic, assign) BOOL terminating;
@property(nonatomic, assign) BOOL closedReported;
@property(nonatomic, assign) NSInteger reportedState;
@end

@implementation DartUiHostDelegate

- (void)printError:(NSString *)code {
  printf("ERROR=%s\n", code.UTF8String);
  fflush(stdout);
}

- (CGFloat)desktopTop {
  NSScreen *primary = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
  return primary == nil ? 0.0 : NSMaxY(primary.frame);
}

- (NSRect)appKitFrameForTopLeftX:(CGFloat)x
                               y:(CGFloat)y
                           width:(CGFloat)width
                          height:(CGFloat)height {
  return NSMakeRect(x, [self desktopTop] - y - height, width, height);
}

- (NSPoint)topLeftPositionForWindowFrame:(NSRect)frame {
  return NSMakePoint(NSMinX(frame), [self desktopTop] - NSMaxY(frame));
}

- (double)renderScale {
  double scale = self.window.backingScaleFactor;
  return scale > 0.0 ? scale : 1.0;
}

- (NSInteger)currentWindowState {
  if ((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0) return 3;
  if (self.window.miniaturized) return 1;
  if (self.window.zoomed) return 2;
  return 0;
}

- (void)reportStateIfChanged {
  if (!self.protocolReady || self.terminating) return;
  NSInteger state = [self currentWindowState];
  if (state == self.reportedState) return;
  self.reportedState = state;
  printf("WINDOW=STATE:%ld\n", (long)state);
  fflush(stdout);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

  NSWindowStyleMask style = NSWindowStyleMaskBorderless;
  if (self.decorated) {
    style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable;
  }
  if (self.resizable) style |= NSWindowStyleMaskResizable;

  NSRect contentRect = NSMakeRect(0.0, 0.0, self.initialWidth,
                                  self.initialHeight);
  self.window = [[NSWindow alloc] initWithContentRect:contentRect
                                            styleMask:style
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.delegate = self;
  self.window.title = self.initialTitle ?: @"dart_ui";
  self.window.releasedWhenClosed = NO;

  self.hostView = [[DartUiHostView alloc] initWithFrame:contentRect];
  self.hostView.sink = self;
  self.hostView.wantsLayer = YES;
  self.hostView.layer.backgroundColor = NSColor.clearColor.CGColor;
  self.hostView.layer.contentsGravity = kCAGravityTopLeft;
  self.hostView.layer.magnificationFilter = kCAFilterNearest;
  self.hostView.layer.minificationFilter = kCAFilterNearest;
  self.window.contentView = self.hostView;
  self.window.acceptsMouseMovedEvents = YES;

  if (self.hasInitialX && self.hasInitialY) {
    NSRect outer = self.window.frame;
    NSRect requested = [self appKitFrameForTopLeftX:self.initialX
                                                 y:self.initialY
                                             width:NSWidth(outer)
                                            height:NSHeight(outer)];
    [self.window setFrameOrigin:requested.origin];
  } else {
    [self.window center];
  }

  if (self.initiallyVisible) {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
  }
  [self.window makeFirstResponder:self.hostView];
  [self installEventMonitor];

  self.reportedState = [self currentWindowState];
  NSInteger scaleMilli = (NSInteger)llround([self renderScale] * 1000.0);
  printf("MAIN_THREAD=%d\n", [NSThread isMainThread] ? 1 : 0);
  printf("WINDOW_ID=%ld\n", (long)self.window.windowNumber);
  printf("PROTOCOL=4\n");
  printf("WINDOW_SCALE=%ld\n", (long)scaleMilli);
  printf("PROTOCOL_FEATURES=surface-port,window-events\n");
  // HOST_PID is deliberately last: it is the final required field and causes
  // the Dart side to publish the completed handshake immediately.
  printf("HOST_PID=%d\n", (int)getpid());
  fflush(stdout);

  self.protocolReady = YES;
  [self reportInitialWindowState];
  if (self.commandStdin) [self startCommandReader];
}

- (void)reportInitialWindowState {
  NSSize size = self.hostView.bounds.size;
  NSPoint position = [self topLeftPositionForWindowFrame:self.window.frame];
  double scale = [self renderScale];
  printf("WINDOW=RESIZED:%.4f:%.4f:%.4f\n", size.width, size.height, scale);
  printf("WINDOW=MOVED:%.4f:%.4f\n", position.x, position.y);
  printf("WINDOW=SCALE:%.4f:%.4f\n", scale, scale);
  printf("WINDOW=STATE:%ld\n", (long)self.reportedState);
  fflush(stdout);
}

- (void)installEventMonitor {
  NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp |
      NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
      NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
      NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
      NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
      NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
      NSEventMaskScrollWheel;
  __weak DartUiHostDelegate *weakSelf = self;
  self.eventMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                           handler:^NSEvent *(NSEvent *event) {
    [weakSelf reportMonitoredEvent:event];
    return event;
  }];
}

- (NSString *)kindForEvent:(NSEvent *)event {
  switch (event.type) {
    case NSEventTypeKeyDown: return @"keyDown";
    case NSEventTypeKeyUp: return @"keyUp";
    case NSEventTypeLeftMouseDown:
    case NSEventTypeRightMouseDown:
    case NSEventTypeOtherMouseDown: return @"pointerDown";
    case NSEventTypeLeftMouseUp:
    case NSEventTypeRightMouseUp:
    case NSEventTypeOtherMouseUp: return @"pointerUp";
    case NSEventTypeMouseMoved:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged: return @"pointerMove";
    case NSEventTypeScrollWheel: return @"scroll";
    default: return @"other";
  }
}

- (NSPoint)clientPointForEvent:(NSEvent *)event {
  if (event.window != self.window) return NSZeroPoint;
  return [self.hostView convertPoint:event.locationInWindow fromView:nil];
}

- (void)reportMonitoredEvent:(NSEvent *)event {
  if (!self.protocolReady || self.terminating) return;
  NSPoint point = [self clientPointForEvent:event];
  unsigned short keyCode =
      event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp
          ? event.keyCode
          : 0;
  printf("INPUT=%s:%.4f:%.4f:%u:%llu\n",
         [self kindForEvent:event].UTF8String, point.x, point.y,
         (unsigned)keyCode, (unsigned long long)mach_absolute_time());
  fflush(stdout);
}

- (void)hostView:(DartUiHostView *)view
     reportEvent:(NSString *)kind
              of:(NSEvent *)event {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  NSPoint point = [self clientPointForEvent:event];
  printf("VIEW_INPUT=%s:%.4f:%.4f\n", kind.UTF8String, point.x, point.y);
  fflush(stdout);
}

- (void)hostView:(DartUiHostView *)view exposedRect:(NSRect)rect {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  printf("WINDOW=EXPOSED:%.4f:%.4f:%.4f:%.4f\n", NSMinX(rect),
         NSMinY(rect), NSWidth(rect), NSHeight(rect));
  fflush(stdout);
}

- (void)startCommandReader {
  __weak DartUiHostDelegate *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char buffer[8194];
    while (fgets(buffer, (int)sizeof(buffer), stdin) != NULL) {
      @autoreleasepool {
        size_t length = strlen(buffer);
        BOOL complete = length > 0 && buffer[length - 1] == '\n';
        if (!complete && !feof(stdin)) {
          int byte = 0;
          while ((byte = fgetc(stdin)) != '\n' && byte != EOF) {}
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf printError:@"LINE_OVERFLOW"];
          });
          continue;
        }
        while (length > 0 &&
               (buffer[length - 1] == '\n' || buffer[length - 1] == '\r')) {
          buffer[--length] = '\0';
        }
        if (length > kDartUiMaximumLineBytes) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf printError:@"LINE_OVERFLOW"];
          });
          continue;
        }
        NSString *line = [[NSString alloc] initWithBytes:buffer
                                                  length:length
                                                encoding:NSUTF8StringEncoding];
        if (line == nil) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf printError:@"BAD_UTF8"];
          });
          continue;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf handleCommand:line];
        });
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      DartUiHostDelegate *strongSelf = weakSelf;
      if (strongSelf != nil && !strongSelf.terminating) {
        [NSApp terminate:nil];
      }
    });
  });
}

- (void)releasePool:(IOSurfaceRef *)pool count:(NSUInteger)count {
  if (pool == NULL) return;
  for (NSUInteger index = 0; index < count; index++) {
    if (pool[index] != NULL) CFRelease(pool[index]);
  }
  free(pool);
}

- (void)releaseSurfacePool {
  [self releasePool:self.surfacePool count:self.surfacePoolCount];
  self.surfacePool = NULL;
  self.surfacePoolCount = 0;
  self.presentedSlot = -1;
}

- (void)releasePendingPool {
  [self releasePool:self.pendingPool count:self.pendingPoolCount];
  self.pendingPool = NULL;
  self.pendingPoolCount = 0;
  self.pendingPoolAttached = 0;
}

- (void)allocateSurfacePool:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  NSInteger count = parts.count == 2 ? parts[1].integerValue : 0;
  if (count <= 0 || count > 64 || self.receivePending) {
    [self printError:@"BAD_SURFACE_POOL"];
    return;
  }
  IOSurfaceRef *pool = calloc((size_t)count, sizeof(IOSurfaceRef));
  if (pool == NULL) {
    [self printError:@"SURFACE_POOL_ALLOC"];
    return;
  }
  [self releasePendingPool];
  self.pendingPool = pool;
  self.pendingPoolCount = (NSUInteger)count;
  self.pendingPoolAttached = 0;
  printf("SURFACE_POOL_OK %ld\n", (long)count);
  fflush(stdout);
}

- (void)attachLookupSurfacePool:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count < 2 || self.receivePending) {
    [self printError:@"BAD_SURFACES"];
    return;
  }
  NSUInteger count = parts.count - 1;
  IOSurfaceRef *pool = calloc(count, sizeof(IOSurfaceRef));
  if (pool == NULL) {
    [self printError:@"SURFACE_POOL_ALLOC"];
    return;
  }
  for (NSUInteger index = 0; index < count; index++) {
    IOSurfaceID identifier = (IOSurfaceID)[parts[index + 1] longLongValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    pool[index] = IOSurfaceLookup(identifier);
#pragma clang diagnostic pop
    if (pool[index] == NULL) {
      [self releasePool:pool count:count];
      [self printError:@"SURFACE_LOOKUP"];
      return;
    }
  }
  [self releasePendingPool];
  [self releaseSurfacePool];
  self.surfacePool = pool;
  self.surfacePoolCount = count;
  printf("SURFACES_OK %lu\n", (unsigned long)count);
  fflush(stdout);
}

- (void)startPortServer:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 2 || parts[1].length == 0 || self.receivePending) {
    [self printError:@"SURFACE_PORT:PORT_SERVER:BAD_COMMAND"];
    return;
  }
  if (MACH_PORT_VALID(self.machServicePort)) {
    if ([self.machServiceName isEqualToString:parts[1]]) {
      printf("PORT_SERVER_OK %s\n", self.machServiceName.UTF8String);
      fflush(stdout);
      return;
    }
    [self printError:@"SURFACE_PORT:PORT_SERVER:DIFFERENT_NAME"];
    return;
  }
  mach_port_t service = MACH_PORT_NULL;
  kern_return_t status = bootstrap_check_in(
      bootstrap_port, (char *)parts[1].UTF8String, &service);
  if (status != KERN_SUCCESS) {
    NSString *error = [NSString
        stringWithFormat:@"SURFACE_PORT:PORT_SERVER:CHECK_IN:%d", (int)status];
    [self printError:error];
    return;
  }
  self.machServicePort = service;
  self.machServiceName = parts[1];
  printf("PORT_SERVER_OK %s\n", self.machServiceName.UTF8String);
  fflush(stdout);
}

- (void)adoptSurfacePort:(mach_port_t)port slot:(NSUInteger)slot {
  self.receivePending = NO;
  if (self.terminating) {
    mach_port_deallocate(mach_task_self(), port);
    return;
  }
  IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
  mach_port_deallocate(mach_task_self(), port);
  if (surface == NULL) {
    [self printError:@"SURFACE_PORT:RENDEZVOUS:LOOKUP_FROM_PORT"];
    return;
  }
  if (self.pendingPool == NULL || slot >= self.pendingPoolCount ||
      self.pendingPool[slot] != NULL) {
    CFRelease(surface);
    [self printError:@"SURFACE_PORT:RENDEZVOUS:STALE_SLOT"];
    return;
  }
  self.pendingPool[slot] = surface;
  self.pendingPoolAttached++;
  size_t width = IOSurfaceGetWidth(surface);
  size_t height = IOSurfaceGetHeight(surface);

  if (self.pendingPoolAttached == self.pendingPoolCount) {
    [self releaseSurfacePool];
    self.surfacePool = self.pendingPool;
    self.surfacePoolCount = self.pendingPoolCount;
    self.pendingPool = NULL;
    self.pendingPoolCount = 0;
    self.pendingPoolAttached = 0;
  }
  printf("SURFACE_PORT_OK rendezvous %zux%zu slot%lu\n", width, height,
         (unsigned long)slot);
  fflush(stdout);
}

- (void)receiveSurfaceForSlot:(NSUInteger)slot {
  if (!MACH_PORT_VALID(self.machServicePort)) {
    [self printError:@"SURFACE_PORT:RENDEZVOUS:NO_PORT_SERVER"];
    return;
  }
  if (self.pendingPool == NULL || slot >= self.pendingPoolCount ||
      self.pendingPool[slot] != NULL || self.receivePending) {
    [self printError:@"SURFACE_PORT:RENDEZVOUS:BAD_SLOT"];
    return;
  }
  self.receivePending = YES;
  mach_port_t service = self.machServicePort;
  __weak DartUiHostDelegate *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    DartUiSurfaceMessageBuffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    mach_msg_return_t status = mach_msg(
        &buffer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
        (mach_msg_size_t)sizeof(buffer), service, 5000, MACH_PORT_NULL);
    if (status != MACH_MSG_SUCCESS) {
      dispatch_async(dispatch_get_main_queue(), ^{
        DartUiHostDelegate *strongSelf = weakSelf;
        strongSelf.receivePending = NO;
        if (strongSelf != nil && !strongSelf.terminating) {
          [strongSelf printError:[NSString
              stringWithFormat:@"SURFACE_PORT:RENDEZVOUS:RECV:0x%x",
                               (unsigned)status]];
        }
      });
      return;
    }
    mach_msg_id_t messageId = buffer.message.header.msgh_id;
    uint32_t token = buffer.message.token;
    BOOL shaped = MACH_MSGH_BITS_IS_COMPLEX(buffer.message.header.msgh_bits) &&
                  buffer.message.body.msgh_descriptor_count == 1 &&
                  buffer.message.port.type == MACH_MSG_PORT_DESCRIPTOR &&
                  messageId == kDartUiSurfaceMessageId && token == slot;
    if (!shaped) {
      mach_msg_destroy(&buffer.message.header);
      dispatch_async(dispatch_get_main_queue(), ^{
        DartUiHostDelegate *strongSelf = weakSelf;
        strongSelf.receivePending = NO;
        if (strongSelf != nil && !strongSelf.terminating) {
          [strongSelf printError:[NSString
              stringWithFormat:@"SURFACE_PORT:RENDEZVOUS:BAD_MESSAGE:%d:%u",
                               (int)messageId, (unsigned)token]];
        }
      });
      return;
    }
    mach_port_t port = buffer.message.port.name;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf adoptSurfacePort:port slot:slot];
    });
  });
}

- (void)attachSurfacePort:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 3 || ![parts[1] isEqualToString:@"RENDEZVOUS"]) {
    [self printError:@"SURFACE_PORT:DISPATCH:BAD_COMMAND"];
    return;
  }
  NSInteger slot = parts[2].integerValue;
  if (slot < 0) {
    [self printError:@"SURFACE_PORT:RENDEZVOUS:BAD_SLOT"];
    return;
  }
  [self receiveSurfaceForSlot:(NSUInteger)slot];
}

- (void)presentSlot:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  if (parts.count != 3 || self.surfacePool == NULL) {
    [self printError:@"SURFACE_POOL:NOT_READY"];
    return;
  }
  NSInteger slot = parts[2].integerValue;
  if (slot < 0 || (NSUInteger)slot >= self.surfacePoolCount ||
      self.surfacePool[slot] == NULL) {
    [self printError:@"SURFACE_POOL:BAD_SLOT"];
    return;
  }
  CALayer *layer = self.hostView.layer;
  if (slot != self.presentedSlot) {
    layer.contents = (__bridge id)self.surfacePool[slot];
    self.presentedSlot = slot;
  } else if ([layer respondsToSelector:@selector(setContentsChanged)]) {
    [layer setContentsChanged];
  } else {
    id contents = layer.contents;
    layer.contents = nil;
    layer.contents = contents;
  }
  [CATransaction flush];
  printf("PRESENT_OK %s slot%ld\n", parts[1].UTF8String, (long)slot);
  fflush(stdout);
}

- (NSCursor *)cursorNamed:(NSString *)name {
  if ([name isEqualToString:@"arrow"] || [name isEqualToString:@"wait"]) {
    return NSCursor.arrowCursor;
  }
  if ([name isEqualToString:@"text"]) return NSCursor.IBeamCursor;
  if ([name isEqualToString:@"hand"]) return NSCursor.pointingHandCursor;
  if ([name isEqualToString:@"resizeHorizontal"]) {
    return NSCursor.resizeLeftRightCursor;
  }
  if ([name isEqualToString:@"resizeVertical"]) {
    return NSCursor.resizeUpDownCursor;
  }
  if ([name isEqualToString:@"resizeDiagonalDown"] ||
      [name isEqualToString:@"resizeDiagonalUp"] ||
      [name isEqualToString:@"crosshair"]) {
    return NSCursor.crosshairCursor;
  }
  if ([name isEqualToString:@"notAllowed"]) {
    return NSCursor.operationNotAllowedCursor;
  }
  return nil;
}

- (void)setBoundsFromCommand:(NSString *)command {
  NSScanner *scanner = [NSScanner scannerWithString:command];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  [scanner scanString:@"SET_BOUNDS" intoString:nil];
  double x = 0.0, y = 0.0, width = 0.0, height = 0.0;
  if (![scanner scanDouble:&x] || ![scanner scanDouble:&y] ||
      ![scanner scanDouble:&width] || ![scanner scanDouble:&height] ||
      width <= 0.0 || height <= 0.0) {
    [self printError:@"BAD_BOUNDS"];
    return;
  }
  NSRect content = [self.window contentRectForFrameRect:self.window.frame];
  content.size = NSMakeSize(width, height);
  NSRect outer = [self.window frameRectForContentRect:content];
  outer.origin = [self appKitFrameForTopLeftX:x y:y width:NSWidth(outer)
                                      height:NSHeight(outer)].origin;
  [self.window setFrame:outer display:YES];
}

- (void)requestRedraw:(NSString *)command {
  if ([command isEqualToString:@"REDRAW"]) {
    [self.hostView setNeedsDisplay:YES];
    return;
  }
  NSScanner *scanner = [NSScanner scannerWithString:command];
  scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  [scanner scanString:@"REDRAW" intoString:nil];
  double x = 0.0, y = 0.0, width = 0.0, height = 0.0;
  if (![scanner scanDouble:&x] || ![scanner scanDouble:&y] ||
      ![scanner scanDouble:&width] || ![scanner scanDouble:&height] ||
      width < 0.0 || height < 0.0) {
    [self printError:@"BAD_REDRAW"];
    return;
  }
  [self.hostView setNeedsDisplayInRect:NSMakeRect(x, y, width, height)];
}

- (void)handleCommand:(NSString *)command {
  if (![NSThread isMainThread]) {
    [self printError:@"COMMAND_NOT_ON_MAIN_THREAD"];
  } else if ([command isEqualToString:@"PING"]) {
    printf("PONG\n");
    fflush(stdout);
  } else if ([command hasPrefix:@"SET_TITLE "]) {
    self.window.title = [command substringFromIndex:10];
    printf("TITLE_OK\n");
    fflush(stdout);
  } else if ([command hasPrefix:@"SET_BOUNDS "]) {
    [self setBoundsFromCommand:command];
  } else if ([command isEqualToString:@"SHOW"]) {
    [self.window makeKeyAndOrderFront:nil];
  } else if ([command isEqualToString:@"HIDE"]) {
    [self.window orderOut:nil];
  } else if ([command hasPrefix:@"CURSOR "]) {
    NSCursor *cursor = [self cursorNamed:[command substringFromIndex:7]];
    if (cursor == nil) [self printError:@"BAD_CURSOR"];
    else [cursor set];
  } else if ([command isEqualToString:@"REDRAW"] ||
             [command hasPrefix:@"REDRAW "]) {
    [self requestRedraw:command];
  } else if ([command hasPrefix:@"SURFACE_POOL "]) {
    [self allocateSurfacePool:command];
  } else if ([command hasPrefix:@"SURFACES "]) {
    [self attachLookupSurfacePool:command];
  } else if ([command hasPrefix:@"PORT_SERVER "]) {
    [self startPortServer:command];
  } else if ([command hasPrefix:@"SURFACE_PORT "]) {
    [self attachSurfacePort:command];
  } else if ([command hasPrefix:@"PRESENT_SLOT "]) {
    [self presentSlot:command];
  } else if ([command isEqualToString:@"CLOSE"]) {
    self.terminating = YES;
    printf("CLOSE_OK\n");
    fflush(stdout);
    [NSApp terminate:nil];
  } else if (command.length != 0) {
    [self printError:@"UNKNOWN_COMMAND"];
  }
}

- (void)windowDidResize:(NSNotification *)notification {
  (void)notification;
  if (!self.protocolReady || self.terminating) return;
  NSSize size = self.hostView.bounds.size;
  printf("WINDOW=RESIZED:%.4f:%.4f:%.4f\n", size.width, size.height,
         [self renderScale]);
  fflush(stdout);
  [self reportStateIfChanged];
}

- (void)windowDidMove:(NSNotification *)notification {
  (void)notification;
  if (!self.protocolReady || self.terminating) return;
  NSPoint point = [self topLeftPositionForWindowFrame:self.window.frame];
  printf("WINDOW=MOVED:%.4f:%.4f\n", point.x, point.y);
  fflush(stdout);
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
  (void)notification;
  if (!self.protocolReady || self.terminating) return;
  double scale = [self renderScale];
  printf("WINDOW=SCALE:%.4f:%.4f\n", scale, scale);
  fflush(stdout);
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  if (self.protocolReady && !self.terminating) {
    printf("WINDOW=ACTIVATED\n");
    fflush(stdout);
  }
}

- (void)windowDidResignKey:(NSNotification *)notification {
  (void)notification;
  if (self.protocolReady && !self.terminating) {
    printf("WINDOW=DEACTIVATED\n");
    fflush(stdout);
  }
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
  (void)notification;
  [self reportStateIfChanged];
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
  (void)notification;
  [self reportStateIfChanged];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
  (void)notification;
  [self reportStateIfChanged];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
  (void)notification;
  [self reportStateIfChanged];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  if (self.protocolReady && !self.terminating) {
    printf("WINDOW=CLOSE_REQUESTED\n");
    fflush(stdout);
  }
  return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  self.terminating = YES;
  if (self.eventMonitor != nil) {
    [NSEvent removeMonitor:self.eventMonitor];
    self.eventMonitor = nil;
  }
  self.hostView.sink = nil;
  self.hostView.layer.contents = nil;
  [self releasePendingPool];
  [self releaseSurfacePool];
  if (MACH_PORT_VALID(self.machServicePort)) {
    mach_port_mod_refs(mach_task_self(), self.machServicePort,
                       MACH_PORT_RIGHT_RECEIVE, -1);
    self.machServicePort = MACH_PORT_NULL;
  }
  self.machServiceName = nil;
  self.window.delegate = nil;
  [self.window orderOut:nil];
  self.window.contentView = nil;
  self.hostView = nil;
  self.window = nil;
  if (!self.closedReported) {
    self.closedReported = YES;
    printf("WINDOW=CLOSED\n");
  }
  printf("TEARDOWN=PASS\n");
  fflush(stdout);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:
    (NSApplication *)sender {
  (void)sender;
  return YES;
}

@end

static BOOL DartUiParseDouble(const char *text, CGFloat *value) {
  char *end = NULL;
  double parsed = strtod(text, &end);
  if (end == text || *end != '\0') return NO;
  *value = (CGFloat)parsed;
  return YES;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    DartUiHostDelegate *delegate = [[DartUiHostDelegate alloc] init];
    delegate.initialTitle = @"dart_ui";
    delegate.initialWidth = 480.0;
    delegate.initialHeight = 320.0;
    delegate.initiallyVisible = YES;
    delegate.decorated = YES;
    delegate.resizable = YES;
    delegate.machServicePort = MACH_PORT_NULL;
    delegate.presentedSlot = -1;
    delegate.reportedState = -1;

    for (int index = 1; index < argc; index++) {
      const char *argument = argv[index];
      if (strcmp(argument, "--command-stdin") == 0) {
        delegate.commandStdin = YES;
      } else if (strcmp(argument, "--width") == 0 && index + 1 < argc) {
        CGFloat value = 0.0;
        if (!DartUiParseDouble(argv[++index], &value) || value <= 0.0) return 64;
        delegate.initialWidth = value;
      } else if (strcmp(argument, "--height") == 0 && index + 1 < argc) {
        CGFloat value = 0.0;
        if (!DartUiParseDouble(argv[++index], &value) || value <= 0.0) return 64;
        delegate.initialHeight = value;
      } else if (strcmp(argument, "--title") == 0 && index + 1 < argc) {
        delegate.initialTitle = [NSString stringWithUTF8String:argv[++index]];
        if (delegate.initialTitle == nil) return 64;
      } else if (strcmp(argument, "--x") == 0 && index + 1 < argc) {
        CGFloat value = 0.0;
        if (!DartUiParseDouble(argv[++index], &value)) return 64;
        delegate.initialX = value;
        delegate.hasInitialX = YES;
      } else if (strcmp(argument, "--y") == 0 && index + 1 < argc) {
        CGFloat value = 0.0;
        if (!DartUiParseDouble(argv[++index], &value)) return 64;
        delegate.initialY = value;
        delegate.hasInitialY = YES;
      } else if (strcmp(argument, "--hidden") == 0) {
        delegate.initiallyVisible = NO;
      } else if (strcmp(argument, "--no-decorations") == 0) {
        delegate.decorated = NO;
      } else if (strcmp(argument, "--not-resizable") == 0) {
        delegate.resizable = NO;
      } else {
        fprintf(stderr, "unknown or incomplete argument: %s\n", argument);
        return 64;
      }
    }
    if (delegate.hasInitialX != delegate.hasInitialY) {
      fprintf(stderr, "--x and --y must be supplied together\n");
      return 64;
    }

    NSApplication *application = [NSApplication sharedApplication];
    application.delegate = delegate;
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    [application run];
  }
  return 0;
}
