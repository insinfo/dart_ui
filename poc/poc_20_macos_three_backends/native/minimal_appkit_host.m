#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface DartUiMinimalAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, assign) NSTimeInterval smokeDuration;
@property(nonatomic, assign) BOOL commandStdin;
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
  printf("PROTOCOL=1\n");
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

- (void)startCommandReader {
  __weak DartUiMinimalAppDelegate *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), stdin) != NULL) {
      @autoreleasepool {
        NSString *line = [NSString stringWithUTF8String:buffer];
        line = [line stringByTrimmingCharactersInSet:
                         [NSCharacterSet newlineCharacterSet]];
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf handleCommand:line];
        });
      }
    }
  });
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
