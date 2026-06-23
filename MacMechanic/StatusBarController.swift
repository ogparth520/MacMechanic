import AppKit
import SwiftUI

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            print("[MacMechanic] ERROR: could not get status item button")
            return
        }

        if let image = NSImage(systemSymbolName: "wrench.and.screwdriver.fill",
                               accessibilityDescription: "MacMechanic") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "MM"
        }

        button.action = #selector(togglePanel(_:))
        button.target = self
        print("[MacMechanic] Status item created — image: \(button.image != nil ? "set" : "nil")")
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
            if event.window !== self.panel {
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

// MARK: - DropdownPanel

/// Borderless NSPanel used as a menu bar dropdown — no title bar, no arrow,
/// no key-window activation flicker.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
