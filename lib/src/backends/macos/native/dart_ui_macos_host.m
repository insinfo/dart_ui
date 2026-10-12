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
- (void)hostView:(DartUiHostView *)view pointerInside:(BOOL)inside;
- (void)hostView:(DartUiHostView *)view
      insertText:(NSString *)text
       committing:(BOOL)committing;
- (void)hostView:(DartUiHostView *)view
    composeText:(NSString *)text
       selected:(NSRange)selected;
- (void)hostView:(DartUiHostView *)view
    deleteBefore:(NSUInteger)before
           after:(NSUInteger)after;
- (void)hostView:(DartUiHostView *)view
    dragSourceEnded:(long long)request
          operation:(NSDragOperation)operation;
- (void)hostViewAccessibilityRequested:(DartUiHostView *)view;
- (BOOL)hostView:(DartUiHostView *)view
    accessibilityAction:(NSString *)action
                     on:(long long)node;
- (void)hostView:(DartUiHostView *)view
            drag:(NSString *)phase
            info:(id<NSDraggingInfo>)info;
@end

@class DartUiHostView;

// One node of the framework's semantic tree, as AppKit's accessibility
// clients see it. The frame is kept in the host view's points (top-left
// origin, the view is flipped) and converted to the screen on demand, so a
// window that moves does not need the tree republished.
@interface DartUiA11yElement : NSAccessibilityElement
@property(nonatomic, assign) long long nodeId;
@property(nonatomic, weak) DartUiHostView *hostView;
@property(nonatomic, assign) NSRect viewRect;
@property(nonatomic, assign) unsigned long long actionBits;
@property(nonatomic, strong) NSMutableArray *childElements;
@end

@interface DartUiHostView : NSView <NSTextInputClient, NSDraggingSource>
@property(nonatomic, weak) id<DartUiHostViewSink> sink;
@property(nonatomic, strong) NSTrackingArea *pointerArea;
// What the text input system is composing - the acute a US layout shows while
// it waits for the vowel, or a Japanese reading before conversion. Mirrored
// to the framework as COMPOSE, which shows it in the field.
@property(nonatomic, strong) NSMutableString *markedText;
// The framework's caret, in this view's points (top-left origin), from
// IME_CARET: where a candidate window opens. NSZeroRect until one arrives.
@property(nonatomic, assign) NSRect caretRect;
// The text around the framework's caret and the selection in it, in UTF-16
// units, from IME_SURROUNDING. What selectedRange and
// attributedSubstringForProposedRange: answer, and what a replacementRange is
// measured against - the press-and-hold accent menu replaces the character
// before the caret, and answering nothing turned 'e' then 'é' into "eé".
@property(nonatomic, copy) NSString *surroundingText;
@property(nonatomic, assign) NSRange surroundingSelection;
// What the framework last answered for the drag over this view, from
// DROP_RESPONSE. AppKit asks for an operation synchronously, on every
// draggingUpdated:, and the answer lives in another process; blocking the
// main thread for it would deadlock against the command reader, so the view
// answers with the framework's latest response - one update behind - and the
// framework refines it on the next one.
@property(nonatomic, assign) NSDragOperation dropOperation;
// The press or drag a drag *out* starts from: beginDraggingSessionWithItems:
// needs the mouse event, and the request arrives from the framework a moment
// after the pointer moved, so the view keeps the latest one.
@property(nonatomic, strong) NSEvent *lastMouseEvent;
// The DRAG_START being served, and the operations its source allows.
@property(nonatomic, assign) long long dragSourceRequest;
@property(nonatomic, assign) NSDragOperation dragSourceMask;
- (void)startDragRequest:(long long)request
                    mask:(NSDragOperation)mask
                   paths:(NSArray<NSString *> *)paths
                    text:(NSString *)text;
// The published semantic tree: its top-level elements, and the tree being
// received between A11Y_BEGIN and A11Y_END.
@property(nonatomic, strong) NSArray *a11yRoots;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, DartUiA11yElement *> *a11yPending;
@property(nonatomic, strong) NSMutableArray *a11yPendingRoots;
@property(nonatomic, assign) BOOL a11yRequested;
- (BOOL)performA11yAction:(NSString *)action on:(long long)node;
@end

// SemanticsAction indices, as the framework numbers them (A11Y_NODE carries
// them as bits).
static const unsigned long long kA11yActionActivate = 1ull << 1;
static const unsigned long long kA11yActionIncrement = 1ull << 3;
static const unsigned long long kA11yActionDecrement = 1ull << 4;

@implementation DartUiA11yElement

- (NSRect)accessibilityFrame {
  DartUiHostView *view = self.hostView;
  if (view == nil || view.window == nil) return NSZeroRect;
  return NSAccessibilityFrameInView(view, self.viewRect);
}

- (NSArray *)accessibilityChildren {
  return self.childElements;
}

- (BOOL)accessibilityPerformPress {
  if ((self.actionBits & kA11yActionActivate) == 0) return NO;
  return [self.hostView performA11yAction:@"activate" on:self.nodeId];
}

- (BOOL)accessibilityPerformIncrement {
  if ((self.actionBits & kA11yActionIncrement) == 0) return NO;
  return [self.hostView performA11yAction:@"increment" on:self.nodeId];
}

- (BOOL)accessibilityPerformDecrement {
  if ((self.actionBits & kA11yActionDecrement) == 0) return NO;
  return [self.hostView performA11yAction:@"decrement" on:self.nodeId];
}

@end

@implementation DartUiHostView

- (BOOL)isFlipped {
  return YES;
}

// --- NSAccessibility ------------------------------------------------------
//
// The view is a group whose children are the framework's semantic tree. The
// first time a client asks for them the framework is told (A11Y_REQUESTED),
// and only from then on does it walk and publish the tree - a window nobody
// reads costs nothing, as on Windows.

- (BOOL)isAccessibilityElement {
  return NO;
}

- (NSAccessibilityRole)accessibilityRole {
  return NSAccessibilityGroupRole;
}

- (NSArray *)accessibilityChildren {
  if (!self.a11yRequested) {
    self.a11yRequested = YES;
    [self.sink hostViewAccessibilityRequested:self];
  }
  return self.a11yRoots ?: @[];
}

- (id)accessibilityHitTest:(NSPoint)point {
  NSArray *level = self.a11yRoots ?: @[];
  id hit = self;
  BOOL descended = YES;
  while (descended) {
    descended = NO;
    for (DartUiA11yElement *element in [level reverseObjectEnumerator]) {
      if (NSPointInRect(point, element.accessibilityFrame)) {
        hit = element;
        level = element.childElements ?: @[];
        descended = YES;
        break;
      }
    }
  }
  return hit;
}

