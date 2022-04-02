//
//  iTermStatusBarLargeComposerViewController.m
//  iTerm2
//
//  Created by George Nachman on 8/12/18.
//

#import "iTermStatusBarLargeComposerViewController.h"

#import "CommandHistoryPopup.h"
#import "NSDate+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSEvent+iTerm.h"
#import "NSResponder+iTerm.h"
#import "NSStringITerm.h"
#import "NSView+iTerm.h"
#import "PasteboardHistory.h"
#import "SolidColorView.h"
#import "VT100RemoteHost.h"
#import "WindowControllerInterface.h"
#import "iTermCommandHistoryEntryMO+CoreDataProperties.h"
#import "iTermPopupWindowController.h"
#import "iTermShellHistoryController.h"
#import "iTermSlowOperationGateway.h"
#import "iTermTextPopoverViewController.h"
#import "iTermWarning.h"

@interface iTermComposerView : NSView
@end
@implementation iTermComposerView {
    NSView *_backgroundView;
}

- (NSView *)newBackgroundViewWithFrame:(NSRect)frame {
    NSVisualEffectView *myView = [[NSVisualEffectView alloc] initWithFrame:frame];
    myView.appearance = self.appearance;
    return myView;
}

- (NSView *)hitTest:(NSPoint)point {
    NSView *result = [super hitTest:point];
    NSLog(@"%@ -> %@", NSStringFromPoint(point), result);
    return result;
}

- (void )viewDidMoveToWindow {
    [self updateBackgroundView];
    [super viewDidMoveToWindow];
}

- (void)updateBackgroundView {
    if ([NSStringFromClass(self.window.class) containsString:@"Popover"]) {
        NSView *privateView = [[self.window contentView] superview];
        [_backgroundView removeFromSuperview];
        _backgroundView = [self newBackgroundViewWithFrame:privateView.bounds];
        _backgroundView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [privateView addSubview:_backgroundView positioned:NSWindowBelow relativeTo:privateView];
    }
}

- (void)setAppearance:(NSAppearance *)appearance {
    if (appearance != self.appearance) {
        [super setAppearance:appearance];
        [self updateBackgroundView];
    }
}

@end

@interface iTermStatusBarLargeComposerViewController ()<PopupDelegate, iTermPopupWindowPresenter, NSTextViewDelegate>

@end

@interface iTermSearchPathsCacheEntry: NSObject
@property (nonatomic, copy) NSArray<NSString *> *paths;
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) BOOL ready;
@end

@implementation iTermSearchPathsCacheEntry
@end

@implementation iTermStatusBarLargeComposerViewController {
    IBOutlet NSButton *_help;
    CommandHistoryPopupWindowController *_historyWindowController;
    NSInteger _completionGeneration;
    iTermTextPopoverViewController *_popoverVC;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    self.textView.textColor = [NSColor textColor];
    self.textView.font = [NSFont fontWithName:@"Menlo" size:11];
}

- (NSMutableDictionary<NSString *, iTermSearchPathsCacheEntry *> *)cache {
    static NSMutableDictionary<NSString *, iTermSearchPathsCacheEntry *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

- (IBAction)pasteOptions:(id)sender {
    NSString *content = self.textView.string;
    if (!content) {
        return;
    }
    [self.textView.composerDelegate composerTextViewSendToAdvancedPaste:content];
}

- (void)setShell:(NSString *)shell {
    _shell = [shell copy];

    iTermSearchPathsCacheEntry *entry = self.cache[shell];
    if (entry) {
        if ([NSDate it_timeSinceBoot] - entry.timestamp < 60) {
            return;
        }
    } else {
        entry = [[iTermSearchPathsCacheEntry alloc] init];
        entry.timestamp = [NSDate it_timeSinceBoot];
        self.cache[shell] = entry;
    }
    [[iTermSlowOperationGateway sharedInstance] exfiltrateEnvironmentVariableNamed:@"PATH"
                                                                             shell:shell
                                                                        completion:^(NSString * _Nonnull value) {
        NSArray<NSString *> *paths = [value componentsSeparatedByString:@":"];
        if (paths && !entry.ready) {
            entry.paths = paths;
            entry.ready = YES;
        }
    }];
}

- (NSString *)lineBeforeCursor {
    NSString *content = self.textView.string;
    const NSRange selectedRange = [self.textView selectedRange];
    if (selectedRange.location > content.length) {
        return @"";
    }

    NSInteger lowerBound = [content rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                                       options:NSBackwardsSearch
                                                         range:NSMakeRange(0, selectedRange.location)].location;
    if (lowerBound == NSNotFound) {
        lowerBound = 0;
    } else {
        lowerBound += 1;
    }
    const NSInteger upperBound = self.textView.selectedRange.location;
    return [content substringWithRange:NSMakeRange(lowerBound, upperBound - lowerBound)];
}

- (NSString *)lineAtCursor {
    NSString *content = self.textView.string;
    const NSRange selectedRange = [self.textView selectedRange];
    if (selectedRange.location > content.length) {
        return @"";
    }

    NSInteger lowerBound = [content rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                                       options:NSBackwardsSearch
                                                         range:NSMakeRange(0, selectedRange.location)].location;
    if (lowerBound == NSNotFound) {
        lowerBound = 0;
    } else {
        lowerBound += 1;
    }
    NSInteger upperBound = [content rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                                    options:0
                                                      range:NSMakeRange(lowerBound, content.length - lowerBound)].location;
    if (upperBound == NSNotFound) {
        upperBound = content.length;
    }
    return [content substringWithRange:NSMakeRange(lowerBound, upperBound - lowerBound)];
}

- (void)openCommandHistory:(id)sender {
    [self.textView setSuggestion:nil];
    if (!_historyWindowController) {
        _historyWindowController = [[CommandHistoryPopupWindowController alloc] initForAutoComplete:NO];
    }
    if ([[iTermShellHistoryController sharedInstance] commandHistoryHasEverBeenUsed]) {
        NSString *prefix;
        NSString *content = self.textView.string;
        const NSRange selectedRange = [self.textView selectedRange];
        if (selectedRange.location > content.length) {
            return;
        }
        const NSInteger newlineBefore = [content rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]
                                                                 options:NSBackwardsSearch
                                                                   range:NSMakeRange(0, selectedRange.location)].location;
        if (newlineBefore == NSNotFound) {
            prefix = [content substringToIndex:selectedRange.location];
        } else {
            prefix = [content substringWithRange:NSMakeRange(newlineBefore + 1, selectedRange.location - newlineBefore - 1)];
        }
        [_historyWindowController popWithDelegate:self inWindow:self.view.window];
        [_historyWindowController loadCommands:[_historyWindowController commandsForHost:self.host
                                                                          partialCommand:prefix
                                                                                  expand:YES]
                                partialCommand:prefix];
    } else {
        [iTermShellHistoryController showInformationalMessage];
    }
}

