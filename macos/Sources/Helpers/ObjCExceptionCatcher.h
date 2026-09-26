#import <Foundation/Foundation.h>

/// This file contains wrappers around various ObjC functions so we can catch
/// exceptions, since you can't natively catch ObjC exceptions from Swift
/// (at least at the time of writing this comment).

/// NSWindow.addTabbedWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyAddTabbedWindowSafely(
    id _Nonnull parent,
    id _Nonnull child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
);

/// NSWindowController.showWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyShowWindowSafely(
    id _Nonnull controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);

/// Runs any block under an Objective-C exception catcher, for AppKit calls
/// without a dedicated wrapper (NSWindowTabGroup.addWindow, orderOut, ...).
FOUNDATION_EXPORT BOOL GhosttyPerformSafely(
    void (NS_NOESCAPE ^ _Nonnull block)(void),
    NSError * _Nullable * _Nullable error
);