- (BOOL)performA11yAction:(NSString *)action on:(long long)node {
  return [self.sink hostView:self accessibilityAction:action on:node];
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

// Text goes through the text input system, as in every AppKit text view.
//
// Not optional: it is where dead keys are composed. Measured with posted
// events on an ABNT2 layout, the acute key then E produced "e" when keyDown:
// read event.characters and "é" when it called interpretKeyEvents: - the
// dead-key state only exists inside the text input system. Every accent typed
// through a dead key was coming out bare. It is also where an input method
// lives, so a CJK method now commits its text through insertText: below;
// showing its preedit in the field is the TextInputProvider's job and not
// done yet.
//
// Not for a Command or Control chord: those are shortcuts, delivered to the
// framework as KeyEvents, and the text input system would answer them with
// Emacs bindings through doCommandBySelector:.
- (void)keyDown:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"keyDown" of:event];
  if ((event.modifierFlags &
       (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0) {
    return;
  }
  [self interpretKeyEvents:@[ event ]];
}

// --- NSDraggingDestination ------------------------------------------------
//
// Registered for file URLs and text only while the framework has a drop target
// on this window (DROP_REGISTER), so a window with none shows the no-drop
// cursor instead of accepting a drop nobody handles.

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  // Optimistic until the framework answers: copy, if the source allows it.
  NSDragOperation mask = sender.draggingSourceOperationMask;
  self.dropOperation = (mask & NSDragOperationCopy) != 0
                           ? NSDragOperationCopy
                           : (mask & NSDragOperationMove) != 0
                                 ? NSDragOperationMove
                                 : NSDragOperationNone;
  [self.sink hostView:self drag:@"ENTER" info:sender];
  return self.dropOperation;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  [self.sink hostView:self drag:@"OVER" info:sender];
  return self.dropOperation & sender.draggingSourceOperationMask;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  [self.sink hostView:self drag:@"LEAVE" info:sender];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  (void)sender;
  return self.dropOperation != NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  [self.sink hostView:self drag:@"DROP" info:sender];
  return YES;
}

// --- NSDraggingSource ------------------------------------------------------

// Starts a drag out of this view with the latest mouse event. Without one -
// no button went down in this view - there is nothing AppKit will start a
// session from, and the request ends at once with -1.
- (void)startDragRequest:(long long)request
                    mask:(NSDragOperation)mask
                   paths:(NSArray<NSString *> *)paths
                    text:(NSString *)text {
  NSEvent *event = self.lastMouseEvent;
  if (event == nil) {
    [self.sink hostView:self dragSourceEnded:request operation:(NSDragOperation)-1];
    return;
  }
  NSPoint at = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect frame = NSMakeRect(at.x - 16, at.y - 16, 32, 32);
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(32, 32)];
  NSMutableArray<NSDraggingItem *> *items = [NSMutableArray array];
  for (NSString *path in paths) {
    NSDraggingItem *item = [[NSDraggingItem alloc]
        initWithPasteboardWriter:[NSURL fileURLWithPath:path]];
    [item setDraggingFrame:frame contents:image];
    [items addObject:item];
  }
  if (text.length > 0) {
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:text];
    [item setDraggingFrame:frame contents:image];
    [items addObject:item];
  }
  if (items.count == 0) {
    [self.sink hostView:self dragSourceEnded:request operation:(NSDragOperation)-1];
    return;
  }
  self.dragSourceRequest = request;
  self.dragSourceMask = mask;
  [self beginDraggingSessionWithItems:items event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  (void)session;
  (void)context;
  return self.dragSourceMask;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  (void)session;
  (void)screenPoint;
  [self.sink hostView:self
      dragSourceEnded:self.dragSourceRequest
            operation:operation];
}

// --- NSTextInputClient ----------------------------------------------------

- (NSMutableString *)markedText {
  if (_markedText == nil) _markedText = [NSMutableString string];
  return _markedText;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  NSString *text =
      [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
  BOOL committing = self.markedText.length > 0;
  [self.markedText setString:@""];
  // A replacement outside the selection: what the input method wants gone
  // first, as UTF-16 units before and after the selection. Inside it, the
  // insertion replaces the selection anyway and nothing more is deleted.
  if (!committing && replacementRange.location != NSNotFound) {
    NSRange selection = self.surroundingSelection;
    NSUInteger start = selection.location;
    NSUInteger end = NSMaxRange(selection);
    NSUInteger before =
        replacementRange.location < start ? start - replacementRange.location
                                          : 0;
    NSUInteger after = NSMaxRange(replacementRange) > end
                           ? NSMaxRange(replacementRange) - end
                           : 0;
    if (before > 0 || after > 0) {
      [self.sink hostView:self deleteBefore:before after:after];
    }
    // The framework will push the new state; until it does, keep answering
    // for the document the input method believes it just made.
    NSString *current = self.surroundingText ?: @"";
    NSRange replaced = NSUnionRange(
        NSMakeRange(MIN(replacementRange.location, current.length),
                    MIN(replacementRange.length,
                        current.length -
                            MIN(replacementRange.location, current.length))),
        NSMakeRange(MIN(start, current.length), 0));
    self.surroundingText =
        [current stringByReplacingCharactersInRange:replaced withString:text];
    self.surroundingSelection =
        NSMakeRange(replaced.location + text.length, 0);
  }
  if (text.length > 0) {
    [self.sink hostView:self insertText:text committing:committing];
  } else if (committing) {
    // An empty commit ends the composition with nothing inserted.
    [self.sink hostView:self composeText:@"" selected:NSMakeRange(0, 0)];
  }
}

- (void)setMarkedText:(id)string
        selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange {
  (void)selectedRange;
  (void)replacementRange;
  NSString *text =
      [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
  [self.markedText setString:text ?: @""];
  [self.sink hostView:self composeText:self.markedText selected:selectedRange];
}

- (void)unmarkText {
  if (self.markedText.length == 0) return;
  [self.markedText setString:@""];
  [self.sink hostView:self composeText:@"" selected:NSMakeRange(0, 0)];
}

- (BOOL)hasMarkedText {
  return self.markedText.length > 0;
}

// Document coordinates: the preedit sits where the selection began.
- (NSRange)markedRange {
  return self.markedText.length > 0
             ? NSMakeRange(self.surroundingSelection.location,
                           self.markedText.length)
             : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
  if (self.markedText.length > 0) {
    return NSMakeRange(
        self.surroundingSelection.location + self.markedText.length, 0);
  }
  return self.surroundingSelection;
}

// The framework's text around the caret, as plain text. Nil outside it, which
// tells the input method there is nothing there rather than inventing it.
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                 actualRange:(NSRangePointer)actualRange {
  NSString *text = self.surroundingText ?: @"";
  if (range.location == NSNotFound || range.location >= text.length) {
    return nil;
  }
  NSRange clamped = NSMakeRange(
      range.location, MIN(range.length, text.length - range.location));
  if (actualRange != NULL) *actualRange = clamped;
  return [[NSAttributedString alloc]
      initWithString:[text substringWithRange:clamped]];
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
  return @[];
}

// Where a candidate window opens: under the framework's caret, which it sends
// with IME_CARET. Until one arrives, the view's top-left corner.
- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actualRange {
  (void)range;
  (void)actualRange;
  NSRect local = NSIsEmptyRect(self.caretRect) && self.caretRect.size.height == 0
                     ? NSMakeRect(0, 0, 1, 20)
                     : self.caretRect;
  return [self.window convertRectToScreen:[self convertRect:local toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  (void)point;
  return NSNotFound;
}

// Return, Delete, the arrows: the framework handles them from their KeyEvents.
// Not passed to super, which would beep for every one of them.
- (void)doCommandBySelector:(SEL)selector {
  (void)selector;
}

- (void)keyUp:(NSEvent *)event {
  [self.sink hostView:self reportEvent:@"keyUp" of:event];
}

- (void)mouseDown:(NSEvent *)event {
  self.lastMouseEvent = event;
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
  self.lastMouseEvent = event;
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

// The pointer leaving the window has no NSEvent of its own unless something
// asks for one, and without it the framework never clears hover: a button the
// mouse left through the window edge stays lit. InVisibleRect keeps the area
// equal to the view through every resize, so it is installed once.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.pointerArea != nil) return;
  self.pointerArea = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:self.pointerArea];
}

- (void)mouseEntered:(NSEvent *)event {
  (void)event;
  [self.sink hostView:self pointerInside:YES];
}

- (void)mouseExited:(NSEvent *)event {
  (void)event;
  [self.sink hostView:self pointerInside:NO];
}

@end

// What a drag looks like to a destination, for SYNTH_DRAG: a private
// pasteboard with the items, a location and the source's operations. AppKit
// hands a real one to the view's NSDraggingDestination methods; this one is
// handed to the same methods, which then report exactly as for a real drag.
@interface DartUiSynthDraggingInfo : NSObject <NSDraggingInfo>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSPasteboard *pasteboard;
@property(nonatomic, assign) NSPoint location;
@property(nonatomic, assign) NSDragOperation mask;
@end

@implementation DartUiSynthDraggingInfo
@synthesize draggingFormation;
@synthesize animatesToDestination;
@synthesize numberOfValidItemsForDrop;
- (NSWindow *)draggingDestinationWindow { return self.window; }
- (NSDragOperation)draggingSourceOperationMask { return self.mask; }
- (NSPoint)draggingLocation { return self.location; }
- (NSPoint)draggedImageLocation { return self.location; }
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint { (void)screenPoint; }
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)url {
  (void)url;
  return nil;
}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)o
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classes
                            searchOptions:(NSDictionary *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger,
                                                    BOOL *))block {
  (void)o; (void)view; (void)classes; (void)searchOptions; (void)block;
}
- (NSSpringLoadingHighlight)springLoadingHighlight {
  return NSSpringLoadingHighlightNone;
}
- (void)resetSpringLoading {}
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
@property(nonatomic, copy) NSString *windowKind;

