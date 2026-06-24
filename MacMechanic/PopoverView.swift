import SwiftUI
import AppKit

// MARK: - Root

struct PopoverView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var cpu: CPUMonitor
    @ObservedObject var processes: ProcessMonitor

    @State private var isPaused: Bool = false
    @State private var pressureHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var batteryHistory: [Double] = Array(repeating: 0, count: 30)

    private let historyLimit = 60
    // Memory pressure and battery percent rarely change, so .onReceive on
    // @Published won't accumulate history. Drive sampling from a timer so
    // every tick adds a fresh sample to both buffers.
    private let sampleTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
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
                            history: padded(cpu.cpuHistory),
                            peak: 100,
                            colorFor: { v in
                                switch v {
                                case ..<50: return .green
                                case ..<80: return .orange
                                default:    return .red
                                }
                            }
                        )
                        StatCard(
                            label: "Memory",
                            value: String(format: "%.1f GB", monitor.memoryUsedGB),
                            history: pressureHistory,
                            // peak = 1 so the normalized pressure values
                            // (0.30 / 0.65 / 1.00) translate directly to bar
                            // height: Normal 30%, Warning 65%, Critical 100%.
                            peak: 1,
                            colorFor: { v in
                                // v: 0.30 = Normal, 0.65 = Warning, 1.00 = Critical
                                switch v {
                                case ..<0.50: return .green
                                case ..<0.85: return .orange
                                default:      return .red
                                }
                            }
                        )
                        StatCard(
                            label: "Battery",
                            value: battery.isPresent ? "\(battery.chargePercent)%" : "—",
                            history: batteryHistory,
                            peak: 100,
                            colorFor: { v in
                                switch v {
                                case ..<20: return .red
                                case ..<50: return .orange
                                default:    return .green
                                }
                            }
                        )
                        StatCard(
                            label: "GPU",
                            value: "\(cpu.gpuPercent)%",
                            history: padded(cpu.gpuHistory),
                            peak: 100,
                            colorFor: { v in
                                switch v {
                                case ..<50: return .green
                                case ..<80: return .orange
                                default:    return .red
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                    Divider()

                ProcessListView(processMonitor: processes)
                    .padding(.bottom, 8)
            }

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
        .onReceive(monitor.$pressureLevel) { newValue in
            print("[MacMechanic] pressureLevel changed → \(newValue)")
        }
        .onReceive(sampleTimer) { _ in
            appendSample(
                pressureSampleValue(monitor.pressureLevel),
                into: &pressureHistory
            )
            if battery.isPresent {
                appendSample(Double(battery.chargePercent), into: &batteryHistory)
            }
        }
    }

    private func appendSample(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private func pressureSampleValue(_ level: PressureLevel) -> Double {
        // Encode pressure as a normalized bar height: Normal 30%, Warning 65%,
        // Critical 100% (used with peak = 1 on the Memory card).
        switch level {
        case .normal:   return 0.30
        case .warning:  return 0.65
        case .critical: return 1.00
        }
    }

    /// Left-pads `history` with zero samples so freshly-launched cards render
    /// a full row of bars instead of leading empty placeholders.
    private func padded(_ history: [Double], to count: Int = 30) -> [Double] {
        if history.count >= count { return history }
        return Array(repeating: 0, count: count - history.count) + history
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let label: String
    let value: String
    let history: [Double]
    let peak: Double
    let colorFor: (Double) -> Color

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
            BarHistoryView(values: history, peak: peak, colorFor: colorFor)
                .frame(height: 48)
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
    let colorFor: (Double) -> Color

    private let slotCount = 24
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = spacing * CGFloat(slotCount - 1)
            let barWidth = max(
                (geo.size.width - totalSpacing) / CGFloat(slotCount),
                1
            )

            let recent = Array(values.suffix(slotCount))
            let leadingPad = slotCount - recent.count

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<slotCount, id: \.self) { i in
                    let v: Double = i < leadingPad ? 0 : recent[i - leadingPad]
                    let normalized: CGFloat = peak > 0
                        ? max(0, min(CGFloat(v / peak), 1))
                        : 0
                    let barHeight = max(geo.size.height * normalized, 1)
                    // Treat any zero sample as a neutral baseline — keeps the
                    // pre-fill slots and idle states reading as "no data"
                    // rather than triggering the lowest threshold color.
                    let fill: Color = v <= 0
                        ? Color.gray.opacity(0.35)
                        : colorFor(v)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(fill)
                        .frame(width: barWidth, height: barHeight)
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

private enum ProcessFilter: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case all  = "All Processes"
    var id: String { rawValue }
}

private enum ProcessSort: String, CaseIterable, Identifiable {
    case memory    = "Memory"
    case cpuUsage  = "CPU Usage"
    case startTime = "Start Time"
    var id: String { rawValue }
}

private struct ProcessListView: View {
    @ObservedObject var processMonitor: ProcessMonitor

    @State private var filter: ProcessFilter = .apps
    @State private var sort: ProcessSort = .memory

    // Subprocesses spawned by user apps that show up in
    // NSWorkspace.runningApplications but aren't standalone apps.
    private static let appsFilterExclusions: Set<String> = [
        "WebKit WebContent",
        "WebKit GPU"
    ]

    private var visibleProcesses: [AppProcess] {
        var list = processMonitor.allProcesses
        if filter == .apps {
            let appPIDs = Set(
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .map { $0.processIdentifier }
            )
            list = list.filter { p in
                appPIDs.contains(p.id) && !Self.appsFilterExclusions.contains(p.name)
            }
        }
        switch sort {
        case .memory:
            list.sort { $0.memoryMB > $1.memoryMB }
        case .cpuUsage:
            list.sort { $0.cpuPercent > $1.cpuPercent }
        case .startTime:
            list.sort {
                let a = NSRunningApplication(processIdentifier: $0.id)?.launchDate ?? .distantPast
                let b = NSRunningApplication(processIdentifier: $1.id)?.launchDate ?? .distantPast
                return a > b
            }
        }
        return list
    }

    private func displayValue(for p: AppProcess) -> String {
        switch sort {
        case .memory:    return p.memoryFormatted
        case .cpuUsage:  return p.cpuFormatted
        case .startTime: return elapsedSinceLaunch(p.id)
        }
    }

    /// Time since the running application launched, formatted like "2h 34m",
    /// "45m", or "1d 3h". Returns "—" when the process isn't tracked by
    /// NSWorkspace (non-app helpers).
    private func elapsedSinceLaunch(_ pid: Int32) -> String {
        guard let launchDate = NSRunningApplication(processIdentifier: pid)?.launchDate
        else { return "—" }
        let seconds = Int(Date().timeIntervalSince(launchDate))
        guard seconds >= 0 else { return "—" }
        let days  = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let mins  = (seconds % 3_600) / 60
        if days  > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Picker("Filter", selection: $filter) {
                    ForEach(ProcessFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 8)

                Picker("Sort", selection: $sort) {
                    ForEach(ProcessSort.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            let list = visibleProcesses
            if list.isEmpty {
                Text(processMonitor.allProcesses.isEmpty ? "Loading…" : "No matching processes")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { p in
                            ProcessRowView(
                                process: p,
                                displayValue: displayValue(for: p),
                                processMonitor: processMonitor
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }
        }
    }
}

// MARK: - Process row

private struct ProcessRowView: View {
    let process: AppProcess
    let displayValue: String
    @ObservedObject var processMonitor: ProcessMonitor

    @State private var isHovering = false
    @State private var forceQuitSucceeded = false

    var body: some View {
        HStack(spacing: 8) {
            ProcessIconView(pid: process.id, name: process.name)
            Text(process.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if forceQuitSucceeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            } else if isHovering {
                Button {
                    confirmForceQuit()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Force Quit")
            }
            Text(displayValue)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func confirmForceQuit() {
        print("[MacMechanic] Force Quit button clicked: name=\(process.name), pid=\(process.id)")

        let alert = NSAlert()
        alert.messageText = "Force Quit Application?"
        alert.informativeText = "Are you sure you want to force quit \(process.name)?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            print("[MacMechanic] Force Quit cancelled: name=\(process.name), pid=\(process.id)")
            return
        }

        print("[MacMechanic] Force Quit confirmed: name=\(process.name), pid=\(process.id)")
        if let message = processMonitor.forceQuit(process) {
            forceQuitSucceeded = false
            showForceQuitError(message)
        } else {
            forceQuitSucceeded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                forceQuitSucceeded = false
            }
        }
    }

    private func showForceQuitError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Unable to Force Quit"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Process icon

private struct ProcessIconView: View {
    let pid: Int32
    let name: String

    private static let safariIcon: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()

    private var iconImage: NSImage? {
        if name == "WebKit WebContent" || name == "WebKit Networking" || name.hasPrefix("Safari ") {
            return Self.safariIcon
        }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    var body: some View {
        Group {
            if let nsImage = iconImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
        }
        .frame(width: 20, height: 20)
    }
}
