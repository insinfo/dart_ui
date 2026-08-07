#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <string.h>

@interface DartUiMinimalAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, assign) NSTimeInterval smokeDuration;
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
  self.window.contentView.wantsLayer = YES;
  self.window.contentView.layer.backgroundColor =
      [NSColor colorWithRed:0.10 green:0.45 blue:0.85 alpha:1.0].CGColor;
  [self.window makeKeyAndOrderFront:nil];

  printf("MAIN_THREAD=%d\n", [NSThread isMainThread] ? 1 : 0);
  printf("WINDOW_ID=%ld\n", (long)self.window.windowNumber);
  fflush(stdout);

  if (self.smokeDuration > 0) {
    [NSTimer scheduledTimerWithTimeInterval:self.smokeDuration
                                     target:NSApp
                                   selector:@selector(terminate:)
                                   userInfo:nil
                                    repeats:NO];
  }
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
    if (argc == 3 && strcmp(argv[1], "--smoke-seconds") == 0) {
      smokeDuration = strtod(argv[2], NULL);
    }

    NSApplication *app = [NSApplication sharedApplication];
    DartUiMinimalAppDelegate *delegate =
        [[DartUiMinimalAppDelegate alloc] init];
    delegate.smokeDuration = smokeDuration;
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
