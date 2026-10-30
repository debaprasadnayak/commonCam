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

/// Blurs photos that are hidden pending review (flagged on-device or reported) until the viewer taps to show them.
private struct PendingReviewBlur: ViewModifier {
    let isBlurred: Bool
    @State private var revealed = false

    func body(content: Content) -> some View {
        content
            .blur(radius: isBlurred && !revealed ? 30 : 0, opaque: true)
            .overlay {
                if isBlurred && !revealed {
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
    func pendingReviewBlur(_ isBlurred: Bool) -> some View {
        modifier(PendingReviewBlur(isBlurred: isBlurred))
    }
}
