import Foundation
import Testing

@testable import Porpoise

@MainActor @Suite struct MainActorDeliveryTests {
    private final class State {
        var values: [Int] = []
    }

    @Test func mainThreadDeliveryIsSynchronous() {
        let state = State()
        MainActorDelivery.deliver { state.values.append(1) }
        #expect(state.values == [1])
    }

    @Test func callbackThreadDeliveryArrivesOnMainInOrder() async {
        let state = State()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for value in 0..<100 {
                    MainActorDelivery.deliver {
                        #expect(Thread.isMainThread)
                        state.values.append(value)
                    }
                }
                MainActorDelivery.deliver { continuation.resume() }
            }
        }
        #expect(state.values == Array(0..<100))
    }
}
