import CommonCamKit
import SensitiveContentAnalysis
import SwiftUI

/// Apple's on-device Sensitive Content Analysis. Needs the `com.apple.developer.sensitivecontentanalysis.client`
/// entitlement and the user's Sensitive Content Warning (or Communication Safety) setting; otherwise `isEnabled`
/// is false and shots are shared unflagged.
struct AppleSensitiveContentAnalyzer: SensitiveContentAnalyzer {
    var isEnabled: Bool { SCSensitivityAnalyzer().analysisPolicy != .disabled }

    func isSensitive(imageAt url: URL) async throws -> Bool {
        try await SCSensitivityAnalyzer().analyzeImage(at: url).isSensitive
    }
}

/// Blurs photos that are hidden pending review (flagged on-device or reported). With `canReveal`, a button shows
/// the photo; without (e.g. a gallery tile that already opens the full photo on tap), it stays blurred.
private struct PendingReviewBlur: ViewModifier {
    let isBlurred: Bool
    let canReveal: Bool
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .blur(radius: isBlurred && !revealed ? 30 : 0, opaque: true)
            .overlay {
                if isBlurred && !revealed && canReveal {
                    Button("Show photo", systemImage: "eye") { revealed = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Hidden pending review; may be sensitive")
                }
            }
    }
}

extension View {
    func pendingReviewBlur(_ isBlurred: Bool, canReveal: Bool = true) -> some View {
        modifier(PendingReviewBlur(isBlurred: isBlurred, canReveal: canReveal))
    }
}
