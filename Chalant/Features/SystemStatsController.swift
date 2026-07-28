import Foundation
import IOKit.ps

/// Battery level for the collapsed island's wing. Polled lazily,
/// battery percentages don't change fast enough to justify more.
/// Room for CPU/memory later behind the same controller.
@MainActor
final class SystemStatsController: ObservableObject {
    struct Battery: Equatable {
        var level: Int
        var charging: Bool
    }

    /// nil on Macs without a battery.
    @Published private(set) var battery: Battery?

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
            battery = Battery(level: capacity * 100 / max, charging: charging)
            return
        }
        battery = nil
    }
}
