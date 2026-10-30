import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Reads the bearer token out of a scanned (or universally-linked) `https://<api>/join/<token>` URL.
public enum JoinLink {
    public static func qrToken(from url: URL) -> String? {
        let parts = url.pathComponents
        guard url.scheme == "https", parts.count == 3, parts[1] == "join", !parts[2].isEmpty else { return nil }
        return parts[2]
    }
}

public enum QRCode {
    /// A crisp QR image of `string`, scaled up so it stays sharp on screen.
    public static func image(for string: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

public enum FunName {
    static let adjectives = ["Dancing", "Sleepy", "Brave", "Giggly", "Sparkly", "Sneaky", "Jolly", "Fuzzy", "Zippy", "Cosmic", "Groovy", "Bouncy"]
    static let animals = ["Otter", "Panda", "Llama", "Fox", "Penguin", "Koala", "Walrus", "Hedgehog", "Narwhal", "Puffin", "Badger", "Gecko"]

    public static func random() -> String {
        "\(adjectives.randomElement()!) \(animals.randomElement()!)"
    }
}

public enum MemberColour {
    public static let palette = ["#FF5A5F", "#FF8800", "#FFC300", "#3DDC84", "#00B3E6", "#5B6CFF", "#B05BFF", "#FF5BC8"]
}
