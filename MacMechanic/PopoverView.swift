import SwiftUI

// MARK: - Tab

private enum Tab: Int, CaseIterable {
    case memory, battery, cpu, gpu
    var label: String {
        switch self {
        case .memory:  return "Memory"
        case .battery: return "Battery"
        case .cpu:     return "CPU"
        case .gpu:     return "GPU"
        }
    }
}

// MARK: - Root

struct PopoverView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var cpu: CPUMonitor
    @ObservedObject var processes: ProcessMonitor

    @State private var tab: Tab = .memory
    @State private var isPaused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch tab {
                case .memory:  MemoryTabView(monitor: monitor, processes: processes)
                case .battery: BatteryTabView(battery: battery, processes: processes)
                case .cpu:     CPUTabView(cpu: cpu, processes: processes)
                case .gpu:     GPUTabView(cpu: cpu)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            Divider()

            HStack {
                Button {
                    isPaused.toggle()
                    MemoryMonitor.shared.isPaused   = isPaused
                    BatteryMonitor.shared.isPaused  = isPaused
                    CPUMonitor.shared.isPaused      = isPaused
                    ProcessMonitor.shared.isPaused  = isPaused
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Memory tab

private struct MemoryTabView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var processes: ProcessMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 2) {
                Text(monitor.pressureLevel.label)
                    .font(.title2.bold())
                    .foregroundColor(Color(monitor.pressureLevel.color))
                Text("Memory Pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Divider()

            // Stats
            VStack(spacing: 0) {
                statRow("Memory Used",  gbStr(monitor.memoryUsedGB), labelColor: .primary)
                statRow("Cached Files", gbStr(monitor.cachedFilesGB))
                statRow("App Memory",   gbStr(monitor.appMemoryGB))
                statRow("Wired",        gbStr(monitor.wiredGB))
                statRow("Compressed",   gbStr(monitor.compressedGB))
                statRow("Swap Used",    gbStr(monitor.swapUsedGB))
                statRow("Total RAM",    gbStr(monitor.totalRAMGB))
            }
            .padding(.vertical, 5)

            Divider()

            ProcessListView(processes: processes.byMemory, valueKey: \.memoryFormatted)
        }
    }
}

// MARK: - Battery tab

private struct BatteryTabView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var processes: ProcessMonitor

    var body: some View {
        VStack(spacing: 0) {
            if !battery.isPresent {
                Spacer()
                Text("No Battery").foregroundStyle(.secondary)
                Spacer()
            } else {
                // Hero
                VStack(spacing: 2) {
                    Text("\(battery.chargePercent)%")
                        .font(.title2.bold())
                    Text("Battery · \(battery.chargingStatus)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Divider()

                // Stats
                VStack(spacing: 0) {
                    statRow("Health",   String(format: "%.1f%%", battery.healthPercent))
                    statRow("Cycles",   "\(battery.cycleCount)")
                    statRow("Capacity", "\(battery.nominalCapacityMAh) / \(battery.designCapacityMAh) mAh")
                    statRow(battery.isCharging ? "Time to Full" : "Time Left",
                            battery.timeRemaining)
                    statRow(battery.isCharging ? "Charging" : "Power Draw",
                            String(format: "%.1f W", battery.powerWatts))
                }
                .padding(.vertical, 5)

                Divider()

                ProcessListView(processes: processes.byEnergy, valueKey: \.energyFormatted)
            }
        }
    }
}

// MARK: - CPU tab

private struct CPUTabView: View {
    @ObservedObject var cpu: CPUMonitor
    @ObservedObject var processes: ProcessMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 2) {
                Text(String(format: "%.0f%%", cpu.overallPercent))
                    .font(.title2.bold())
                Text("CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 8)

            SparklineView(values: cpu.cpuHistory)
                .frame(height: 36)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            // Stats
            VStack(spacing: 0) {
                statRow("System", String(format: "%.0f%%", cpu.systemPercent))
                statRow("User",   String(format: "%.0f%%", cpu.userPercent))
                statRow("Idle",   String(format: "%.0f%%", cpu.idlePercent))
                statRow("P-Cores (\(cpu.pCoreCount))",
                        String(format: "%.0f%%", cpu.pCorePercent))
                statRow("E-Cores (\(cpu.eCoreCount))",
                        String(format: "%.0f%%", cpu.eCorePercent))
            }
            .padding(.vertical, 5)

            Divider()

            ProcessListView(processes: processes.byCPU, valueKey: \.cpuFormatted)
        }
    }
}

// MARK: - GPU tab

private struct GPUTabView: View {
    @ObservedObject var cpu: CPUMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Hero
            VStack(spacing: 2) {
                Text("\(cpu.gpuPercent)%")
                    .font(.title2.bold())
                Text(cpu.gpuModelName.isEmpty ? "GPU" : cpu.gpuModelName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 8)

            SparklineView(values: cpu.gpuHistory)
                .frame(height: 36)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            // Stats
            VStack(spacing: 0) {
                statRow("Tiler",    "\(cpu.tilerPercent)%")
                statRow("Renderer", "\(cpu.rendererPercent)%")
                if cpu.gpuMemoryGB > 0 {
                    statRow("Memory", String(format: "%.1f GB", cpu.gpuMemoryGB))
                }
            }
            .padding(.vertical, 5)
        }
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func statRow(_ label: String, _ value: String,
                     labelColor: Color = .secondary) -> some View {
    HStack(spacing: 4) {
        Text(label).foregroundStyle(labelColor)
        Spacer(minLength: 8)
        Text(value).foregroundStyle(.primary)
    }
    .font(.body)
    .padding(.horizontal, 16)
    .padding(.vertical, 3)
}

private func gbStr(_ gb: Double) -> String {
    String(format: "%.1f GB", gb)
}

// MARK: - Process list

private struct ProcessListView: View {
    let processes: [AppProcess]
    let valueKey: KeyPath<AppProcess, String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TOP PROCESSES")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if processes.isEmpty {
                Text("Loading…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            } else {
                ForEach(processes) { p in
                    HStack(spacing: 4) {
                        Text(p.name)
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(p[keyPath: valueKey])
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Sparkline

private struct SparklineView: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(values.max() ?? 100, 5)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat(v) / CGFloat(peak))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else       { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
        }
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
