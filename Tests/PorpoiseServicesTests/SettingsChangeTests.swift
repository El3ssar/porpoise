import Darwin
import Foundation
import PorpoiseServicesTestSupport
import Testing
import os

@testable import PorpoiseServices

@Suite(.isolatedSettings) struct SettingsChangeTests {
    @Test func decodingKeepsRawKeysAndDistinguishesBroadcastFromMalformedObjects() {
        #expect(SettingsChange(Notification(name: Settings.changed)) == .all)
        for key in ["confirmTrash", "future.setting", ""] {
            #expect(SettingsChange(Notification(name: Settings.changed, object: key)) == .key(key))
        }
        #expect(SettingsChange(Notification(name: Settings.changed, object: NSString(string: "bridged"))) == .key("bridged"))
        #expect(SettingsChange(Notification(name: Settings.changed, object: 42)) == nil)
        #expect(SettingsChange(Notification(name: Notification.Name("unrelated"), object: "confirmTrash")) == nil)
    }

    @Test func postingUsesTheSameRawPayloadSynchronouslyOnThePostingThread() {
        let center = NotificationCenter()
        let changes = OSAllocatedUnfairLock(initialState: [SettingsChange?]())
        let thread = pthread_mach_thread_np(pthread_self())
        let token = center.addObserver(forName: nil, object: nil, queue: nil) { note in
            #expect(pthread_mach_thread_np(pthread_self()) == thread)
            #expect(note.name == Settings.changed && note.userInfo == nil)
            changes.withLock { $0.append(SettingsChange(note)) }
        }
        defer { center.removeObserver(token) }
        SettingsChange.key("future.setting").post(to: center)
        #expect(changes.withLock { $0 } == [.key("future.setting")])
        SettingsChange.all.post(to: center)
        #expect(changes.withLock { $0 } == [.key("future.setting"), .all])
    }

    @Test func centralPublishersNotifyOnceAfterStoringAndResetStillBroadcasts() {
        let changes = OSAllocatedUnfairLock(initialState: [SettingsChange?]())
        let expected: [SettingsChange] = [.key("confirmTrash"), .key("ctx.duplicate"), .all]
        let token = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: nil) { note in
            guard let change = SettingsChange(note), expected.contains(change) else { return }
            changes.withLock { $0.append(change) }
            switch change {
            case .key("confirmTrash"): #expect(Settings.store.bool(forKey: "confirmTrash"))
            case .key("ctx.duplicate"): #expect(Settings.store.object(forKey: "ctx.duplicate") as? Bool == false)
            case .all: #expect(Settings.store.object(forKey: "confirmTrash") == nil)
            default: break
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        SettingsChange.key("unrelated.fixture").post()
        #expect(changes.withLock { $0.isEmpty })
        Settings.shared.confirmTrash = true
        #expect(changes.withLock { $0 } == [.key("confirmTrash")])
        Settings.shared.setContextMenu(.duplicate, false)
        #expect(changes.withLock { $0 } == [.key("confirmTrash"), .key("ctx.duplicate")])
        Settings.shared.resetAll()
        #expect(changes.withLock { $0 } == [.key("confirmTrash"), .key("ctx.duplicate"), .all])
    }
}
