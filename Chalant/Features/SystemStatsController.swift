import Foundation
import IOKit
import IOKit.ps

/// Battery status for the collapsed island's wing and the battery
/// panel. The power-source snapshot (charge, state, time remaining)
/// is polled lazily on a timer, battery percentages don't change fast
/// enough to justify more. Cycle count and condition live in a
/// heavier IOKit service and are fetched only when the panel is
/// actually opened (`refreshBatteryHealth()`), not on that timer.
/// Room for CPU/memory later behind the same controller.
@MainActor
final class SystemStatsController: ObservableObject {
    struct Battery: Equatable {
        enum State: Equatable {
            case charging
            case discharging
            case full
            /// Plugged in, but neither charging nor full: Optimized
            /// Battery Charging holding below 100%, or a charger too
            /// weak to move the level at all.
            case notCharging
        }

        var level: Int
        var state: State
        var pluggedIn: Bool
        /// Minutes to empty while discharging, or to full while
        /// charging; nil when the state has no such number (full,
        /// not charging). macOS reports -1 for a few seconds after
        /// any plug or unplug while it works out the real figure;
        /// that sentinel passes through as-is, never rounded away, so
        /// callers can't mistake "still calculating" for "no time
        /// left."
        var minutesRemaining: Int?
    }

    /// Cycle count and condition, read separately from `Battery`
    /// above (see `refreshBatteryHealth()`).
    struct Health: Equatable {
        var cycleCount: Int?
        /// "Normal" or "Service Recommended", derived from maximum
        /// capacity against design capacity the same way System
        /// Information does. nil, not a guess, when either capacity
        /// figure isn't reported.
        var condition: String?
    }

    /// nil on Macs without a battery.
    @Published private(set) var battery: Battery?
    @Published private(set) var batteryHealth: Health?

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            battery = nil
            return
        }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            let full = info[kIOPSIsChargedKey] as? Bool ?? false
            let pluggedIn = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let state: Battery.State = full ? .full
                : charging ? .charging
                : pluggedIn ? .notCharging : .discharging
            let minutesRemaining: Int? = charging
                ? info[kIOPSTimeToFullChargeKey] as? Int
                : state == .discharging ? info[kIOPSTimeToEmptyKey] as? Int : nil
            battery = Battery(
                level: capacity * 100 / max, state: state, pluggedIn: pluggedIn,
                minutesRemaining: minutesRemaining
            )
            return
        }
        battery = nil
    }

    /// Cycle count and condition: `AppleSmartBattery` is a heavier
    /// service to query than the power-source snapshot `refresh()`
    /// already reads, and neither figure moves fast enough to earn a
    /// place on a 60-second timer that runs whether or not the panel
    /// is even open. The battery panel calls this once, on appear.
    func refreshBatteryHealth() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else {
            batteryHealth = nil
            return
        }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
            batteryHealth = nil
            return
        }
        let cycleCount = dict["CycleCount"] as? Int
        var condition: String?
        if let design = dict["DesignCapacity"] as? Int, design > 0,
           let maxRaw = dict["AppleRawMaxCapacity"] as? Int {
            // ponytail: the same 80% threshold System Information
            // uses for "Service Recommended"; a finer read (age,
            // temperature history) is what the real diagnostic adds.
            let ratio = Double(maxRaw) / Double(design)
            condition = ratio >= 0.8 ? "Normal" : "Service Recommended"
        }
        batteryHealth = (cycleCount == nil && condition == nil)
            ? nil : Health(cycleCount: cycleCount, condition: condition)
    }
}
