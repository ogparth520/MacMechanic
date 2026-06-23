import Foundation
import Darwin

struct AppProcess: Identifiable {
    let id: Int32
    let name: String
    let memoryMB: Double
    let cpuPercent: Double
    let energySeconds: Double   // cumulative user+system CPU time in seconds

    var memoryFormatted: String {
        memoryMB >= 1024
            ? String(format: "%.1f GB", memoryMB / 1024)
            : String(format: "%.0f MB", memoryMB)
    }

    var cpuFormatted: String {
        cpuPercent >= 10
            ? String(format: "%.0f%%", cpuPercent)
            : String(format: "%.1f%%", cpuPercent)
    }

    var energyFormatted: String {
        String(format: "%.1f", energySeconds)
    }
}

class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()
    @Published var byMemory: [AppProcess] = []
    @Published var byCPU: [AppProcess] = []
    @Published var byEnergy: [AppProcess] = []

    private var timer: Timer?
    private let bgQueue = DispatchQueue(label: "com.macmechanic.process", qos: .utility)
    private var prevCPUNs: [Int32: UInt64] = [:]
    private var prevSampleDate = Date()

    private init() {
        startTimer()
    }

    func startTimer() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var isPaused: Bool = false

    private func refresh() {
        guard !isPaused else { return }
        bgQueue.async { [weak self] in
            guard let self else { return }

            let now = Date()
            let elapsed = now.timeIntervalSince(self.prevSampleDate)

            // Query how many bytes we need for the PID list
            let pidCountBytes = proc_listpids(1 /* PROC_ALL_PIDS */, 0, nil, 0)
            guard pidCountBytes > 0 else { return }

            let capacity = Int(pidCountBytes) / MemoryLayout<Int32>.size + 32
            var pids = [Int32](repeating: 0, count: capacity)
            let writtenBytes = proc_listpids(1, 0, &pids,
                                             Int32(capacity * MemoryLayout<Int32>.size))
            let pidCount = Int(writtenBytes) / MemoryLayout<Int32>.size

            var list: [AppProcess] = []
            list.reserveCapacity(pidCount)
            var newCPUNs = [Int32: UInt64](minimumCapacity: pidCount)

            for i in 0..<pidCount {
                let pid = pids[i]
                guard pid > 0 else { continue }

                var info = proc_taskinfo()
                let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
                let ret = proc_pidinfo(pid, 4 /* PROC_PIDTASKINFO */, 0, &info, infoSize)
                guard ret == infoSize else { continue }

                var nameBuf = [CChar](repeating: 0, count: 2048)
                proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                let name = String(cString: nameBuf)
                guard !name.isEmpty else { continue }

                let totalNs = info.pti_total_user + info.pti_total_system
                newCPUNs[pid] = totalNs

                var cpuPct = 0.0
                if elapsed > 0.1, let prev = self.prevCPUNs[pid], totalNs >= prev {
                    cpuPct = Double(totalNs - prev) / (elapsed * 1_000_000_000) * 100
                }

                let memMB    = Double(info.pti_resident_size) / 1_048_576
                let energySec = Double(totalNs) / 1_000_000_000
                list.append(AppProcess(id: pid, name: ProcessMonitor.cleanName(name),
                                       memoryMB: memMB, cpuPercent: cpuPct,
                                       energySeconds: energySec))
            }

            self.prevCPUNs = newCPUNs
            self.prevSampleDate = now

            let topMem    = Array(list.sorted { $0.memoryMB      > $1.memoryMB      }.prefix(5))
            let topCPU    = Array(list.sorted { $0.cpuPercent    > $1.cpuPercent    }.prefix(5))
            let topEnergy = Array(list.sorted { $0.energySeconds > $1.energySeconds }.prefix(5))

            DispatchQueue.main.async {
                self.byMemory = topMem
                self.byCPU    = topCPU
                self.byEnergy = topEnergy
            }
        }
    }

    // Strip reverse-DNS prefixes and clean up truncated bundle-name suffixes.
    // "com.apple.WebKit.WebContent"     → "WebKit WebContent"
    // "com.apple.Virtualization.Virtua" → "Virtualization"  (truncation artifact)
    private static func cleanName(_ raw: String) -> String {
        var name = raw

        // Drop two-component reverse-DNS prefix (com.apple., io.foo., net.bar., …)
        let parts = name.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3,
           let tld = parts.first,
           tld.count <= 3,
           tld == tld.lowercased(),
           parts[1] == parts[1].lowercased() {
            name = String(parts[2])
        }

        // Dots → spaces
        name = name.replacingOccurrences(of: ".", with: " ")

        // Drop trailing word if it's a prefix of the word before it
        // (handles proc_name truncation like "Virtualization Virtua")
        var words = name.split(separator: " ").map(String.init)
        if words.count >= 2 {
            let last = words[words.count - 1].lowercased()
            let prev = words[words.count - 2].lowercased()
            if prev.hasPrefix(last) && last.count < prev.count {
                words.removeLast()
            }
        }

        return words.joined(separator: " ")
    }
}
