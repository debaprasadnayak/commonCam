import Foundation
import Testing
@testable import CommonCamKit

private let host = Contributor(memberId: nil, displayName: "Host", colour: "#8E8E93")
private let ada = Contributor(memberId: "m-ada", displayName: "Ada Otter", colour: "#FF0000")
private let bo = Contributor(memberId: "m-bo", displayName: "Bo Badger", colour: "#00FF00")

/// `minute` is minutes after a fixed start, so later minutes are newer.
private func item(_ id: String, by contributor: Contributor, minute: Int) -> GalleryItem {
    GalleryItem(
        id: id, type: "photo", contentType: "image/jpeg", bytes: 1,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60),
        contributor: contributor,
        downloadUrl: URL(string: "https://example.test/\(id)")!,
        downloadUrlExpiresAt: Date(timeIntervalSince1970: 1_900_000_000))
}

@Suite struct ContributorStatsTests {
    @Test func countsEachPersonsItemsMostFirst() {
        // Newest first, as the gallery endpoint returns them.
        let items = [
            item("5", by: ada, minute: 5),
            item("4", by: host, minute: 4),
            item("3", by: ada, minute: 3),
            item("2", by: bo, minute: 2),
            item("1", by: ada, minute: 1),
        ]
        let stats = ContributorStats(items: items)
        #expect(stats.counts.map(\.contributor) == [ada, bo, host])
        #expect(stats.counts.map(\.count) == [3, 1, 1])
        #expect(stats.top == ada)
    }

    @Test func aTieForTopGoesToWhoeverGotThereFirst() {
        let items = [
            item("4", by: bo, minute: 4),
            item("3", by: ada, minute: 3),
            item("2", by: bo, minute: 2),
            item("1", by: ada, minute: 1),
        ]
        #expect(ContributorStats(items: items).top == ada)
        #expect(ContributorStats(items: [item("5", by: bo, minute: 5)] + items).top == bo)
    }

    @Test func filtersToOnePersonKeepingOrder() {
        let items = [
            item("4", by: host, minute: 4),
            item("3", by: ada, minute: 3),
            item("2", by: host, minute: 2),
            item("1", by: ada, minute: 1),
        ]
        #expect(items.contributed(by: ada).map(\.id) == ["3", "1"])
        #expect(items.contributed(by: host).map(\.id) == ["4", "2"])
        #expect(items.contributed(by: bo).isEmpty)
        #expect(items.contributed(by: nil).map(\.id) == ["4", "3", "2", "1"])
    }

    @Test func nobodyIsHighlightedUntilTwoPeopleHaveShared() {
        #expect(ContributorStats(items: []).top == nil)
        #expect(ContributorStats(items: [item("2", by: host, minute: 2), item("1", by: host, minute: 1)]).top == nil)
    }
}
