#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "SidekeyTestBootstrap.h"

// SwiftPM test bundles have no principal class, and Swift has no load-time
// hook, so this constructor is the one place that runs before the first test
// whatever `--filter` selects. It only hands over to the Swift guards: no
// sound (SystemSoundGuard) and no window on screen (OnScreenWindowGuard).
// WHY: .project-docs/decisions/2026-11-23-silent-test-runs.md
// WHY: .project-docs/decisions/2026-11-24-windowless-test-runs.md
__attribute__((constructor)) static void WhytapTestBootstrap(void) {
    SEL install = NSSelectorFromString(@"installAtLoad");
    for (NSString *name in @[@"WhytapSystemSoundGuard", @"WhytapOnScreenWindowGuard"]) {
        Class guard = NSClassFromString(name);
        if (guard != Nil && [guard respondsToSelector:install]) {
            ((void (*)(id, SEL))objc_msgSend)(guard, install);
        }
    }
}

void WhytapTestBootstrapAnchor(void) {}
