#if PORPOISE_TEST_HOOKS
import AppKit
import ObjectiveC
import PorpoiseServices

/// A test instance never takes focus from the app the person at the Mac is using: activating Porpoise becomes a
/// no-op, so launches, bridge commands and opened windows stay behind the frontmost app. Windows still order
/// front (captures and `reviewfront` work), they just do not become active. PORPOISE_ALLOW_FOCUS=1 restores
/// activation for a run that needs the active look. Compiled only into test builds.
enum FocusGuard {
    static func install() {
        guard Settings.isTesting, ProcessInfo.processInfo.environment["PORPOISE_ALLOW_FOCUS"] != "1" else { return }
        let quiet: @convention(block) (AnyObject) -> Void = { _ in }
        let quietFlag: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        replace(NSApplication.self, "activate", with: quiet)
        replace(NSApplication.self, "activateIgnoringOtherApps:", with: quietFlag)
        ownProcessOnly(NSRunningApplication.self, "activateWithOptions:")
    }

    private static func replace(_ cls: AnyClass, _ name: String, with block: Any) {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)) else { return }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Activating another app (Finder, an editor) still works; only Porpoise itself is kept in the background.
    private static func ownProcessOnly(_ cls: AnyClass, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Activate = @convention(c) (AnyObject, Selector, UInt) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Activate.self)
        let block: @convention(block) (NSRunningApplication, UInt) -> Bool = { app, options in
            app.processIdentifier == getpid() ? false : original(app, selector, options)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
#endif
