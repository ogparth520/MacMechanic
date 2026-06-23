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
    // PID cache: (pid, name) pairs that passed resource filter on the last full scan.
    // Incremental ticks reuse this list to avoid proc_listpids + proc_name on all PIDs.
    private var pidNameCache: [(pid: Int32, name: String)] = []
    private var tickCount: Int = 0

    private init() {
        startTimer()
    }

    func startTimer() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 7.3, repeats: true) { [weak self] _ in
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

            let isFullScan = self.tickCount % 5 == 0
            self.tickCount &+= 1

            var nameBuf = [CChar](repeating: 0, count: 2048)

            // Full scan: enumerate every PID, filter by name, then by resources.
            // The resource-significant survivors are cached for the next 4 incremental ticks.
            // Incremental ticks skip proc_listpids + proc_name entirely, hitting only
            // proc_pidinfo on ~30-50 known-active processes instead of 600+.
            let candidates: [(pid: Int32, name: String)]
            if isFullScan {
                let pidCountBytes = proc_listpids(1 /* PROC_ALL_PIDS */, 0, nil, 0)
                guard pidCountBytes > 0 else { return }

                let capacity = Int(pidCountBytes) / MemoryLayout<Int32>.size + 32
                var allPIDs = [Int32](repeating: 0, count: capacity)
                let writtenBytes = proc_listpids(1, 0, &allPIDs,
                                                 Int32(capacity * MemoryLayout<Int32>.size))
                let pidCount = Int(writtenBytes) / MemoryLayout<Int32>.size

                var fresh: [(pid: Int32, name: String)] = []
                for i in 0..<pidCount {
                    let pid = allPIDs[i]
                    guard pid > 0 else { continue }
                    nameBuf[0] = 0
                    proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                    let name = String(cString: nameBuf)
                    guard !name.isEmpty, name.first?.isLetter == true else { continue }
                    fresh.append((pid, name))
                }
                candidates = fresh
            } else {
                candidates = self.pidNameCache
            }

            var list: [AppProcess] = []
            list.reserveCapacity(64)
            var newCPUNs = [Int32: UInt64](minimumCapacity: candidates.count)

            for (pid, name) in candidates {
                var info = proc_taskinfo()
                let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
                let ret = proc_pidinfo(pid, 4 /* PROC_PIDTASKINFO */, 0, &info, infoSize)
                guard ret == infoSize else { continue }

                let memMB   = Double(info.pti_resident_size) / 1_048_576
                let totalNs = info.pti_total_user + info.pti_total_system
                let prevNs  = self.prevCPUNs[pid] ?? totalNs  // no prev → treat delta as 0
                guard memMB >= 10 || totalNs > prevNs else { continue }

                newCPUNs[pid] = totalNs

                var cpuPct = 0.0
                if elapsed > 0.1, prevNs < totalNs {
                    cpuPct = Double(totalNs - prevNs) / (elapsed * 1_000_000_000) * 100
                }

                let energySec = Double(totalNs) / 1_000_000_000
                list.append(AppProcess(id: pid, name: name,  // raw name; cleaned after sort
                                       memoryMB: memMB, cpuPercent: cpuPct,
                                       energySeconds: energySec))
            }

            if isFullScan {
                // Cache the resource-significant survivors so incremental ticks are cheap.
                // Replace prevCPUNs entirely to prune entries for exited processes.
                self.pidNameCache = list.map { ($0.id, $0.name) }
                self.prevCPUNs = newCPUNs
            } else {
                // Merge: preserve CPU tracking for cached processes not seen this tick.
                for (pid, ns) in newCPUNs { self.prevCPUNs[pid] = ns }
            }
            self.prevSampleDate = now

            // Apply cleanName only to the top-5 winners (≤15 calls instead of 500+)
            func cleaned(_ p: AppProcess) -> AppProcess {
                AppProcess(id: p.id, name: ProcessMonitor.cleanName(p.name),
                           memoryMB: p.memoryMB, cpuPercent: p.cpuPercent,
                           energySeconds: p.energySeconds)
            }
            let topMem    = list.sorted { $0.memoryMB      > $1.memoryMB      }.prefix(5).map(cleaned)
            let topCPU    = list.sorted { $0.cpuPercent    > $1.cpuPercent    }.prefix(5).map(cleaned)
            let topEnergy = list.sorted { $0.energySeconds > $1.energySeconds }.prefix(5).map(cleaned)

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
