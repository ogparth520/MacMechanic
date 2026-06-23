import Foundation
import IOKit
import IOKit.ps

class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    @Published var chargePercent: Int = 0
    @Published var chargingStatus: String = "--"
    @Published var healthPercent: Double = 0
    @Published var cycleCount: Int = 0
    @Published var nominalCapacityMAh: Int = 0
    @Published var designCapacityMAh: Int = 0
    @Published var timeRemaining: String = "--"
    @Published var powerWatts: Double = 0
    @Published var isCharging: Bool = false
    @Published var isPresent: Bool = false

    private var timer: Timer?
    private let bgQueue = DispatchQueue(label: "com.macmechanic.battery", qos: .utility)

    private init() {
        startTimer()
    }

    func startTimer() {
        fetchStats()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.fetchStats()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var isPaused: Bool = false

    func fetchStats() {
        guard !isPaused else { return }
        bgQueue.async { [weak self] in
            guard let self else { return }

            // ── IOPowerSources: charge % and presence only ────────────────────
            var chargePercent = 0
            var present = false

            if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
               let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
                for src in list {
                    guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                            .takeUnretainedValue() as? [String: Any],
                          let type = desc[kIOPSTypeKey] as? String,
                          type == kIOPSInternalBatteryType
                    else { continue }
                    present = true
                    let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
                    let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
                    chargePercent = max > 0 ? cur * 100 / max : 0
                    break
                }
            }

            // ── AppleSmartBattery: all other stats ────────────────────────────
            var healthPercent = 0.0
            var chargingStatus = "--"
            var timeStr = "--"
            var charging = false
            var cycleCount = 0
            var maxMAh = 0
            var designMAh = 0
            var powerWatts = 0.0

            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            var props: Unmanaged<CFMutableDictionary>? = nil
            IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
            let dict = props?.takeRetainedValue() as? [String: Any]
            let nominalChargeCapacity = dict?["NominalChargeCapacity"] as? Int ?? 0
            let designCapacity = dict?["DesignCapacity"] as? Int ?? 0
            let health = designCapacity > 0 ? min((Double(nominalChargeCapacity) / Double(designCapacity)) * 100, 100.0) : 0
            IOObjectRelease(service)

            healthPercent = health
            maxMAh        = nominalChargeCapacity
            designMAh     = designCapacity

            if let dict {
                func intVal(_ key: String) -> Int {
                    (dict[key] as? NSNumber)?.intValue ?? 0
                }

                let isCharging        = dict["IsCharging"] as? Bool ?? false
                let externalConnected = dict["ExternalConnected"] as? Bool ?? false
                charging = isCharging

                if isCharging {
                    chargingStatus = "Charging"
                    let mins = intVal("AvgTimeToFull")
                    timeStr = mins > 0 && mins < 65535 ? Self.formatMinutes(mins) : "Calculating…"
                } else if externalConnected {
                    chargingStatus = "AC Power"
                    timeStr = "--"
                } else {
                    chargingStatus = "Discharging"
                    let mins = intVal("AvgTimeToEmpty")
                    timeStr = mins > 0 && mins < 65535 ? Self.formatMinutes(mins) : "Calculating…"
                }

                cycleCount = intVal("CycleCount")
                let amperage = dict["Amperage"] as? Int ?? 0
                let voltage  = dict["Voltage"] as? Int ?? 0
                powerWatts   = abs(Double(amperage) * Double(voltage)) / 1_000_000.0
            }

            DispatchQueue.main.async {
                self.chargePercent     = chargePercent
                self.chargingStatus    = chargingStatus
                self.healthPercent     = healthPercent
                self.cycleCount        = cycleCount
                self.nominalCapacityMAh = maxMAh
                self.designCapacityMAh = designMAh
                self.timeRemaining     = timeStr
                self.powerWatts        = powerWatts
                self.isCharging        = charging
                self.isPresent         = present
            }
        }
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
