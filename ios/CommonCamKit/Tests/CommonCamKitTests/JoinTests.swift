import CoreImage
import Foundation
import Testing
@testable import CommonCamKit

@Suite struct JoinLinkTests {
    @Test func readsTheTokenFromAScannedJoinLink() {
        let url = URL(string: "https://api.commoncam.app/join/AbC-123_xyz")!
        #expect(JoinLink.qrToken(from: url) == "AbC-123_xyz")
    }

    @Test func ignoresCodesThatAreNotJoinLinks() {
        #expect(JoinLink.qrToken(from: URL(string: "https://example.com/menu")!) == nil)
        #expect(JoinLink.qrToken(from: URL(string: "https://api.commoncam.app/join/")!) == nil)
        #expect(JoinLink.qrToken(from: URL(string: "https://api.commoncam.app/join/a/b")!) == nil)
    }
}

@Suite struct QRCodeTests {
    @Test func encodesTheJoinLinkSoAScannerCanReadItBack() throws {
        let link = "https://api.commoncam.app/join/q0xh0g5rbN2l3bDpDS9hUiZCwHqfS8kXo2pFq8Vd0nA"

        let image = try #require(QRCode.image(for: link))

        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(features.first?.messageString == link)
    }
}

@Suite struct FunNameTests {
    @Test func suggestsTwoWordNamesThatFitTheServerLimit() {
        for _ in 0..<50 {
            let name = FunName.random()
            #expect(name.split(separator: " ").count == 2)
            #expect((1...30).contains(name.count))
        }
    }

    @Test func offersColoursTheServerAccepts() {
        #expect(!MemberColour.palette.isEmpty)
        for colour in MemberColour.palette {
            #expect(colour.wholeMatch(of: /#[0-9A-F]{6}/) != nil)
        }
    }
}
