import Testing
@testable import CommonCamKit

@Suite struct PinCodeTests {
    @Test func acceptsAPinHoweverItIsTyped() {
        #expect(PinCode.normalized("K7M-Q2X") == "K7MQ2X")
        #expect(PinCode.normalized(" k7m q2x ") == "K7MQ2X")
    }

    @Test func rejectsTheWrongLengthOrLookAlikeCharacters() {
        #expect(PinCode.normalized("K7MQ2") == nil)
        #expect(PinCode.normalized("K7MQ2XY") == nil)
        for lookAlike in ["0", "O", "1", "I", "L"] {
            #expect(PinCode.normalized("K7MQ2" + lookAlike) == nil)
        }
    }
}
