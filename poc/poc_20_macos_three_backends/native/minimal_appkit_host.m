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
// Input is reported twice on purpose. The local NSEvent monitor sees every
// event the application dequeues and is the gate; VIEW_INPUT= comes from the
// responder chain and proves the event was routed to a view, not merely
// received.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  printf("PROTOCOL=2\n");
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
  printf("INPUT=%s:%.0f:%.0f:%u\n", kind, point.x, point.y,
         (unsigned)keyCode);
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

- (void)handleCommand:(NSString *)command {
  if (![NSThread isMainThread]) {
    printf("ERROR=COMMAND_NOT_ON_MAIN_THREAD\n");
  } else if ([command isEqualToString:@"PING"]) {
    printf("PONG\n");
  } else if ([command hasPrefix:@"SET_TITLE "]) {
    self.window.title = [command substringFromIndex:10];
    printf("TITLE_OK\n");
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
