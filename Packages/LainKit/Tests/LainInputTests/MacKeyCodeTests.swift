import Testing
@testable import LainInput

@Test func letterAMapsToANSIA() {
    #expect(MacKeyCode.from(hidUsage: 0x04) == 0x00)
    #expect(MacKeyCode.from(hidUsage: 0x00) == nil)
}
