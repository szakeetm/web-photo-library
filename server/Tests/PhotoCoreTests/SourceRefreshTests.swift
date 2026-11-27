import Foundation
import Testing
@testable import PhotoCore

@Suite struct SourceRefreshTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func scan(_ root: String, minutesAgo: Double) -> SourceScan {
        SourceScan(root: root, at: now.addingTimeInterval(-minutesAgo * 60), report: nil)
    }

    @Test func offByDefaultSoNothingIsDue() {
        #expect(SourceRefresh.due(intervals: [:], scans: [scan("photos-1", minutesAgo: 10_000)], now: now).isEmpty)
    }

    @Test func dueOnceItsIntervalHasPassedMostOverdueFirst() {
        let intervals = ["photos-1": 5, "remote-1": 10080, "library": 60]
        let scans = [scan("photos-1", minutesAgo: 6), scan("remote-1", minutesAgo: 60), scan("library", minutesAgo: 200)]
        // library is 140 min over, photos-1 1 min over; remote-1 (a week) isn't due
        #expect(SourceRefresh.due(intervals: intervals, scans: scans, now: now) == ["library", "photos-1"])
    }

    @Test func neverScannedIsDue() {
        #expect(SourceRefresh.due(intervals: ["local-2": 15], scans: [], now: now) == ["local-2"])
    }
}
