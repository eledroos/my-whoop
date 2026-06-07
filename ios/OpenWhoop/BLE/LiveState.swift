import Foundation
import Combine

/// Where a battery reading came from. Only `.strap` (the strap's decoded battery frame) is trusted
/// to drive low-battery alerts; `.bleStandard` (the standard 0x2A19 GATT characteristic) is
/// display-only, because on the WHOOP it intermittently reports stale/garbage low values that were
/// firing false "battery low" notifications.
public enum BatterySource {
    case strap
    case bleStandard
}

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    @Published public var bonded: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    public init() {}

    /// Single funnel for battery readings. Updates the published value for display from any source,
    /// but only the trusted strap-frame source drives the alert hook — the standard 0x2A19
    /// characteristic is a notify stream that intermittently reports stale/garbage low values,
    /// which were tripping false "battery low" notifications.
    public func setBattery(_ pct: Double, source: BatterySource = .strap) {
        batteryPct = pct
        if source == .strap { onBatteryUpdate?(pct) }
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
