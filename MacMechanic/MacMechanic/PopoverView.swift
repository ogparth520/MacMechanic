import SwiftUI

// MARK: - Root

struct PopoverView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var cpu: CPUMonitor
    @ObservedObject var processes: ProcessMonitor

    @State private var isPaused: Bool = false
    @State private var memoryHistory: [Double] = []
    @State private var batteryHistory: [Double] = []

    private let historyLimit = 30

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ],
                        spacing: 8
                    ) {
                        StatCard(
                            label: "CPU",
                            value: String(format: "%.0f%%", cpu.overallPercent),
                            history: cpu.cpuHistory,
                            peak: 100
                        )
                        StatCard(
                            label: "Memory",
                            value: String(format: "%.1f GB", monitor.memoryUsedGB),
                            history: memoryHistory,
                            peak: max(monitor.totalRAMGB, 1)
                        )
                        StatCard(
                            label: "Battery",
                            value: battery.isPresent ? "\(battery.chargePercent)%" : "—",
                            history: batteryHistory,
                            peak: 100
                        )
                        StatCard(
                            label: "GPU",
                            value: "\(cpu.gpuPercent)%",
                            history: cpu.gpuHistory,
                            peak: 100
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                    Divider()

                    ProcessListView(
                        processes: processes.byMemory,
                        valueKey: \.memoryFormatted
                    )
                    .padding(.bottom, 8)
                }
            }
            .frame(maxHeight: 480)

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
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(monitor.$memoryUsedGB) { newValue in
            appendSample(newValue, into: &memoryHistory)
        }
        .onReceive(battery.$chargePercent) { newValue in
            guard battery.isPresent else { return }
            appendSample(Double(newValue), into: &batteryHistory)
        }
    }

    private func appendSample(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let label: String
    let value: String
    let history: [Double]
    let peak: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.callout.bold().monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            BarHistoryView(values: history, peak: peak)
                .frame(height: 24)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

// MARK: - Mini bar graph

private struct BarHistoryView: View {
    let values: [Double]
    let peak: Double

    var body: some View {
        GeometryReader { geo in
            let count = max(values.count, 1)
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(max(count - 1, 0))
            let barWidth = max((geo.size.width - totalSpacing) / CGFloat(count), 1)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    let normalized = peak > 0
                        ? max(0, min(CGFloat(v / peak), 1))
                        : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(
                            width: barWidth,
                            height: max(geo.size.height * normalized, 1)
                        )
                }
            }
            .frame(
                width: geo.size.width,
                height: geo.size.height,
                alignment: .bottomLeading
            )
        }
    }
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
