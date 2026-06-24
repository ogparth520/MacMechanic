import Foundation
import ServiceManagement

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    static let allowedPollingIntervals: [TimeInterval] = [1, 5, 10, 15]
    static let defaultPollingInterval: TimeInterval = 5
    private static let pollingIntervalKey = "pollingIntervalSeconds"

    @Published var pollingInterval: TimeInterval {
        didSet {
            guard pollingInterval != oldValue else { return }
            UserDefaults.standard.set(pollingInterval, forKey: Self.pollingIntervalKey)
            CPUMonitor.shared.restartTimer()
            MemoryMonitor.shared.restartTimer()
        }
    }

    /// Reflects the current Service Management state. Mutated through
    /// `setLaunchAtLogin(_:)` so a failed register/unregister doesn't leave the
    /// UI out of sync with the real login-item state.
    @Published private(set) var launchAtLogin: Bool

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.pollingIntervalKey) as? Double
        let resolved = stored.flatMap { Self.allowedPollingIntervals.contains($0) ? $0 : nil }
            ?? Self.defaultPollingInterval
        self.pollingInterval = resolved

        let status = SMAppService.mainApp.status
        self.launchAtLogin = (status == .enabled || status == .requiresApproval)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLogin = enabled
            print("[MacMechanic] Launch at login set to \(enabled); status=\(service.status.rawValue)")
        } catch {
            print("[MacMechanic] Launch at login update failed (enabled=\(enabled)): \(error)")
        }
    }
}