@property(nonatomic, assign) IOSurfaceRef *surfacePool;
@property(nonatomic, assign) NSUInteger surfacePoolCount;
@property(nonatomic, assign) IOSurfaceRef *pendingPool;
@property(nonatomic, assign) NSUInteger pendingPoolCount;
@property(nonatomic, assign) NSUInteger pendingPoolAttached;
@property(nonatomic, assign) NSInteger presentedSlot;
// The vertical-blank signal for PRESENT_SLOT ... vsync: a display link of the
// host view, paused until a present asks for the next tick, so an idle window
// costs nothing. Typed id because CADisplayLink on NSView is macOS 14.
@property(nonatomic, strong) id vsyncLink;
@property(nonatomic, strong) NSMutableArray<NSString *> *vsyncWaiters;

@property(nonatomic, assign) mach_port_t machServicePort;
@property(nonatomic, copy) NSString *machServiceName;
@property(nonatomic, assign) BOOL receivePending;
@property(nonatomic, assign) BOOL protocolReady;
@property(nonatomic, assign) BOOL terminating;
@property(nonatomic, assign) BOOL closedReported;
@property(nonatomic, assign) NSInteger reportedState;
// The drag SYNTH_DRAG is building, from its enter to its leave or drop.
@property(nonatomic, strong) DartUiSynthDraggingInfo *synthDrag;
// Base64 pieces of a CLIPBOARD_WRITE still being sent, by request number.
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSMutableString *> *clipboardPending;
- (void)reportScreens;
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

// Positions are the *content* rect's top-left, in top-left-origin screen
// points, because that is what NativeWindow means on every other backend:
// Win32's setBounds places the client area and its clientToScreen answers
// from the client origin. Answering with the frame instead put every popup
// anchored in a titled window one title bar (32 pt on macOS 27) too high,
// since the anchor is client-relative and the origin it was added to was not.
- (NSRect)frameRectForContentTopLeftX:(CGFloat)x
                                    y:(CGFloat)y
                                width:(CGFloat)width
                               height:(CGFloat)height {
  NSRect content = NSMakeRect(x, [self desktopTop] - y - height, width, height);
  return [self.window frameRectForContentRect:content];
}

- (NSPoint)contentTopLeftPosition {
  NSRect content = [self.window contentRectForFrameRect:self.window.frame];
  return NSMakePoint(NSMinX(content), [self desktopTop] - NSMaxY(content));
}

- (void)reportMoved {
  NSPoint point = [self contentTopLeftPosition];
  printf("WINDOW=MOVED:%.4f:%.4f\n", point.x, point.y);
  fflush(stdout);
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

  BOOL isPopup = [self.windowKind isEqualToString:@"popup"];
  BOOL isTooltip = [self.windowKind isEqualToString:@"tooltip"];
  BOOL isTransient = isPopup || isTooltip;
  NSWindowStyleMask style = NSWindowStyleMaskBorderless;
  if (isTransient) {
    // NonactivatingPanel is a style-mask promise, not merely a choice of show
    // method. Keeping it on a separate NSPanel prevents a mouse press in a
    // menu from making the host process key and dimming the owner's caret.
    style |= NSWindowStyleMaskNonactivatingPanel;
  } else if (self.decorated) {
    style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable;
  }
  if (self.resizable && !isTransient) style |= NSWindowStyleMaskResizable;

  NSRect contentRect = NSMakeRect(0.0, 0.0, self.initialWidth,
                                  self.initialHeight);
  Class windowClass = isTransient ? NSPanel.class : NSWindow.class;
  self.window = [[windowClass alloc] initWithContentRect:contentRect
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
  if (isTransient) {
    self.window.level = NSPopUpMenuWindowLevel;
    self.window.collectionBehavior =
        NSWindowCollectionBehaviorTransient |
        NSWindowCollectionBehaviorIgnoresCycle;
    ((NSPanel *)self.window).becomesKeyOnlyIfNeeded = YES;
    self.window.ignoresMouseEvents = isTooltip;
  }
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
    NSRect requested =
        [self frameRectForContentTopLeftX:self.initialX
                                        y:self.initialY
                                    width:self.initialWidth
                                   height:self.initialHeight];
    [self.window setFrameOrigin:requested.origin];
  } else {
    [self.window center];
  }

  if (self.initiallyVisible && isTransient) {
    [self.window orderFront:nil];
  } else if (self.initiallyVisible) {
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
  printf("PROTOCOL_FEATURES=surface-port,window-events,clipboard,vsync\n");
  [self reportScreens];
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
  NSPoint position = [self contentTopLeftPosition];
  double scale = [self renderScale];
  printf("WINDOW=RESIZED:%.4f:%.4f:%.4f\n", size.width, size.height, scale);
  printf("WINDOW=MOVED:%.4f:%.4f\n", position.x, position.y);
  printf("WINDOW=SCALE:%.4f:%.4f\n", scale, scale);
  printf("WINDOW=STATE:%ld\n", (long)self.reportedState);
  fflush(stdout);
}

- (void)reportScreens {
  CGFloat desktopTop = [self desktopTop];
  NSScreen *primary = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
  for (NSScreen *screen in NSScreen.screens) {
    NSRect frame = screen.frame;
    NSRect visible = screen.visibleFrame;
    NSString *name = [screen.localizedName stringByReplacingOccurrencesOfString:@"\n"
                                                                    withString:@" "];
    printf("SCREEN_INFO=%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%.4f:%d:%s\n",
           NSMinX(frame), desktopTop - NSMaxY(frame), NSWidth(frame), NSHeight(frame),
           NSMinX(visible), desktopTop - NSMaxY(visible), NSWidth(visible),
           NSHeight(visible), screen.backingScaleFactor,
           screen == primary ? 1 : 0, name.UTF8String);
  }
}

- (void)installEventMonitor {
  NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp |
      NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp |
      NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
      NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
      NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
      NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
      NSEventMaskScrollWheel | NSEventMaskFlagsChanged;
  __weak DartUiHostDelegate *weakSelf = self;
  self.eventMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                           handler:^NSEvent *(NSEvent *event) {
    [weakSelf reportMonitoredEvent:event];
    return event;
  }];
}

