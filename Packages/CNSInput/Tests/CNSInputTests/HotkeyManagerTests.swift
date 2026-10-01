import Testing
import Carbon.HIToolbox
@testable import CNSInput

@Suite("HotkeyManager")
struct HotkeyManagerTests {
    @Test("Default binding is Option+Space")
    func defaultBinding() {
        let b = HotkeyManager.Binding.optionSpace
        #expect(b.keyCode == UInt32(kVK_Space))
        #expect(b.modifiers == UInt32(optionKey))
    }

    @Test("Custom binding stores its values")
    func customBinding() {
        let b = HotkeyManager.Binding(keyCode: 3, modifiers: UInt32(cmdKey))
        #expect(b.keyCode == 3)
        #expect(b.modifiers == UInt32(cmdKey))
    }
}
