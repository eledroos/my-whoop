import XCTest
@testable import OpenWhoop

/// Unit tests for the pure battery-alert crossing logic. The tricky parts are edge-triggering
/// (fire once on the way down, not repeatedly), re-arming after a charge, the no-prior-reading
/// case, and both thresholds tripping in one big drop.
final class BatteryAlertsTests: XCTestCase {
    private let both = BatteryAlertConfig(warnEnabled: true, warnThreshold: 50,
                                          lowEnabled: true, lowThreshold: 20)

    private func eval(_ prev: Double?, _ cur: Double, _ c: BatteryAlertConfig) -> [Int] {
        BatteryAlertEvaluator.evaluate(previous: prev, current: cur, config: c).map(\.threshold)
    }

    func test_noPriorReading_neverFires() {
        XCTAssertEqual(eval(nil, 10, both), [])
    }

    func test_crossingDownThroughWarn_fires() {
        XCTAssertEqual(eval(55, 45, both), [50])
    }

    func test_reachingThresholdExactly_fires() {
        // "notify when it gets to 50%": 51 → 50 counts as reaching it.
        XCTAssertEqual(eval(51, 50, both), [50])
    }

    func test_notCrossing_doesNotFire() {
        XCTAssertEqual(eval(55, 52, both), [])
    }

    func test_alreadyBelow_stayingBelow_doesNotFire() {
        // Sitting at 19%, dropping to 18% must NOT re-spam the low alert.
        XCTAssertEqual(eval(19, 18, both), [])
    }

    func test_rising_doesNotFire_thenReArms() {
        XCTAssertEqual(eval(45, 55, both), [], "charging back up should not fire")
        XCTAssertEqual(eval(55, 45, both), [50], "after recharge, a fresh drop fires again")
    }

    func test_bigDropCrossesBothThresholds() {
        XCTAssertEqual(eval(55, 15, both), [50, 20])
    }

    func test_disabledThreshold_doesNotFire() {
        let warnOnly = BatteryAlertConfig(warnEnabled: true, warnThreshold: 50,
                                          lowEnabled: false, lowThreshold: 20)
        XCTAssertEqual(eval(55, 15, warnOnly), [50], "low disabled → only warn fires")
    }

    func test_firedAlertCarriesActualReading() {
        // The notification text uses the reading, not the threshold label.
        let fired = BatteryAlertEvaluator.evaluate(previous: 55, current: 45, config: both)
        XCTAssertEqual(fired.first?.threshold, 50)
        XCTAssertEqual(fired.first?.reading, 45, "alert must carry the real reading for the notification text")
    }

    // ── Monitor-level sanity gate: the false "20%" pings fix ───────────────────
    // Bug: the unreliable 0x2A19 source pushed a momentary low value between good readings,
    // tripping the edge-triggered low alert (whose text printed the 20% threshold, not the real
    // value). The monitor now drops implausible single-step cliffs without poisoning the baseline.

    private final class AlertSink { var alerts: [BatteryAlert] = [] }

    @MainActor
    private func makeMonitor() -> (BatteryAlertMonitor, AlertSink) {
        let defaults = UserDefaults(suiteName: "BatteryAlertsTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: BatteryAlertKeys.warnEnabled)
        defaults.set(true, forKey: BatteryAlertKeys.lowEnabled)
        defaults.set(50, forKey: BatteryAlertKeys.warnThreshold)
        defaults.set(20, forKey: BatteryAlertKeys.lowThreshold)
        let sink = AlertSink()
        let monitor = BatteryAlertMonitor(defaults: defaults, notify: { sink.alerts.append($0) })
        return (monitor, sink)
    }

    @MainActor
    func test_spuriousLowBetweenGoodReadings_doesNotFire() {
        let (m, sink) = makeMonitor()
        m.handle(battery: 58.4)   // good reading
        m.handle(battery: 0)      // spurious cliff → gated, not persisted
        m.handle(battery: 58.4)   // good again
        XCTAssertEqual(sink.alerts.map(\.threshold), [],
                       "a spurious low between good readings must not fire the false 20% alert")
    }

    @MainActor
    func test_spuriousLow_doesNotPoisonBaseline_realLaterDropStillFires() {
        let (m, sink) = makeMonitor()
        m.handle(battery: 45)   // baseline 45 (prev nil → no fire)
        m.handle(battery: 0)    // gated; baseline stays 45, NOT poisoned to 0
        m.handle(battery: 18)   // 45 → 18 plausible, crosses low(20)
        XCTAssertEqual(sink.alerts.map(\.threshold), [20],
                       "after a gated spurious low, a genuine drop must still alert")
    }

    @MainActor
    func test_realGradualCross_fires_andReportsActualReading() {
        let (m, sink) = makeMonitor()
        m.handle(battery: 55)
        m.handle(battery: 45)   // crosses warn(50)
        XCTAssertEqual(sink.alerts.map(\.threshold), [50])
        XCTAssertEqual(sink.alerts.first?.reading, 45,
                       "notification must report the actual reading, not the threshold label")
    }
}
