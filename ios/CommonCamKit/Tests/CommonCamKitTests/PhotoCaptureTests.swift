import Testing
@testable import CommonCamKit

struct PhotoFormatTests {
    @Test func prefersFullQualityHEICWhenTheCameraCanEncodeIt() {
        #expect(PhotoFormat.preferred(availableCodecs: ["jpeg", "hvc1"]) == .heic)
        #expect(PhotoFormat.heic.contentType == "image/heic")
    }

    @Test func fallsBackToJPEGOnHardwareWithoutHEVC() {
        #expect(PhotoFormat.preferred(availableCodecs: ["jpeg"]) == .jpeg)
        #expect(PhotoFormat.jpeg.contentType == "image/jpeg")
    }

    @Test func hasNoFormatWhenThereIsNoCamera() {
        #expect(PhotoFormat.preferred(availableCodecs: []) == nil)
    }
}
