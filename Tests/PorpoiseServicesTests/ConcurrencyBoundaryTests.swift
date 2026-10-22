import Foundation
import Testing
import os

@testable import PorpoiseServices

@Suite struct ConcurrencyBoundaryTests {
    @Test func concurrentCredentialChangesPublishWholePairs() {
        let login = FTPLoginState(user: "0", password: "0")
        let mismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            let value = String(index)
            login.replace(user: value, password: value)
            let snapshot = login.snapshot
            if snapshot.user != snapshot.password { mismatches.withLock { $0 += 1 } }
        }
        #expect(mismatches.withLock { $0 } == 0)
    }

    @Test func concurrentSoundsCreateEachIDOnceAndPlayEveryRequest() {
        let created = OSAllocatedUnfairLock(initialState: [FinderSound: Int]())
        let outputs = OSAllocatedUnfairLock(initialState: [UInt32: Int]())
        let sounds: [FinderSound] = [.moveToTrash, .dragToTrash, .emptyTrash]
        let player = FinderSoundPlayer(
            create: { sound in
                created.withLock { $0[sound, default: 0] += 1 }
                return UInt32(sounds.firstIndex(of: sound)! + 1)
            }, play: { id in outputs.withLock { $0[id, default: 0] += 1 } })
        DispatchQueue.concurrentPerform(iterations: 3_000) { index in player.play(sounds[index % 3], silent: false) }
        #expect(created.withLock { $0 } == Dictionary(uniqueKeysWithValues: sounds.map { ($0, 1) }))
        #expect(outputs.withLock { $0 } == [1: 1_000, 2: 1_000, 3: 1_000])
        player.play(.emptyTrash, silent: true)
        #expect(player.lastPlayed == FinderSound.emptyTrash.rawValue)
        #expect(outputs.withLock { $0.values.reduce(0, +) } == 3_000)
    }

    @Test func silentSoundDoesNotAllocateAnID() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let player = FinderSoundPlayer(
            create: { _ in
                calls.withLock { $0 += 1 }; return 1
            },
            play: { _ in calls.withLock { $0 += 1 } })
        player.play(.moveToTrash, silent: true)
        #expect(calls.withLock { $0 } == 0)
        #expect(player.lastPlayed == FinderSound.moveToTrash.rawValue)
    }
}
