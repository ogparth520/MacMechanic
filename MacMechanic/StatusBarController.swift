import AppKit
import SwiftUI

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusGaugeHostingView: NSHostingView<StatusItemGaugeView>!
    private var panel: DropdownPanel!
    private var hostingView: NSHostingView<PopoverView>!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDismissAt: TimeInterval = 0
    private let dismissDebounce: TimeInterval = 0.25

    private let monitor = MemoryMonitor.shared
    private let batteryMonitor = BatteryMonitor.shared
    private let cpuMonitor = CPUMonitor.shared
    private let processMonitor = ProcessMonitor.shared

    override init() {
        super.init()
        setupStatusItem()
        setupPanel()
    }

    private func setupStatusItem() {
        let itemWidth: CGFloat = 112
        statusItem = NSStatusBar.system.statusItem(withLength: itemWidth)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            print("[MacMechanic] ERROR: could not get status item button")
            return
        }

        button.image = nil
        button.title = ""
        button.action = #selector(togglePanel(_:))
        button.target = self

        statusGaugeHostingView = NSHostingView(
            rootView: StatusItemGaugeView(cpu: cpuMonitor, memory: monitor)
        )
        statusGaugeHostingView.translatesAutoresizingMaskIntoConstraints = false
        statusGaugeHostingView.wantsLayer = true
        button.addSubview(statusGaugeHostingView)
        NSLayoutConstraint.activate([
            statusGaugeHostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusGaugeHostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusGaugeHostingView.topAnchor.constraint(equalTo: button.topAnchor),
            statusGaugeHostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        print("[MacMechanic] Status item created — live gauges enabled")
    }

    private func setupPanel() {
        hostingView = NSHostingView(
            rootView: PopoverView(monitor: monitor, battery: batteryMonitor,
                                  cpu: cpuMonitor, processes: processMonitor)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel = DropdownPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovable = false
        panel.contentView = background
    }

    @objc func togglePanel(_ sender: AnyObject?) {
        // The outside-click monitor fires on mouseDown and calls hidePanel(),
        // flipping panel.isVisible to false before this button action (which
        // runs on mouseUp). Without this guard, the toggle would immediately
        // reopen the panel that the user just clicked to close.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDismissAt < dismissDebounce {
            return
        }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Let SwiftUI report its preferred size, then size the panel to fit.
        hostingView.layoutSubtreeIfNeeded()
        let intrinsic = hostingView.intrinsicContentSize
        let width = intrinsic.width > 0 ? intrinsic.width : 300
        let height = intrinsic.height > 0 ? intrinsic.height : 400

        let buttonFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let x = buttonFrame.midX - width / 2
        let y = buttonFrame.minY - height - 4

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()

        installDismissMonitors()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        removeDismissMonitors()
        lastDismissAt = ProcessInfo.processInfo.systemUptime
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if NSApp.modalWindow == nil, event.window !== self.panel {
                self.hidePanel()
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
    }
}

// MARK: - Status item gauge

private struct StatusItemGaugeView: View {
    @ObservedObject var cpu: CPUMonitor
    @ObservedObject var memory: MemoryMonitor

    private var memoryPercent: Double {
        guard memory.totalRAMGB > 0 else { return 0 }
        return min(max(memory.memoryUsedGB / memory.totalRAMGB * 100, 0), 100)
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusMetricGauge(label: "CPU", percent: cpu.overallPercent)
            StatusMetricGauge(label: "GPU", percent: Double(cpu.gpuPercent))
            StatusMetricGauge(label: "MEM", percent: memoryPercent)
        }
        .padding(.horizontal, 5)
        .frame(width: 112, height: NSStatusBar.system.thickness)
    }
}

private struct StatusMetricGauge: View {
    let label: String
    let percent: Double

    private let barCount = 5

    private var activeBars: Int {
        guard percent > 0 else { return 0 }
        return min(barCount, max(1, Int(ceil(percent / 100 * Double(barCount)))))
    }

    private var fillColor: Color {
        switch percent {
        case ..<50: return .green
        case ..<80: return .orange
        default:    return .red
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .lineLimit(1)
            HStack(spacing: 1) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < activeBars ? fillColor : Color.secondary.opacity(0.28))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(width: 30)
    }
}

// MARK: - DropdownPanel

/// Borderless NSPanel used as a menu bar dropdown — no title bar, no arrow,
/// no key-window activation flicker.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