- (BOOL)helpShouldBeAvailable {
    return [[self lineAtCursor] length] > 0 && [[self browserName] length] > 0;
}

- (NSString *)browserName {
    NSURL *appUrl = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"https://explainshell.com/explain?cmd=example"]];
    if (!appUrl) {
        return nil;
    }
    NSBundle *bundle = [NSBundle bundleWithURL:appUrl];
    return [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: [[appUrl URLByDeletingPathExtension] lastPathComponent];
}

- (void)explainHelpButton {
    [_popoverVC.popover close];
    _popoverVC = [[iTermTextPopoverViewController alloc] initWithNibName:@"iTermTextPopoverViewController"
                                                                  bundle:[NSBundle bundleForClass:self.class]];
    _popoverVC.popover.behavior = NSPopoverBehaviorTransient;
    [_popoverVC view];
    _popoverVC.textView.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    _popoverVC.textView.drawsBackground = NO;
    [_popoverVC appendString:@"Enter a command in the composer and select the help button to open it in explainshell.com."];
    NSRect frame = _popoverVC.view.frame;
    frame.size.width = 300;
    frame.size.height = 42;
    _popoverVC.view.frame = frame;
    [_popoverVC.popover showRelativeToRect:_help.bounds
                                    ofView:_help
                             preferredEdge:NSRectEdgeMaxY];
}


- (IBAction)help:(id)sender {
    if (!self.helpShouldBeAvailable) {
        [self explainHelpButton];
    }
    NSString *command = [self lineAtCursor];
    if (!command.length) {
        return;
    }
    NSString *browserName = [self browserName];
    if (!browserName.length) {
        return;
    }
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.host = @"explainshell.com";
    components.scheme = @"https";
    components.path = @"/explain";
    components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"cmd" value:command] ];
    NSURL *url = components.URL;

    const iTermWarningSelection selection = [iTermWarning showWarningWithTitle:[NSString stringWithFormat:@"This will open %@ in %@.", url.absoluteString, browserName]
                                                                       actions:@[ @"OK", @"Cancel" ]
                                                                 actionMapping:nil
                                                                     accessory:nil
                                                                    identifier:@"NoSyncExplainShell"
                                                                   silenceable:kiTermWarningTypePermanentlySilenceable
                                                                       heading:@"Open ExplainShell?"
                                                                        window:self.view.window];
    if (selection == kiTermWarningSelection0) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}


#pragma mark - PopupDelegate

- (NSRect)popupScreenVisibleFrame {
    return self.view.window.screen.visibleFrame;
}

- (VT100Screen *)popupVT100Screen {
    return nil;
}

- (id<iTermPopupWindowPresenter>)popupPresenter {
    return self;
}

- (void)popupInsertText:(NSString *)text {
    [self.textView insertText:text replacementRange:self.textView.selectedRange];
}

- (void)popupKeyDown:(NSEvent *)event {
    [self.textView keyDown:event];
}

- (BOOL)popupHandleSelector:(SEL)selector string:(NSString *)string currentValue:(NSString *)currentValue {
    return NO;
}

