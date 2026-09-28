import Testing
@testable import LainInput

@Suite struct KeyCodes {
    @Test func lettersFollowTheANSILayout() {
        // kVK_ANSI_A … Z, by HID position.
        let expected: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                  0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        #expect((0x04...0x1D).map { MacKeyCode.from(hidUsage: UInt16($0)) } == expected)
    }

    @Test func everyStandardKeyboardUsageMaps() {
        // Letters through keypad ., plus F13–F20 and the modifiers: all have Mac keycodes.
        let ranges: [ClosedRange<UInt16>] = [0x04...0x63, 0x68...0x6F, 0xE0...0xE7]
        for r in ranges {
            for u in r { #expect(MacKeyCode.from(hidUsage: u) != nil, "usage \(u)") }
        }
    }

    @Test func mappingIsInjectiveExceptTheBackslashPair() {
        // HID 0x31 (\) and 0x32 (non-US #) are the same Mac key; F13–F15 are shared with PrtSc/ScrLk/Pause
        // and Insert shares Help.
        var seen: [UInt16: UInt16] = [:]
        let allowedShared: Set<UInt16> = [0x2A, 0x69, 0x6B, 0x71, 0x72]
        for (usage, code) in MacKeyCode.keyboard.sorted(by: { $0.key < $1.key }) {
            if let other = seen[code] {
                #expect(allowedShared.contains(code), "usages \(other) and \(usage) both map to \(code)")
            }
            seen[code] = usage
        }
    }

    @Test func specialKeys() {
        #expect(MacKeyCode.from(.tab) == 0x30)
        #expect(MacKeyCode.from(.space) == 0x31)
        #expect(MacKeyCode.from(.escape) == 0x35)
        #expect(MacKeyCode.from(.key(0x2A)) == 0x33)       // Backspace → kVK_Delete
        #expect(MacKeyCode.from(.key(0x4C)) == 0x75)       // Delete → kVK_ForwardDelete
        #expect(MacKeyCode.from(.key(0x35)) == 0x32)       // ` → kVK_ANSI_Grave
        #expect(MacKeyCode.from(.key(0x3A)) == 0x7A)       // F1
        #expect(MacKeyCode.from(.key(0x45)) == 0x6F)       // F12
        #expect(MacKeyCode.from(.key(0x52)) == 0x7E)       // Up
        #expect(MacKeyCode.from(.key(0x58)) == 0x4C)       // Keypad Enter
        #expect(MacKeyCode.from(.globe) == 0x3F)           // Globe via UIKit → kVK_Function
        #expect(MacKeyCode.from(.appleFn) == 0x3F)
        #expect(MacKeyCode.from(PhysicalKey(page: 0x0C, usage: 0xE9)) == nil)
    }

    @Test func modifiers() {
        #expect(MacKeyCode.from(.leftCommand) == 0x37)
        #expect(MacKeyCode.from(.rightCommand) == 0x36)
        #expect(MacKeyCode.from(.leftOption) == 0x3A)
        #expect(MacKeyCode.from(.rightOption) == 0x3D)
        #expect(MacKeyCode.from(.leftShift) == 0x38)
        #expect(MacKeyCode.from(.rightShift) == 0x3C)
        #expect(MacKeyCode.from(.leftControl) == 0x3B)
        #expect(MacKeyCode.from(.rightControl) == 0x3E)
    }

    @Test func isoAndJISKeys() {
        #expect(MacKeyCode.from(.key(0x64)) == 0x0A)   // ISO key beside left Shift → kVK_ISO_Section
        #expect(MacKeyCode.from(.key(0x32)) == 0x2A)   // ISO key beside Return → same Mac key as \
        #expect(MacKeyCode.from(.key(0x87)) == 0x5E)   // JIS ろ → kVK_JIS_Underscore
        #expect(MacKeyCode.from(.key(0x89)) == 0x5D)   // JIS ¥
        #expect(MacKeyCode.from(.key(0x90)) == 0x68)   // かな
        #expect(MacKeyCode.from(.key(0x91)) == 0x66)   // 英数
        #expect(MacKeyCode.from(.key(0x85)) == 0x5F)   // JIS keypad ,
    }
}
