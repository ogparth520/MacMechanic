import Foundation
import Combine
import Darwin

enum PressureLevel {
    case normal, warning, critical

    var color: NSColor {
        switch self {
        case .normal:   return .systemGreen
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }
}

import AppKit

class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    @Published var pressureLevel: PressureLevel = .normal
    @Published var memoryUsedGB: Double = 0
    @Published var cachedFilesGB: Double = 0
    @Published var swapUsedGB: Double = 0
    @Published var compressedGB: Double = 0
    @Published var appMemoryGB: Double = 0
    @Published var wiredGB: Double = 0
    @Published var totalRAMGB: Double = {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }()

    private var pressureSource: DispatchSourceMemoryPressure?
    private var statsTimer: Timer?
    private let bgQueue = DispatchQueue(label: "com.macmechanic.vmstats", qos: .utility)

    private var lastSwap: Double = -1
    private var lastCompressed: Double = -1
    private var lastApp: Double = -1
    private var lastWired: Double = -1
    private var lastFree: Double = -1

    private init() {
        setupPressureSource()
        startTimer()
    }

    private func setupPressureSource() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: .all, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.mask
            if flags.contains(.critical) {
                self.pressureLevel = .critical
            } else if flags.contains(.warning) {
                self.pressureLevel = .warning
            } else {
                self.pressureLevel = .normal
            }
            self.fetchStats()
        }
        src.resume()
        pressureSource = src
    }

    func startTimer() {
        fetchStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.fetchStats()
        }
    }

    func stopTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
    }

    var isPaused: Bool = false

    func fetchStats() {
        guard !isPaused else { return }
        bgQueue.async { [weak self] in
            guard let self else { return }

            var vmStats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let pageSize = UInt64(vm_kernel_page_size)

            let result = withUnsafeMutablePointer(to: &vmStats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }

            guard result == KERN_SUCCESS else { return }

            let gb = 1_073_741_824.0
            let totalRAMBytes = UInt64(ProcessInfo.processInfo.physicalMemory)
            let newSwap       = Double(vmStats.swapins + vmStats.swapouts) / gb
            let newCompressed = Double(vmStats.compressor_page_count) * Double(pageSize) / gb
            let newApp        = Double(vmStats.internal_page_count - vmStats.purgeable_count) * Double(pageSize) / gb
            let newWired      = Double(vmStats.wire_count) * Double(pageSize) / gb
            let newFree       = Double(vmStats.free_count) * Double(pageSize) / gb
            // Apple vm_stat formula: used = totalRAM - (truly_free + file_cache)
            let usedBytes     = totalRAMBytes -
                                (UInt64(vmStats.free_count - vmStats.speculative_count) +
                                 UInt64(vmStats.external_page_count)) * pageSize
            let newUsed       = Double(usedBytes) / gb
            let newCached     = Double(UInt64(vmStats.external_page_count) * pageSize) / gb

            let threshold = 50.0 / 1024  // 50 MB in GB
            let changed = abs(newSwap - self.lastSwap) > threshold
                       || abs(newCompressed - self.lastCompressed) > threshold
                       || abs(newApp - self.lastApp) > threshold
                       || abs(newWired - self.lastWired) > threshold
                       || abs(newFree - self.lastFree) > threshold

            guard changed || self.lastSwap < 0 else { return }

            self.lastSwap       = newSwap
            self.lastCompressed = newCompressed
            self.lastApp        = newApp
            self.lastWired      = newWired
            self.lastFree       = newFree

            DispatchQueue.main.async {
                self.memoryUsedGB  = newUsed
                self.cachedFilesGB = newCached
                self.swapUsedGB    = newSwap
                self.compressedGB  = newCompressed
                self.appMemoryGB   = newApp
                self.wiredGB       = newWired
            }
        }
    }
}