- (void)popupWillClose:(iTermPopupWindowController *)popup {
    _historyWindowController = nil;
}

- (BOOL)popupWindowIsInFloatingHotkeyWindow {
    id<iTermWindowController> windowController = (id<iTermWindowController>)self.view.window.delegate;
    if ([windowController conformsToProtocol:@protocol(iTermWindowController)]) {
        return [windowController isFloatingHotKeyWindow];
    }
    return NO;
}

- (void)popupIsSearching:(BOOL)searching {
}

#pragma mark - iTermPopupWindowPresenter

- (void)popupWindowWillPresent:(iTermPopupWindowController *)popupWindowController {
}

- (NSRect)popupWindowOriginRectInScreenCoords {
    NSRange range = [self.textView selectedRange];
    range.length = 0;
    return [self.textView firstRectForCharacterRange:range actualRange:NULL];
}

#pragma mark - NSTextViewDelegate

- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (self.textView.isSettingSuggestion) {
        return;
    }
    _completionGeneration += 1;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf.textView setSuggestion:nil];
    });
}

- (NSString *)historySuggestionForPrefix:(NSString *)prefix {
    NSArray<iTermCommandHistoryEntryMO *> *entries =
    [[iTermShellHistoryController sharedInstance] commandHistoryEntriesWithPrefix:prefix
                                                                           onHost:self.host];
    return [entries.firstObject.command copy];
}

// NOTE: This must not change the suggestion directly. It has to do it in dispatch_async because
// otherwise NSTextView throws exceptions.
- (void)textDidChange:(NSNotification *)notification {
    _completionGeneration += 1;
    if (self.textView.isSettingSuggestion) {
        return;
    }
    [self.textView setSuggestion:nil];

    NSString *command = [self lineBeforeCursor];
    if (command.length == 0) {
        return;
    }
    NSString *historySuggestion = [self historySuggestionForPrefix:command];
    if (historySuggestion) {
        __weak __typeof(self) weakSelf = self;
        const NSInteger generation = ++_completionGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf didFindCompletions:@[[historySuggestion substringFromIndex:command.length]]
                           forGeneration:generation
                                  escape:NO];
        });
        return;
    }

    if (![self.host isLocalhost] || self.tmuxController) {
        // Don't try to complete filenames if not on localhost. Completion on tmux is possible in
        // theory but likely to be very slow because of the amount of data that would need to be
        // exchanged.
        [self.textView setSuggestion:nil];
        return;
    }

    NSArray<NSString *> *words = [command componentsInShellCommand];
    const BOOL onFirstWord = words.count < 2;
    NSString *const prefix = words.lastObject;
    const NSInteger generation = ++_completionGeneration;
    NSArray<NSString *> *directories;
    if (onFirstWord) {
        iTermSearchPathsCacheEntry *entry = self.cache[self.shell];
        NSArray<NSString *> *paths = nil;
        if (entry.ready) {
            paths = entry.paths;
        }
        directories = paths ?: @[self.workingDirectory ?: NSHomeDirectory()];
    } else {
        directories = @[self.workingDirectory ?: NSHomeDirectory()];
    }
    __weak __typeof(self) weakSelf = self;
    [[iTermSlowOperationGateway sharedInstance] findCompletionsWithPrefix:prefix
                                                            inDirectories:directories
                                                                      pwd:self.workingDirectory
                                                                 maxCount:1
                                                               executable:onFirstWord
                                                               completion:^(NSArray<NSString *> * _Nonnull completions) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf didFindCompletions:completions
                           forGeneration:generation
                                  escape:YES];
        });
    }];
}

- (void)didFindCompletions:(NSArray<NSString *> *)completions
             forGeneration:(NSInteger)generation
                    escape:(BOOL)shouldEscape {
    if ([_historyWindowController.window isVisible]) {
        return;
    }
    if (generation != _completionGeneration) {
        return;
    }
    if (completions.count == 0) {
        return;
    }
    if (shouldEscape) {
        self.textView.suggestion = [completions.firstObject stringWithBackslashEscapedShellCharactersIncludingNewlines:YES];
    } else {
        self.textView.suggestion = completions.firstObject;
    }
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (self.textView.hasSuggestion &&
        commandSelector == @selector(insertTab:)) {
        [self.textView acceptSuggestion];
        return YES;
    }

    if (commandSelector == @selector(deleteForward:) ||
        commandSelector == @selector(deleteBackward:) ||
        commandSelector == @selector(deleteBackwardByDecomposingPreviousCharacter:) ||
        commandSelector == @selector(deleteWordForward:) ||
        commandSelector == @selector(deleteWordBackward:) ||
        commandSelector == @selector(deleteToBeginningOfLine:) ||
        commandSelector == @selector(deleteToEndOfLine:) ||
        commandSelector == @selector(deleteToBeginningOfParagraph:) ||
        commandSelector == @selector(deleteToEndOfParagraph:) ||
        commandSelector == @selector(deleteToMark:)) {
        [self.textView setSuggestion:nil];
    }

    return NO;
}

@end
