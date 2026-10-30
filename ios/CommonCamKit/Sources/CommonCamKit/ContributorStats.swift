import Foundation

/// How many gallery items one person contributed.
public struct ContributorCount: Equatable, Sendable {
    public let contributor: Contributor
    public let count: Int
}

/// Per-person counts over a gallery listing. People are identified by `memberId` (nil = the host).
/// Ties go to whoever reached that count first, so `counts` is most-first and stable as photos arrive.
public struct ContributorStats: Sendable {
    public let counts: [ContributorCount]

    /// The person to highlight: most items, ties to whoever got there first. Nil until two people have shared.
    public var top: Contributor? {
        counts.count >= 2 ? counts.first?.contributor : nil
    }

    public init(items: [GalleryItem]) {
        // Oldest first; equal timestamps keep the listing's newest-first order reversed.
        let chronological = items.enumerated()
            .sorted { ($0.element.createdAt, -$0.offset) < ($1.element.createdAt, -$1.offset) }
            .map(\.element)
        var tallies: [String?: (contributor: Contributor, count: Int, reachedAt: Int)] = [:]
        for (step, item) in chronological.enumerated() {
            let key = item.contributor.memberId
            tallies[key] = (item.contributor, (tallies[key]?.count ?? 0) + 1, step)
        }
        counts = tallies.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reachedAt < $1.reachedAt }
            .map { ContributorCount(contributor: $0.contributor, count: $0.count) }
    }
}

extension Array where Element == GalleryItem {
    /// Only the items one person shot (matched by `memberId`, so the host works too); everything when `contributor` is nil.
    public func contributed(by contributor: Contributor?) -> [GalleryItem] {
        guard let contributor else { return self }
        return filter { $0.contributor.memberId == contributor.memberId }
    }
}
