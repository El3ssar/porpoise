import AppKit
import Foundation
import PorpoiseHelperKit
import PorpoiseTestSupport
import Security
import Testing

@testable import PorpoiseServices

/// W-245: the authorization Porpoise sends the helper. Kept for as long as a standard approval lasts, so a few actions
/// in a row are approved once; forgotten sooner when the screens sleep or lock, or another user takes over.
@Suite(.serialized) struct HelperAuthorizationTests {
    private func holder(_ workspace: NotificationCenter, _ distributed: NotificationCenter) -> (HelperAuthorization, Locked<Int>, Locked<Date>) {
        let made = Locked(0), clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let h = HelperAuthorization(observing: workspace, distributed: distributed)
        h.now = { clock.value }
        let real = h.make
        h.make = {
            made.change { $0 += 1 }; return real()
        }
        return (h, made, clock)
    }

    @Test func oneAuthorizationForAStandardApprovalsTime() throws {
        let (h, made, clock) = holder(NotificationCenter(), NotificationCenter())
        let first = try #require(h.externalForm())
        #expect(first.count == Int(kAuthorizationExternalFormLength))
        clock.change { $0 += 299 }
        #expect(h.externalForm() == first && made.value == 1)
        clock.change { $0 += 1 }  // 300 s: the approval it held has run out; a new one is made
        let second = try #require(h.externalForm())
        #expect(second != first && made.value == 2)
    }

    @Test(arguments: [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification])
    func forgottenWhenTheMacIsLeft(_ name: Notification.Name) throws {
        let workspace = NotificationCenter()
        let (h, made, _) = holder(workspace, NotificationCenter())
        _ = try #require(h.externalForm())
        workspace.post(name: name, object: nil)
        #expect(!h.holdsOne)
        _ = h.externalForm()
        #expect(made.value == 2)
    }

    @Test func forgottenWhenTheScreenLocks() throws {
        let distributed = NotificationCenter()
        let (h, _, _) = holder(NotificationCenter(), distributed)
        _ = try #require(h.externalForm())
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        #expect(!h.holdsOne)
    }

    /// A cancelled approval is the person's choice: no error, no diagnostic.
    @Test func aCancelledApprovalIsNotAFailure() throws {
        let store = DiagnosticStore()
        #expect(PrivilegedHelper.diagnosed(.cancelled, store: store) == .cancelled)
        #expect(!(try store.preview().text.contains("\"code\"")))
    }
}