// The modifier flag a modifier key's keyCode sets, or 0 for any other key.
// AppKit reports a modifier key alone as NSEventTypeFlagsChanged, with no
// down or up of its own; whether the flag is now set is the direction.
static NSEventModifierFlags modifierFlagForKeyCode(unsigned short keyCode) {
  switch (keyCode) {
    case 0x38: case 0x3C: return NSEventModifierFlagShift;
    case 0x3B: case 0x3E: return NSEventModifierFlagControl;
    case 0x3A: case 0x3D: return NSEventModifierFlagOption;
    case 0x37: case 0x36: return NSEventModifierFlagCommand;
    case 0x39: return NSEventModifierFlagCapsLock;
    case 0x3F: return NSEventModifierFlagFunction;
    default: return 0;
  }
}

- (NSString *)kindForEvent:(NSEvent *)event {
  switch (event.type) {
    case NSEventTypeKeyDown: return @"keyDown";
    case NSEventTypeKeyUp: return @"keyUp";
    case NSEventTypeFlagsChanged: {
      NSEventModifierFlags flag = modifierFlagForKeyCode(event.keyCode);
      if (flag == 0) return @"other";
      return (event.modifierFlags & flag) != 0 ? @"keyDown" : @"keyUp";
    }
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
  if (event.window == self.window) {
    return [self.hostView convertPoint:event.locationInWindow fromView:nil];
  }
  // An event with no window - a scroll built from a Quartz event, say - has
  // locationInWindow in *screen* coordinates, as NSEvent documents. Pointer
  // and scroll events are the ones whose position means anything.
  BOOL positional = event.type == NSEventTypeScrollWheel ||
                    (NSEventMaskFromType(event.type) &
                     (NSEventMaskMouseMoved | NSEventMaskLeftMouseDown |
                      NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown |
                      NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown |
                      NSEventMaskOtherMouseUp | NSEventMaskLeftMouseDragged |
                      NSEventMaskRightMouseDragged |
                      NSEventMaskOtherMouseDragged)) != 0;
  if (event.window == nil && positional) {
    NSPoint inWindow = [self.window convertPointFromScreen:event.locationInWindow];
    return [self.hostView convertPoint:inWindow fromView:nil];
  }
  return NSZeroPoint;
}

// INPUT=<kind>:<x>:<y>:<keyCode>:<machTime>:<button>:<modifierFlags>:
//       <clickCount>:<deltaX>:<deltaY>:<flags>:<keyChar>
//
// The first five fields are the protocol 2 line the latency probes read; the
// rest are what turning the line into framework input needs, appended so an
// older reader still parses the front of it:
//   button        NSEvent.buttonNumber for a mouse event, -1 otherwise;
//   modifierFlags NSEvent.modifierFlags, raw;
//   clickCount    NSEvent.clickCount for a press or release, 0 otherwise;
//   deltaX/Y      scrollingDeltaX/Y for a scroll, 0 otherwise;
//   flags         bit 0 hasPreciseScrollingDeltas, bit 1 isARepeat;
//   keyChar       the first code point of charactersIgnoringModifiers, 0 if
//                 none - what the layout says the key is, for shortcuts.
- (void)reportMonitoredEvent:(NSEvent *)event {
  if (!self.protocolReady || self.terminating) return;
  // While the text input system is composing, a key is its - the vowel after
  // a dead key, an arrow choosing a candidate, Return accepting one - and
  // reporting it would also move the caret or press the default button. The
  // Mac's counterpart of the VK_PROCESSKEY win32_window.dart drops.
  if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
      self.hostView.hasMarkedText) {
    return;
  }
  NSPoint point = [self clientPointForEvent:event];
  NSEventType type = event.type;
  BOOL isKey = type == NSEventTypeKeyDown || type == NSEventTypeKeyUp ||
               type == NSEventTypeFlagsChanged;
  BOOL isMouseButton =
      type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseUp ||
      type == NSEventTypeRightMouseDown || type == NSEventTypeRightMouseUp ||
      type == NSEventTypeOtherMouseDown || type == NSEventTypeOtherMouseUp;
  BOOL isMouse = isMouseButton || type == NSEventTypeMouseMoved ||
                 type == NSEventTypeLeftMouseDragged ||
                 type == NSEventTypeRightMouseDragged ||
                 type == NSEventTypeOtherMouseDragged;
  BOOL isScroll = type == NSEventTypeScrollWheel;
  unsigned short keyCode = isKey ? event.keyCode : 0;
  unsigned flags = 0;
  if (isScroll && event.hasPreciseScrollingDeltas) flags |= 1u;
  if ((type == NSEventTypeKeyDown || type == NSEventTypeKeyUp) &&
      event.isARepeat) {
    flags |= 2u;
  }
  unsigned keyChar = 0;
  if (type == NSEventTypeKeyDown || type == NSEventTypeKeyUp) {
    NSString *ignoring = event.charactersIgnoringModifiers;
    if (ignoring.length > 0) {
      UTF32Char scalar = 0;
      [ignoring getBytes:&scalar
               maxLength:sizeof(scalar)
              usedLength:NULL
                encoding:NSUTF32LittleEndianStringEncoding
                 options:0
                   range:NSMakeRange(0, [ignoring rangeOfComposedCharacterSequenceAtIndex:0].length)
          remainingRange:NULL];
      keyChar = scalar;
    }
  }
  printf("INPUT=%s:%.4f:%.4f:%u:%llu:%ld:%lu:%ld:%.4f:%.4f:%u:%u\n",
         [self kindForEvent:event].UTF8String, point.x, point.y,
         (unsigned)keyCode, (unsigned long long)mach_absolute_time(),
         isMouse ? (long)event.buttonNumber : -1L,
         (unsigned long)event.modifierFlags,
         isMouseButton ? (long)event.clickCount : 0L,
         isScroll ? event.scrollingDeltaX : 0.0,
         isScroll ? event.scrollingDeltaY : 0.0, flags, keyChar);
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

// The characters the text input system committed, on their own line because
// they are text and need encoding. They come from insertText: - after the
// layout's dead keys and any input method - and not from the event monitor,
// which sees a key before AppKit has composed anything.
//
// TEXT_INPUT when nothing was being composed, which the framework treats as
// typing; COMMIT when it ends a composition, which replaces the preedit the
// framework is showing instead of being inserted beside it.
- (void)hostView:(DartUiHostView *)view
      insertText:(NSString *)text
       committing:(BOOL)committing {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes.length == 0) return;
  printf("%s=%s\n", committing ? "COMMIT" : "TEXT_INPUT",
         [bytes base64EncodedStringWithOptions:0].UTF8String);
  fflush(stdout);
}

// COMPOSE=<base64>:<selectedLocation>:<selectedLength>, in UTF-16 units of the
// composed text, which are a Dart String's units too. An empty composition is
// "-": the preedit ended without anything committed.
- (void)hostView:(DartUiHostView *)view
    composeText:(NSString *)text
       selected:(NSRange)selected {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  NSUInteger location = selected.location == NSNotFound ? text.length
                                                        : selected.location;
  printf("COMPOSE=%s:%lu:%lu\n",
         bytes.length == 0 ? "-"
                           : [bytes base64EncodedStringWithOptions:0].UTF8String,
         (unsigned long)MIN(location, text.length),
         (unsigned long)selected.length);
  fflush(stdout);
}

// A11Y_REQUESTED: an accessibility client asked this view for its children,
// so the framework should start publishing the tree.
- (void)hostViewAccessibilityRequested:(DartUiHostView *)view {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  printf("A11Y_REQUESTED\n");
  fflush(stdout);
}

