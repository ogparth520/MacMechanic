import Foundation
import Darwin
import IOKit

class CPUMonitor: ObservableObject {
    static let shared = CPUMonitor()
    // CPU
    @Published var overallPercent: Double = 0
    @Published var systemPercent: Double = 0
    @Published var userPercent: Double = 0
    @Published var idlePercent: Double = 0
    @Published var pCorePercent: Double = 0
    @Published var eCorePercent: Double = 0
    @Published var cpuHistory: [Double] = []

    // GPU
    @Published var gpuPercent: Int = 0
    @Published var tilerPercent: Int = 0
    @Published var rendererPercent: Int = 0
    @Published var gpuMemoryGB: Double = 0
    @Published var gpuHistory: [Double] = []
    @Published var gpuModelName: String = ""

    let pCoreCount: Int
    let eCoreCount: Int

    private var timer: Timer?
    private let bgQueue = DispatchQueue(label: "com.macmechanic.cpu", qos: .utility)
    private var prevTicks: [UInt32] = []

    private static let historyLength = 60

    private init() {
        pCoreCount = CPUMonitor.sysctlInt("hw.perflevel0.physicalcpu")
        eCoreCount = CPUMonitor.sysctlInt("hw.perflevel1.physicalcpu")
        bgQueue.async { [weak self] in
            let name = CPUMonitor.buildGPUModelName()
            DispatchQueue.main.async { self?.gpuModelName = name }
        }
        startTimer()
    }

    private static func buildGPUModelName() -> String {
        // Chip name from sysctl (returns e.g. "Apple M4 Max" on Apple Silicon)
        var brand = [CChar](repeating: 0, count: 256)
        var brandSize = brand.count
        sysctlbyname("machdep.cpu.brand_string", &brand, &brandSize, nil, 0)
        let chipName = String(cString: brand)

        // GPU core count from AGXAccelerator device-tree property
        var coreCount: Int? = nil
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AGXAccelerator"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>? = nil
            IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
            if let dict = props?.takeRetainedValue() as? [String: Any] {
                if let n = dict["gpu-core-count"] as? Int {
                    coreCount = n
                } else if let data = dict["gpu-core-count"] as? Data, data.count >= 4 {
                    // Device-tree integers are big-endian
                    coreCount = Int(data.withUnsafeBytes {
                        UInt32(bigEndian: $0.load(as: UInt32.self))
                    })
                }
            }
        }

        let base = chipName.isEmpty ? "GPU" : "\(chipName) GPU"
        if let count = coreCount, count > 0 {
            return "\(base) · \(count) Cores"
        }
        return base
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
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
            self.fetchCPU()
            self.fetchGPU()
        }
    }

    private func fetchCPU() {
        var numCPU: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &numCPU, &infoPtr, &infoCount) == KERN_SUCCESS,
              let info = infoPtr else { return }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let coreCount  = Int(numCPU)
        let stateCount = Int(CPU_STATE_MAX)

        if prevTicks.isEmpty {
            prevTicks = (0..<coreCount * stateCount).map { UInt32(bitPattern: info[$0]) }
            return
        }

        var coreUsages: [Double] = []
        coreUsages.reserveCapacity(coreCount)

        // Aggregate ticks across all cores for system/user/idle breakdown
        var sumUser: UInt64 = 0
        var sumSys: UInt64 = 0
        var sumIdle: UInt64 = 0
        var sumNice: UInt64 = 0

        for core in 0..<coreCount {
            let base = core * stateCount

            let curUser = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let curSys  = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let curIdle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let curNice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])

            let dUser = curUser &- prevTicks[base + Int(CPU_STATE_USER)]
            let dSys  = curSys  &- prevTicks[base + Int(CPU_STATE_SYSTEM)]
            let dIdle = curIdle &- prevTicks[base + Int(CPU_STATE_IDLE)]
            let dNice = curNice &- prevTicks[base + Int(CPU_STATE_NICE)]

            sumUser += UInt64(dUser)
            sumSys  += UInt64(dSys)
            sumIdle += UInt64(dIdle)
            sumNice += UInt64(dNice)

            let total = UInt64(dUser) + UInt64(dSys) + UInt64(dIdle) + UInt64(dNice)
            let used  = UInt64(dUser) + UInt64(dSys) + UInt64(dNice)
            coreUsages.append(total > 0 ? Double(used) / Double(total) * 100 : 0)

            prevTicks[base + Int(CPU_STATE_USER)]   = curUser
            prevTicks[base + Int(CPU_STATE_SYSTEM)] = curSys
            prevTicks[base + Int(CPU_STATE_IDLE)]   = curIdle
            prevTicks[base + Int(CPU_STATE_NICE)]   = curNice
        }

        let overall = coreUsages.reduce(0, +) / Double(coreCount)

        let pCount = min(pCoreCount, coreCount)
        let eCount = min(eCoreCount, coreCount - pCount)
        let pUsages = Array(coreUsages.prefix(pCount))
        let eUsages = Array(coreUsages.dropFirst(pCount).prefix(eCount))
        let pAvg = pUsages.isEmpty ? 0 : pUsages.reduce(0, +) / Double(pUsages.count)
        let eAvg = eUsages.isEmpty ? 0 : eUsages.reduce(0, +) / Double(eUsages.count)

        let totalAll = sumUser + sumSys + sumIdle + sumNice
        let sysPct  = totalAll > 0 ? Double(sumSys) / Double(totalAll) * 100 : 0
        let userPct = totalAll > 0 ? Double(sumUser + sumNice) / Double(totalAll) * 100 : 0
        let idlePct = totalAll > 0 ? Double(sumIdle) / Double(totalAll) * 100 : 0

        DispatchQueue.main.async {
            self.overallPercent = overall
            self.pCorePercent   = pAvg
            self.eCorePercent   = eAvg
            self.systemPercent  = sysPct
            self.userPercent    = userPct
            self.idlePercent    = idlePct
            self.appendHistory(&self.cpuHistory, value: overall)
        }
    }

    private func fetchGPU() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AGXAccelerator"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>? = nil
        IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard let dict = props?.takeRetainedValue() as? [String: Any],
              let perfStats = dict["PerformanceStatistics"] as? [String: Any] else { return }

        let gpu      = perfStats["Device Utilization %"]   as? Int ?? 0
        let tiler    = perfStats["Tiler Utilization %"]    as? Int ?? 0
        let renderer = perfStats["Renderer Utilization %"] as? Int ?? 0

        // GPU memory: "Alloc system memory" is in bytes on Apple Silicon
        let memBytes = perfStats["Alloc system memory"] as? Int ?? 0
        let memGB    = Double(memBytes) / 1_073_741_824.0

        DispatchQueue.main.async {
            self.gpuPercent      = gpu
            self.tilerPercent    = tiler
            self.rendererPercent = renderer
            self.gpuMemoryGB     = memGB
            self.appendHistory(&self.gpuHistory, value: Double(gpu))
        }
    }

    private func appendHistory(_ history: inout [Double], value: Double) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }
}
