import Foundation

/// Pure mapping from "when did we last successfully sync?" to a user-facing state. Thresholds mimic
/// WHOOP (caught-up < 1 h behind; catching-up beyond) plus a `.stale` step that drives the local nudge.
enum SyncFreshness: Equatable { case neverSynced, caughtUp, catchingUp, stale }

enum StalenessPolicy {
    static let catchingUpAfterSeconds: TimeInterval = 3600    // 1 h — WHOOP's DataCatchingUpHelper number
    static let staleAfterSeconds: TimeInterval = 6 * 3600     // 6 h — our local-nudge threshold

    static func state(lastSyncedAt: TimeInterval?, now: TimeInterval) -> SyncFreshness {
        guard let last = lastSyncedAt else { return .neverSynced }
        let elapsed = now - last
        if elapsed >= staleAfterSeconds { return .stale }
        if elapsed >= catchingUpAfterSeconds { return .catchingUp }
        return .caughtUp
    }
}

/// "How far is our stored data behind the strap's newest record?" — i.e. what your data is complete
/// THROUGH. Distinct from `StalenessPolicy`, which measures time since the last *sync attempt*; this
/// measures the data's actual reach (frontier vs the strap's newest record from GET_DATA_RANGE).
enum SyncCoverageState: Equatable {
    case noData                         // nothing stored yet
    case caughtUp                       // frontier ≈ the strap's newest (or the strap's newest is unknown)
    case behind(seconds: TimeInterval)  // the strap holds data newer than our frontier by this much
}

enum SyncCoverage {
    /// Treat a gap this small as caught up — the strap logs ~1 Hz, so a little lag is normal even mid-drain.
    static let caughtUpToleranceSeconds: TimeInterval = 120

    /// "Caught up" requires evidence the data is current. Measure the frontier against the strap's
    /// newest record when we have a fresh reading (connected, post-GET_DATA_RANGE); otherwise against
    /// `now` — we can't claim caught up without knowing the strap has nothing newer, so day-old data
    /// must not show green just because we're disconnected and can't see the strap. (When connected and
    /// the strap genuinely has nothing newer — e.g. it was off-wrist — frontier ≈ strap, so it correctly
    /// stays caught up even though the data is old.)
    static func state(dataThroughTs: TimeInterval?, strapNewestTs: TimeInterval?,
                      now: TimeInterval) -> SyncCoverageState {
        guard let frontier = dataThroughTs else { return .noData }
        let reference = strapNewestTs ?? now
        let gap = reference - frontier
        return gap > caughtUpToleranceSeconds ? .behind(seconds: gap) : .caughtUp
    }

    /// Compact label for a behind gap: "~2d behind" / "~34h behind" / "~12m behind" / "~5s behind".
    static func behindLabel(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 86_400 { return "~\(s / 86_400)d behind" }
        if s >= 3_600  { return "~\(s / 3_600)h behind" }
        if s >= 60     { return "~\(s / 60)m behind" }
        return "~\(s)s behind"
    }
}