// A11Y_ACTION=<node>:<action>: a client asked a node to act. Answered YES at
// once - the framework decides; AppKit cannot wait for it.
- (BOOL)hostView:(DartUiHostView *)view
    accessibilityAction:(NSString *)action
                     on:(long long)node {
  (void)view;
  if (!self.protocolReady || self.terminating) return NO;
  printf("A11Y_ACTION=%lld:%s\n", node, action.UTF8String);
  fflush(stdout);
  return YES;
}

static NSAccessibilityRole DartUiA11yRole(NSString *role) {
  static NSDictionary<NSString *, NSAccessibilityRole> *roles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    roles = @{
      @"button" : NSAccessibilityButtonRole,
      @"toggleButton" : NSAccessibilityCheckBoxRole,
      @"checkbox" : NSAccessibilityCheckBoxRole,
      @"radio" : NSAccessibilityRadioButtonRole,
      @"slider" : NSAccessibilitySliderRole,
      @"progressBar" : NSAccessibilityProgressIndicatorRole,
      @"textField" : NSAccessibilityTextFieldRole,
      @"list" : NSAccessibilityListRole,
      @"listItem" : NSAccessibilityGroupRole,
      @"menu" : NSAccessibilityMenuRole,
      @"menuItem" : NSAccessibilityMenuItemRole,
      @"dialog" : NSAccessibilityGroupRole,
      @"tooltip" : NSAccessibilityHelpTagRole,
      @"scrollView" : NSAccessibilityScrollAreaRole,
      @"image" : NSAccessibilityImageRole,
      @"text" : NSAccessibilityStaticTextRole,
    };
  });
  return roles[role] ?: NSAccessibilityGroupRole;
}

// A11Y_NODE <id> <parent> <role> <label|-> <value|-> <x> <y> <w> <h>
//           <states> <actions>, between A11Y_BEGIN and A11Y_END; label and
// value are base64 of UTF-8, the rectangle is in view points.
- (void)accessibilityNode:(NSArray<NSString *> *)parts {
  DartUiHostView *view = self.hostView;
  if (parts.count != 12 || view.a11yPending == nil) {
    [self printError:@"BAD_A11Y_NODE"];
    return;
  }
  NSString *label = [self decodeSynthText:parts[4]];
  NSString *value = [self decodeSynthText:parts[5]];
  if (label == nil || value == nil) {
    [self printError:@"BAD_A11Y_NODE"];
    return;
  }
  DartUiA11yElement *element = [[DartUiA11yElement alloc] init];
  element.nodeId = parts[1].longLongValue;
  element.hostView = view;
  element.viewRect = NSMakeRect(parts[6].doubleValue, parts[7].doubleValue,
                                parts[8].doubleValue, parts[9].doubleValue);
  element.actionBits = (unsigned long long)parts[11].longLongValue;
  element.childElements = [NSMutableArray array];
  NSString *roleName = parts[3];
  NSAccessibilityRole role = DartUiA11yRole(roleName);
  element.accessibilityRole = role;
  if (label.length > 0) element.accessibilityLabel = label;
  // SemanticsState indices: disabled 0, checked 1, mixed 2, selected 3,
  // focused 4, expanded 5.
  unsigned long long states = (unsigned long long)parts[10].longLongValue;
  element.accessibilityEnabled = (states & (1ull << 0)) == 0;
  if (value.length > 0) {
    element.accessibilityValue = value;
  } else if ([role isEqualToString:NSAccessibilityCheckBoxRole] ||
             [role isEqualToString:NSAccessibilityRadioButtonRole]) {
    element.accessibilityValue = (states & (1ull << 2))
                                     ? @2
                                     : ((states & (1ull << 1)) ? @1 : @0);
  }
  if (states & (1ull << 3)) element.accessibilitySelected = YES;
  if (states & (1ull << 4)) element.accessibilityFocused = YES;
  if (states & (1ull << 5)) element.accessibilityExpanded = YES;

  long long parent = parts[2].longLongValue;
  DartUiA11yElement *owner = parent == 0 ? nil : view.a11yPending[@(parent)];
  if (owner == nil) {
    element.accessibilityParent = view;
    [view.a11yPendingRoots addObject:element];
  } else {
    element.accessibilityParent = owner;
    [owner.childElements addObject:element];
  }
  view.a11yPending[@(element.nodeId)] = element;
}

// SYNTH_A11Y_DUMP: the view's accessibility tree as an assistive client reads
// it, one A11Y_DUMP=<depth>:<role>:<label|->:<value|-> line per element and
// A11Y_DUMP=END - asked through the same accessibilityChildren a client calls,
// so it also exercises A11Y_REQUESTED.
- (void)dumpAccessibility:(NSArray *)elements depth:(int)depth {
  for (id element in elements) {
    NSString *label = [element accessibilityLabel] ?: @"";
    id raw = [element accessibilityValue];
    NSString *value = raw == nil ? @"" : [NSString stringWithFormat:@"%@", raw];
    NSData *labelBytes = [label dataUsingEncoding:NSUTF8StringEncoding];
    NSData *valueBytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    printf("A11Y_DUMP=%d:%s:%s:%s\n", depth,
           [[element accessibilityRole] UTF8String] ?: "-",
           labelBytes.length == 0
               ? "-"
               : [labelBytes base64EncodedStringWithOptions:0].UTF8String,
           valueBytes.length == 0
               ? "-"
               : [valueBytes base64EncodedStringWithOptions:0].UTF8String);
    [self dumpAccessibility:[element accessibilityChildren] ?: @[]
                      depth:depth + 1];
  }
}

// DRAG_SOURCE_END=<request>:<operation>: how a DRAG_START ended - the
// NSDragOperation the destination performed, 0 for none, -1 when no session
// could start at all.
- (void)hostView:(DartUiHostView *)view
    dragSourceEnded:(long long)request
          operation:(NSDragOperation)operation {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  printf("DRAG_SOURCE_END=%lld:%lld\n", request, (long long)operation);
  fflush(stdout);
}

// IME_DELETE=<before>:<after>: UTF-16 units to delete around the selection
// before the text that follows. Sent ahead of the TEXT_INPUT or COMMIT of an
// insertText:replacementRange: whose range reaches outside the selection.
- (void)hostView:(DartUiHostView *)view
    deleteBefore:(NSUInteger)before
           after:(NSUInteger)after {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  printf("IME_DELETE=%lu:%lu\n", (unsigned long)before, (unsigned long)after);
  fflush(stdout);
}

