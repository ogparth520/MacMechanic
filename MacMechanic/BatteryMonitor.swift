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
    private let batteryService: io_service_t

    // Change detection — only accessed on bgQueue
    private var lastCharge: Int = -1
    private var lastStatus: String = ""
    private var lastTime: String = ""
    private var lastWatts: Double = -1
    private var lastCharging: Bool = false
    private var lastPresent: Bool = false

    var isPaused: Bool = false

    private init() {
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("AppleSmartBattery"))
        // Static fields: health, capacity, cycles never change during a session
        if batteryService != IO_OBJECT_NULL {
            var props: Unmanaged<CFMutableDictionary>? = nil
            IORegistryEntryCreateCFProperties(batteryService, &props, kCFAllocatorDefault, 0)
            if let dict = props?.takeRetainedValue() as? [String: Any] {
                let nominal = dict["NominalChargeCapacity"] as? Int ?? 0
                let design  = dict["DesignCapacity"] as? Int ?? 0
                nominalCapacityMAh = nominal
                designCapacityMAh  = design
                cycleCount         = dict["CycleCount"] as? Int ?? 0
                healthPercent      = design > 0
                    ? min(Double(nominal) / Double(design) * 100, 100.0) : 0
            }
        }
        startTimer()
    }

    deinit {
        if batteryService != IO_OBJECT_NULL { IOObjectRelease(batteryService) }
    }

    func startTimer() {
        fetchStats()
        timer = Timer.scheduledTimer(withTimeInterval: 11.9, repeats: true) { [weak self] _ in
            self?.fetchStats()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

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

            // ── AppleSmartBattery: dynamic fields only (cached service) ───────
            var chargingStatus = "--"
            var timeStr = "--"
            var charging = false
            var powerWatts = 0.0

            if self.batteryService != IO_OBJECT_NULL {
                var props: Unmanaged<CFMutableDictionary>? = nil
                IORegistryEntryCreateCFProperties(self.batteryService, &props, kCFAllocatorDefault, 0)
                if let dict = props?.takeRetainedValue() as? [String: Any] {
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

                    let amperage = dict["Amperage"] as? Int ?? 0
                    let voltage  = dict["Voltage"] as? Int ?? 0
                    powerWatts   = abs(Double(amperage) * Double(voltage)) / 1_000_000.0
                }
            }

            // ── Change detection ──────────────────────────────────────────────
            let changed = chargePercent != self.lastCharge
                       || chargingStatus != self.lastStatus
                       || timeStr != self.lastTime
                       || abs(powerWatts - self.lastWatts) > 0.05
                       || charging  != self.lastCharging
                       || present   != self.lastPresent

            guard changed else { return }
            self.lastCharge   = chargePercent
            self.lastStatus   = chargingStatus
            self.lastTime     = timeStr
            self.lastWatts    = powerWatts
            self.lastCharging = charging
            self.lastPresent  = present

            DispatchQueue.main.async {
                self.chargePercent  = chargePercent
                self.chargingStatus = chargingStatus
                self.timeRemaining  = timeStr
                self.powerWatts     = powerWatts
                self.isCharging     = charging
                self.isPresent      = present
            }
        }
    }

    private static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
