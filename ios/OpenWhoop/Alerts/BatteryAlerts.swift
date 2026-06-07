import Foundation

/// UserDefaults keys shared between the settings UI (`@AppStorage`) and `BatteryAlertMonitor`.
/// Defaults: alerts OFF, warn at 50%, low at 20%.
public enum BatteryAlertKeys {
    public static let warnEnabled   = "batteryWarnEnabled"
    public static let warnThreshold = "batteryWarnThreshold"
    public static let lowEnabled    = "batteryLowEnabled"
    public static let lowThreshold  = "batteryLowThreshold"
    /// Internal: last battery % we saw, persisted so crossing detection survives app restarts.
    static let lastReading = "batteryAlertLastReading"

    public static let defaultWarnThreshold = 50
    public static let defaultLowThreshold  = 20
}

/// The two configurable battery alerts. Thresholds are whole percentages.
public struct BatteryAlertConfig: Equatable {
    public var warnEnabled: Bool
    public var warnThreshold: Int
    public var lowEnabled: Bool
    public var lowThreshold: Int

    public init(warnEnabled: Bool, warnThreshold: Int, lowEnabled: Bool, lowThreshold: Int) {
        self.warnEnabled = warnEnabled
        self.warnThreshold = warnThreshold
        self.lowEnabled = lowEnabled
        self.lowThreshold = lowThreshold
    }
}

/// One alert that fired because the battery crossed its threshold on the way down.
public struct BatteryAlert: Equatable {
    /// The configured threshold this alert is for (50 / 20 by default).
    public let threshold: Int
    /// The actual battery reading (%) that tripped it. Reported in the notification so the text
    /// shows the real value instead of the threshold label.
    public let reading: Double

    public init(threshold: Int, reading: Double) {
        self.threshold = threshold
        self.reading = reading
    }
}

public enum BatteryAlertEvaluator {
    /// Largest plausible single-step battery drop, in percentage points. Real discharge is
    /// gradual; a bigger one-shot drop (e.g. 58 → 0) is a stale/garbage sample, so the monitor
    /// ignores it rather than firing a false alert. Sized so the existing "big drop crosses both
    /// thresholds" case (55 → 15 = 40 points) stays valid.
    public static let maxPlausibleDrop: Double = 40

    /// Decide which enabled alerts should fire for a transition from `previous` to `current` %.
    ///
    /// Edge-triggered: an alert fires only when the battery crosses DOWN through its threshold —
    /// `previous` strictly above and `current` at or below. This means:
    /// - reaching the threshold (51 → 50) fires once,
    /// - staying below it (19 → 18) does NOT re-fire,
    /// - charging back above it re-arms it for the next drop,
    /// - with no prior reading (`previous == nil`) nothing fires — we only alert on an observed drop.
    public static func evaluate(previous: Double?,
                                current: Double,
                                config: BatteryAlertConfig) -> [BatteryAlert] {
        guard let previous else { return [] }
        func crossed(_ threshold: Int) -> Bool {
            previous > Double(threshold) && current <= Double(threshold)
        }
        var fired: [BatteryAlert] = []
        if config.warnEnabled, crossed(config.warnThreshold) {
            fired.append(BatteryAlert(threshold: config.warnThreshold, reading: current))
        }
        if config.lowEnabled, crossed(config.lowThreshold) {
            fired.append(BatteryAlert(threshold: config.lowThreshold, reading: current))
        }
        return fired
    }
}
