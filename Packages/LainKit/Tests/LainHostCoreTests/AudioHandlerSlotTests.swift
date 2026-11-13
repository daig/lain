import Foundation
@testable import LainHostCore
import Synchronization
import Testing

/// The audio handler is read with every buffer (~47 a second). Kept bare in a `Mutex`, each read wrapped it in
/// two more reabstraction thunks, until calling it (or freeing it) overflowed the stack: the host crashed every
/// ~2¼ minutes while the Mac's sound played on the iPad (2026-11-12).
@Suite struct AudioHandlerSlotTests {
    @Test func readingTheHandlerDoesNotDeepenIt() throws {
        let slot = AudioHandlerSlot()
        let depth = Mutex(0)
        slot.set { _, _ in depth.withLock { $0 = Thread.callStackSymbols.count } }
        try #require(slot.current).call([], 0)
        let first = depth.withLock { $0 }
        // 40 s of buffers: enough to see a chain grow (4,000 frames deeper), not so many that it overflows.
        for _ in 0..<2_000 { _ = slot.current }
        try #require(slot.current).call([], 0)
        #expect(depth.withLock { $0 } == first, "each read must leave the handler as it was")
    }

    @Test func clearingIt() {
        let slot = AudioHandlerSlot()
        slot.set { _, _ in }
        slot.set(nil)
        #expect(slot.current == nil)
    }
}
