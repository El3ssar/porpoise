import Foundation
import PorpoiseCore
import Testing

@testable import PorpoiseServices

@MainActor @Suite struct JobEnvironmentMonitorTests {
    @Test func noticesAreSynchronousOnMainAndUnregisterStopsDelivery() {
        let monitor = JobEnvironmentMonitor(monitorsNetwork: false)
        let control = JobControl()
        var notices: [String?] = []
        monitor.register(control, network: true) {
            #expect(Thread.isMainThread)
            notices.append($0)
        }
        #expect(notices == [nil])
        monitor.setOnline(false)
        #expect(notices == [nil, "Waiting for network"])
        monitor.setSleeping(true)
        #expect(notices == [nil, "Waiting for network", "Waiting for wake"])
        monitor.unregister(control)
        monitor.setSleeping(false)
        monitor.setOnline(true)
        #expect(notices == [nil, "Waiting for network", "Waiting for wake"])
    }

    @Test func jobsRegisteredDuringSleepInheritBothIndependentHolds() {
        let monitor = JobEnvironmentMonitor(monitorsNetwork: false)
        monitor.setSleeping(true)
        monitor.setOnline(false)
        let local = JobControl(), remote = JobControl()
        var localNotice: String?, remoteNotice: String?
        monitor.register(local, network: false) { localNotice = $0 }
        monitor.register(remote, network: true) { remoteNotice = $0 }
        #expect(local.isPaused && remote.isPaused)
        #expect(localNotice == "Waiting for wake" && remoteNotice == "Waiting for wake")
        monitor.setSleeping(false)
        #expect(!local.isPaused && remote.isPaused)
        #expect(localNotice == nil && remoteNotice == "Waiting for network")
        monitor.setOnline(true)
        #expect(!remote.isPaused && remoteNotice == nil)
    }

    @Test func releasingTheMonitorClearsItsHoldsButKeepsManualPause() {
        let automatic = JobControl(), manual = JobControl()
        var monitor: JobEnvironmentMonitor? = JobEnvironmentMonitor(monitorsNetwork: false)
        monitor?.register(automatic, network: true) { _ in }
        monitor?.register(manual, network: true) { _ in }
        manual.pause()
        monitor?.setSleeping(true)
        monitor?.setOnline(false)
        #expect(automatic.isPaused && manual.isPaused)
        monitor = nil
        #expect(!automatic.isPaused && manual.isPaused)
        manual.resume()
        #expect(!manual.isPaused)
    }
}