// DRAG_ITEM=<file|text>:<base64> for each thing the drag carries, before the
// DRAG=ENTER that uses them; then DRAG=<ENTER|OVER|DROP>:<x>:<y>:<mask>:<flags>
// with view points (top-left origin), the source's NSDragOperation mask and
// the modifier flags; DRAG=LEAVE when it goes without dropping.
- (void)hostView:(DartUiHostView *)view
            drag:(NSString *)phase
            info:(id<NSDraggingInfo>)info {
  if (!self.protocolReady || self.terminating) return;
  if ([phase isEqualToString:@"LEAVE"]) {
    printf("DRAG=LEAVE\n");
    fflush(stdout);
    return;
  }
  if ([phase isEqualToString:@"ENTER"]) {
    NSPasteboard *pasteboard = info.draggingPasteboard;
    NSArray<NSURL *> *urls = [pasteboard
        readObjectsForClasses:@[ NSURL.class ]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
    for (NSURL *url in urls) {
      NSData *bytes = [url.path dataUsingEncoding:NSUTF8StringEncoding];
      if (bytes.length > 0) {
        printf("DRAG_ITEM=file:%s\n",
               [bytes base64EncodedStringWithOptions:0].UTF8String);
      }
    }
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    NSData *textBytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (textBytes.length > 0 && urls.count == 0) {
      // A file drag from Finder also carries the path as a string; offering
      // it as text too would let a text target paste a path the user meant
      // as a file.
      printf("DRAG_ITEM=text:%s\n",
             [textBytes base64EncodedStringWithOptions:0].UTF8String);
    }
  }
  NSPoint point = [view convertPoint:info.draggingLocation fromView:nil];
  printf("DRAG=%s:%.4f:%.4f:%lu:%lu\n", phase.UTF8String, point.x, point.y,
         (unsigned long)info.draggingSourceOperationMask,
         (unsigned long)NSEvent.modifierFlags);
  fflush(stdout);
}

- (void)hostView:(DartUiHostView *)view pointerInside:(BOOL)inside {
  (void)view;
  if (!self.protocolReady || self.terminating) return;
  printf("WINDOW=%s\n", inside ? "POINTER_ENTER" : "POINTER_LEAVE");
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
  // PRESENT_SLOT <sequence> <slot> [vsync]. The optional word asks for a
  // VSYNC <sequence> line at the display's next refresh after this commit,
  // which is what paces a FIFO client to the screen.
  BOOL wantsVsync = parts.count == 4 && [parts[3] isEqualToString:@"vsync"];
  if ((parts.count != 3 && !wantsVsync) || self.surfacePool == NULL) {
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
  if (wantsVsync) [self armVsync:parts[1]];
}

// Reports VSYNC <sequence> at the next refresh of the screen the view is on.
// The link follows the window between displays by itself, and pauses while
// the window is hidden or occluded - a client waiting then times out and runs
// unpaced, which is the right answer for a window nobody can see.
- (void)armVsync:(NSString *)sequence {
  if (@available(macOS 14.0, *)) {
    if (self.vsyncWaiters == nil) self.vsyncWaiters = [NSMutableArray array];
    [self.vsyncWaiters addObject:sequence];
    CADisplayLink *link = self.vsyncLink;
    if (link == nil) {
      link = [self.hostView displayLinkWithTarget:self
                                         selector:@selector(onVsync:)];
      [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
      self.vsyncLink = link;
    }
    link.paused = NO;
  } else {
    // No display link on NSView before macOS 14: answer at once, so the
    // client is never left waiting on a signal that cannot come.
    printf("VSYNC %s\n", sequence.UTF8String);
    fflush(stdout);
  }
}

- (void)onVsync:(CADisplayLink *)link API_AVAILABLE(macos(14.0)) {
  for (NSString *sequence in self.vsyncWaiters) {
    printf("VSYNC %s\n", sequence.UTF8String);
  }
  fflush(stdout);
  [self.vsyncWaiters removeAllObjects];
  link.paused = YES;
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

// The general pasteboard, as text. The Dart side owns the request numbers;
// this side only echoes them, so two requests in flight cannot be confused.
// Text crosses the pipe as base64 of UTF-8 because the protocol is line based
// and clipboard text has newlines in it, in pieces short enough for the
// 8192-byte line cap (kMacosHostClipboardChunk on the Dart side).
static const NSUInteger kClipboardChunk = 6000;

- (void)readClipboard:(NSString *)command {
  long long request = [[command substringFromIndex:15] longLongValue];
  NSString *text =
      [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
  if (text == nil) {
    printf("CLIPBOARD=%lld:NONE\n", request);
    fflush(stdout);
    return;
  }
  NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (bytes == nil) {
    printf("CLIPBOARD=%lld:FAILED\n", request);
    fflush(stdout);
    return;
  }
  NSString *encoded = [bytes base64EncodedStringWithOptions:0];
  for (NSUInteger start = 0; start < encoded.length; start += kClipboardChunk) {
    NSUInteger length = MIN(kClipboardChunk, encoded.length - start);
    printf("CLIPBOARD_DATA=%lld:%s\n", request,
           [encoded substringWithRange:NSMakeRange(start, length)].UTF8String);
  }
  printf("CLIPBOARD=%lld:TEXT\n", request);
  fflush(stdout);
}

- (void)appendClipboard:(NSString *)command {
  // CLIPBOARD_APPEND <request> <base64>
  NSString *rest = [command substringFromIndex:17];
  NSRange space = [rest rangeOfString:@" "];
  if (space.location == NSNotFound) {
    [self printError:@"BAD_CLIPBOARD_APPEND"];
    return;
  }
  NSNumber *request =
      @([[rest substringToIndex:space.location] longLongValue]);
  if (self.clipboardPending == nil) {
    self.clipboardPending = [NSMutableDictionary dictionary];
  }
  NSMutableString *pending = self.clipboardPending[request];
  if (pending == nil) {
    pending = [NSMutableString string];
    self.clipboardPending[request] = pending;
  }
  [pending appendString:[rest substringFromIndex:space.location + 1]];
}

- (void)writeClipboard:(NSString *)command {
  long long request = [[command substringFromIndex:16] longLongValue];
  NSString *encoded = self.clipboardPending[@(request)] ?: @"";
  [self.clipboardPending removeObjectForKey:@(request)];
  NSData *bytes = [[NSData alloc] initWithBase64EncodedString:encoded
                                                      options:0];
  NSString *text = bytes == nil
                       ? nil
                       : [[NSString alloc] initWithData:bytes
                                               encoding:NSUTF8StringEncoding];
  BOOL written = NO;
  if (text != nil) {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    written = [pasteboard setString:text forType:NSPasteboardTypeString];
  }
  printf("CLIPBOARD=%lld:%s\n", request, written ? "WRITTEN" : "FAILED");
  fflush(stdout);
}

// --- synthetic input, for smokes ----------------------------------------
//
// Builds an NSEvent and posts it to this application's own queue, so it is
// dequeued, seen by the local event monitor and reported exactly as a real
// one would be. That is the whole point: tool/macos_input_smoke.dart proves
// the path from the event queue to a widget, and posting to our own queue
// needs no accessibility permission, which CGEventPost from outside does - a
// synthetic click from another process never arrived on the machine this was
// written on.
//
//   SYNTH_MOUSE <down|up|move|drag> <x> <y> <button> <clickCount> <flags>
//   SYNTH_KEY <down|up> <keyCode> <flags> <characters-b64|-> <ignoring-b64|->
//   SYNTH_SCROLL <x> <y> <deltaX> <deltaY> <precise 0|1>
//   SYNTH_POINTER <enter|leave>
//
// SYNTH_POINTER calls the view's tracking-area handlers directly: AppKit
// routes a real crossing to them from its tracking area, and an enter/exit
// event built by hand carries no tracking area to be routed by.
//
// x and y are view points, top-left origin, like everything else here.

- (NSPoint)windowPointForViewX:(double)x y:(double)y {
  return [self.hostView convertPoint:NSMakePoint(x, y) toView:nil];
}

- (NSString *)decodeSynthText:(NSString *)field {
  if ([field isEqualToString:@"-"]) return @"";
  NSData *bytes = [[NSData alloc] initWithBase64EncodedString:field options:0];
  if (bytes == nil) return nil;
  return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

- (void)synthesize:(NSString *)command {
  NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
  NSString *verb = parts.firstObject;
  NSEvent *event = nil;
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  NSInteger number = self.window.windowNumber;
  if ([verb isEqualToString:@"SYNTH_IME"] && parts.count >= 3) {
    // SYNTH_IME mark <b64> <selectedLocation> | SYNTH_IME commit <b64>:
    // what an input method calls, called directly, because no input method
    // that marks text is guaranteed to be installed. A US layout's dead keys
    // are one, and the runner's input smoke reaches them through keys.
    NSString *text = [self decodeSynthText:parts[2]];
    if (text == nil) {
      [self printError:@"BAD_SYNTH_TEXT"];
    } else if ([parts[1] isEqualToString:@"mark"] && parts.count == 4) {
      [self.hostView setMarkedText:text
                     selectedRange:NSMakeRange((NSUInteger)parts[3].integerValue, 0)
                  replacementRange:NSMakeRange(NSNotFound, 0)];
    } else if ([parts[1] isEqualToString:@"commit"]) {
      [self.hostView insertText:text
               replacementRange:NSMakeRange(NSNotFound, 0)];
    } else if ([parts[1] isEqualToString:@"replace"] && parts.count == 5) {
      // SYNTH_IME replace <b64> <location> <length>: what the press-and-hold
      // accent menu calls when a variant is picked.
      [self.hostView
                insertText:text
          replacementRange:NSMakeRange((NSUInteger)parts[3].integerValue,
                                       (NSUInteger)parts[4].integerValue)];
    } else {
      [self printError:@"BAD_SYNTH_IME"];
    }
    return;
  }
  if ([verb isEqualToString:@"SYNTH_A11Y_PRESS"] && parts.count == 2) {
    // SYNTH_A11Y_PRESS <label-b64>: what VoiceOver's activate does to the
    // first element with that label - accessibilityPerformPress.
    NSString *label = [self decodeSynthText:parts[1]];
    NSMutableArray *queue =
        [NSMutableArray arrayWithArray:self.hostView.a11yRoots ?: @[]];
    BOOL pressed = NO;
    while (queue.count > 0 && !pressed) {
      DartUiA11yElement *element = queue.firstObject;
      [queue removeObjectAtIndex:0];
      if ([element.accessibilityLabel isEqualToString:label]) {
        pressed = [element accessibilityPerformPress];
        break;
      }
      [queue addObjectsFromArray:element.childElements ?: @[]];
    }
    printf("A11Y_DUMP=PRESS:%s\n", pressed ? "YES" : "NO");
    fflush(stdout);
    return;
  }
  if ([verb isEqualToString:@"SYNTH_A11Y_DUMP"]) {
    [self dumpAccessibility:[self.hostView accessibilityChildren] depth:0];
    printf("A11Y_DUMP=END\n");
    fflush(stdout);
    return;
  }
  if ([verb isEqualToString:@"SYNTH_DRAG"] && parts.count == 7) {
    // SYNTH_DRAG <enter|over|leave|drop> <x> <y> <mask> <paths-b64|-> <text-b64|->
    // paths are newline-separated, then base64. The pasteboard is kept across
    // the phases of one drag, as AppKit keeps the drag pasteboard.
    if ([parts[1] isEqualToString:@"enter"]) {
      self.synthDrag = [[DartUiSynthDraggingInfo alloc] init];
      self.synthDrag.window = self.window;
      self.synthDrag.pasteboard = [NSPasteboard pasteboardWithUniqueName];
      [self.synthDrag.pasteboard clearContents];
      NSString *paths = [self decodeSynthText:parts[5]];
      NSString *text = [self decodeSynthText:parts[6]];
      NSMutableArray *items = [NSMutableArray array];
      for (NSString *path in [paths componentsSeparatedByString:@"\n"]) {
        if (path.length > 0) [items addObject:[NSURL fileURLWithPath:path]];
      }
      if (text.length > 0) [items addObject:text];
      [self.synthDrag.pasteboard writeObjects:items];
    }
    DartUiSynthDraggingInfo *info = self.synthDrag;
    if (info == nil) {
      [self printError:@"BAD_SYNTH_DRAG"];
      return;
    }
    info.location = [self windowPointForViewX:parts[2].doubleValue
                                            y:parts[3].doubleValue];
    info.mask = (NSDragOperation)parts[4].longLongValue;
    NSString *phase = parts[1];
    if ([phase isEqualToString:@"enter"]) {
      [self.hostView draggingEntered:info];
    } else if ([phase isEqualToString:@"over"]) {
      [self.hostView draggingUpdated:info];
    } else if ([phase isEqualToString:@"leave"]) {
      [self.hostView draggingExited:info];
      self.synthDrag = nil;
    } else {
      if ([self.hostView prepareForDragOperation:info]) {
        [self.hostView performDragOperation:info];
      }
      self.synthDrag = nil;
    }
    return;
  }
  if ([verb isEqualToString:@"SYNTH_POINTER"] && parts.count == 2) {
    if ([parts[1] isEqualToString:@"enter"]) {
      [self.hostView mouseEntered:[NSApp currentEvent]];
    } else {
      [self.hostView mouseExited:[NSApp currentEvent]];
    }
    return;
  }
  if ([verb isEqualToString:@"SYNTH_MOUSE"] && parts.count == 7) {
    NSString *phase = parts[1];
    NSInteger button = parts[4].integerValue;
    NSEventType type;
    if ([phase isEqualToString:@"move"]) {
      type = NSEventTypeMouseMoved;
    } else if ([phase isEqualToString:@"drag"]) {
      type = button == 0 ? NSEventTypeLeftMouseDragged
           : button == 1 ? NSEventTypeRightMouseDragged
                         : NSEventTypeOtherMouseDragged;
    } else if ([phase isEqualToString:@"down"]) {
      type = button == 0 ? NSEventTypeLeftMouseDown
           : button == 1 ? NSEventTypeRightMouseDown
                         : NSEventTypeOtherMouseDown;
    } else {
      type = button == 0 ? NSEventTypeLeftMouseUp
           : button == 1 ? NSEventTypeRightMouseUp
                         : NSEventTypeOtherMouseUp;
    }
    event = [NSEvent mouseEventWithType:type
                               location:[self windowPointForViewX:parts[2].doubleValue
                                                                y:parts[3].doubleValue]
                          modifierFlags:(NSEventModifierFlags)parts[6].longLongValue
                              timestamp:now
                           windowNumber:number
                                context:nil
                            eventNumber:0
                             clickCount:parts[5].integerValue
                               pressure:type == NSEventTypeMouseMoved ? 0.0 : 1.0];
    if (event != nil) {
      // mouseEventWithType: has no buttonNumber argument and leaves it 0 even
      // for a right-button type, so the number goes through Quartz.
      CGEventRef quartz = CGEventCreateCopy(event.CGEvent);
      CGEventSetIntegerValueField(quartz, kCGMouseEventButtonNumber, button);
      event = [NSEvent eventWithCGEvent:quartz];
      CFRelease(quartz);
    }
  } else if ([verb isEqualToString:@"SYNTH_KEY"] && parts.count == 6) {
    NSString *characters = [self decodeSynthText:parts[4]];
    NSString *ignoring = [self decodeSynthText:parts[5]];
    if (characters == nil || ignoring == nil) {
      [self printError:@"BAD_SYNTH_TEXT"];
      return;
    }
    unsigned short keyCode = (unsigned short)parts[2].integerValue;
    NSEventModifierFlags flags = (NSEventModifierFlags)parts[3].longLongValue;
    BOOL down = [parts[1] isEqualToString:@"down"];
    NSEventType type = down ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    if (modifierFlagForKeyCode(keyCode) != 0) {
      // A modifier key alone is FlagsChanged, whose direction is the flag.
      CGEventRef quartz = CGEventCreateKeyboardEvent(NULL, keyCode, down);
      CGEventSetFlags(quartz, (CGEventFlags)flags);
      event = [NSEvent eventWithCGEvent:quartz];
      CFRelease(quartz);
    } else {
      event = [NSEvent keyEventWithType:type
                               location:NSZeroPoint
                          modifierFlags:flags
                              timestamp:now
                           windowNumber:number
                                context:nil
                             characters:characters
            charactersIgnoringModifiers:ignoring
                              isARepeat:NO
                                keyCode:keyCode];
    }
  } else if ([verb isEqualToString:@"SYNTH_SCROLL"] && parts.count == 6) {
    BOOL precise = parts[5].integerValue != 0;
    CGEventRef quartz = CGEventCreateScrollWheelEvent2(
        NULL, precise ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine, 2,
        (int32_t)parts[4].doubleValue, (int32_t)parts[3].doubleValue, 0);
    NSPoint windowPoint = [self windowPointForViewX:parts[1].doubleValue
                                                  y:parts[2].doubleValue];
    NSPoint screenPoint = [self.window convertPointToScreen:windowPoint];
    CGEventSetLocation(quartz,
                       CGPointMake(screenPoint.x, [self desktopTop] - screenPoint.y));
    CGEventSetIntegerValueField(quartz, kCGMouseEventWindowUnderMousePointer,
                                number);
    CGEventSetIntegerValueField(
        quartz, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        number);
    event = [NSEvent eventWithCGEvent:quartz];
    CFRelease(quartz);
  }
  if (event == nil) {
    [self printError:@"BAD_SYNTH"];
    return;
  }
  [NSApp postEvent:event atStart:NO];
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
  NSRect outer =
      [self frameRectForContentTopLeftX:x y:y width:width height:height];
  [self.window setFrame:outer display:YES];
  // Reported here and not left to windowDidMove:, which AppKit does not send
  // for a window that is not on screen. Application.openPopup places the
  // popup while it is still hidden - it has to, or it would flash at the
  // wrong place - so without this the Dart side kept the position the hidden
  // window was created at (0,31 measured) while the panel itself sat exactly
  // where it was asked to be.
  [self reportMoved];
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
  } else if ([command hasPrefix:@"IME_CARET "]) {
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    if (parts.count == 5) {
      self.hostView.caretRect =
          NSMakeRect(parts[1].doubleValue, parts[2].doubleValue,
                     parts[3].doubleValue, parts[4].doubleValue);
    } else {
      [self printError:@"BAD_IME_CARET"];
    }
  } else if ([command isEqualToString:@"A11Y_BEGIN"]) {
    self.hostView.a11yPending = [NSMutableDictionary dictionary];
    self.hostView.a11yPendingRoots = [NSMutableArray array];
  } else if ([command hasPrefix:@"A11Y_NODE "]) {
    [self accessibilityNode:[command componentsSeparatedByString:@" "]];
  } else if ([command isEqualToString:@"A11Y_END"]) {
    DartUiHostView *view = self.hostView;
    if (view.a11yPendingRoots != nil) {
      view.a11yRoots = [view.a11yPendingRoots copy];
      view.a11yPending = nil;
      view.a11yPendingRoots = nil;
      NSAccessibilityPostNotification(view,
                                      NSAccessibilityLayoutChangedNotification);
    }
  } else if ([command hasPrefix:@"DRAG_START "]) {
    // DRAG_START <request> <mask> <paths-b64|-> <text-b64|->, paths
    // newline-separated before the base64.
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    NSString *paths = parts.count == 5 ? [self decodeSynthText:parts[3]] : nil;
    NSString *text = parts.count == 5 ? [self decodeSynthText:parts[4]] : nil;
    if (paths == nil || text == nil) {
      [self printError:@"BAD_DRAG_START"];
    } else {
      NSMutableArray<NSString *> *list = [NSMutableArray array];
      for (NSString *path in [paths componentsSeparatedByString:@"\n"]) {
        if (path.length > 0) [list addObject:path];
      }
      [self.hostView startDragRequest:parts[1].longLongValue
                                 mask:(NSDragOperation)parts[2].longLongValue
                                paths:list
                                 text:text];
    }
  } else if ([command hasPrefix:@"IME_SURROUNDING "]) {
    // IME_SURROUNDING <base64|-> <anchor> <cursor>, offsets in UTF-16 units.
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    NSString *text = parts.count == 4 ? [self decodeSynthText:parts[1]] : nil;
    if (text == nil) {
      [self printError:@"BAD_IME_SURROUNDING"];
    } else {
      NSUInteger anchor = MIN((NSUInteger)MAX(parts[2].integerValue, 0),
                              text.length);
      NSUInteger cursor = MIN((NSUInteger)MAX(parts[3].integerValue, 0),
                              text.length);
      self.hostView.surroundingText = text;
      self.hostView.surroundingSelection =
          NSMakeRange(MIN(anchor, cursor),
                      MAX(anchor, cursor) - MIN(anchor, cursor));
    }
  } else if ([command isEqualToString:@"DROP_REGISTER"]) {
    [self.hostView registerForDraggedTypes:@[
      NSPasteboardTypeFileURL, NSPasteboardTypeString
    ]];
  } else if ([command isEqualToString:@"DROP_UNREGISTER"]) {
    [self.hostView unregisterDraggedTypes];
  } else if ([command hasPrefix:@"DROP_RESPONSE "]) {
    self.hostView.dropOperation =
        (NSDragOperation)[[command substringFromIndex:14] longLongValue];
  } else if ([command isEqualToString:@"IME_CANCEL"]) {
    // Escape inside a preedit, or the field losing focus: the provisional
    // text is dropped, not committed.
    [self.hostView.inputContext discardMarkedText];
    [self.hostView unmarkText];
  } else if ([command hasPrefix:@"SYNTH_"]) {
    [self synthesize:command];
  } else if ([command hasPrefix:@"CLIPBOARD_READ "]) {
    [self readClipboard:command];
  } else if ([command hasPrefix:@"CLIPBOARD_APPEND "]) {
    [self appendClipboard:command];
  } else if ([command hasPrefix:@"CLIPBOARD_WRITE "]) {
    [self writeClipboard:command];
  } else if ([command isEqualToString:@"SHOW"]) {
    BOOL isTransient = [self.windowKind isEqualToString:@"popup"] ||
                       [self.windowKind isEqualToString:@"tooltip"];
    if (isTransient) [self.window orderFront:nil];
    else [self.window makeKeyAndOrderFront:nil];
  } else if ([command isEqualToString:@"INSPECT_WINDOW"]) {
    printf("WINDOW_INSPECT=%s:%s:%llu:%ld:%d:%d:%ld\n",
           self.windowKind.UTF8String,
           NSStringFromClass(self.window.class).UTF8String,
           (unsigned long long)self.window.styleMask,
           (long)self.window.level,
           self.window.isKeyWindow ? 1 : 0,
           self.window.ignoresMouseEvents ? 1 : 0,
           (long)NSApp.activationPolicy);
    fflush(stdout);
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
  [self reportMoved];
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
    delegate.windowKind = @"normal";
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
      } else if (strcmp(argument, "--window-kind") == 0 && index + 1 < argc) {
        NSString *kind = [NSString stringWithUTF8String:argv[++index]];
        if (![kind isEqualToString:@"normal"] &&
            ![kind isEqualToString:@"dialog"] &&
            ![kind isEqualToString:@"popup"] &&
            ![kind isEqualToString:@"tooltip"]) return 64;
        delegate.windowKind = kind;
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
    BOOL isTransient = [delegate.windowKind isEqualToString:@"popup"] ||
                       [delegate.windowKind isEqualToString:@"tooltip"];
    // Each window has its own host process. A Regular activation policy would
    // consequently put every open submenu in the Dock and application
    // switcher; Accessory keeps the process alive and interactive without
    // pretending that the popup is an application of its own.
    [application setActivationPolicy:isTransient
        ? NSApplicationActivationPolicyAccessory
        : NSApplicationActivationPolicyRegular];
    [application run];
  }
  return 0;
}
