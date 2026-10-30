import Foundation

/// On-device check for likely explicit images (Apple's Sensitive Content Analysis in the app).
/// Shots it flags are confirmed with `sensitive: true`, which hides them from members pending owner review.
public protocol SensitiveContentAnalyzer: Sendable {
    /// False when analysis is unavailable or the user has not switched it on in Settings.
    var isEnabled: Bool { get }
    func isSensitive(imageAt url: URL) async throws -> Bool
}

extension SensitiveContentAnalyzer {
    /// Whether to flag the image. Analysis being off, unavailable or failing never blocks sharing: it just doesn't flag.
    func shouldFlag(imageAt url: URL) async -> Bool {
        guard isEnabled else { return false }
        return (try? await isSensitive(imageAt: url)) ?? false
    }
}
