import XCTest
@testable import OpenWhoop

/// Tests for SyncCoverage — "what is our data complete THROUGH, and are we behind?" The map that
/// drives the Device view's "Data through" readout.
final class SyncCoverageTests: XCTestCase {
    private let now: TimeInterval = 100_000

    func test_noFrontier_isNoData() {
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: nil, strapNewestTs: 1_000, now: now), .noData)
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: nil, strapNewestTs: nil, now: now), .noData)
    }

    // ── Strap known (connected): compare against the strap's newest record ──
    func test_frontierAtStrap_isCaughtUp() {
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: 90_000, strapNewestTs: 90_000, now: now), .caughtUp)
    }
    func test_gapWithinTolerance_isCaughtUp() {
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: 90_000, strapNewestTs: 90_060, now: now), .caughtUp)
    }
    func test_strapHasNewer_isBehind() {
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: 90_000, strapNewestTs: 90_000 + 3_600, now: now),
                       .behind(seconds: 3_600))
    }
    func test_strapEqualsFrontier_bothOld_isCaughtUp() {
        // Connected, strap has nothing newer (e.g. band was off-wrist) → caught up even though old.
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: 10_000, strapNewestTs: 10_000, now: now), .caughtUp)
    }

    // ── Strap unknown (disconnected): compare against now ──
    func test_strapUnknown_recentFrontier_isCaughtUp() {
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: now - 30, strapNewestTs: nil, now: now), .caughtUp)
    }
    func test_strapUnknown_staleFrontier_isBehind_regression() {
        // The reported bug: data through ~25h ago, strap unknown, must NOT show caught up.
        XCTAssertEqual(SyncCoverage.state(dataThroughTs: now - 25 * 3_600, strapNewestTs: nil, now: now),
                       .behind(seconds: 25 * 3_600))
    }

    func test_behindLabel_daysHoursMinutesSeconds() {
        XCTAssertEqual(SyncCoverage.behindLabel(seconds: 2 * 86_400), "~2d behind")
        XCTAssertEqual(SyncCoverage.behindLabel(seconds: 34 * 3_600), "~34h behind")
        XCTAssertEqual(SyncCoverage.behindLabel(seconds: 12 * 60), "~12m behind")
        XCTAssertEqual(SyncCoverage.behindLabel(seconds: 5), "~5s behind")
    }
}
