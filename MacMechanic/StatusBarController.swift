import AppKit
import SwiftUI

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = MemoryMonitor.shared
    private let batteryMonitor = BatteryMonitor.shared
    private let cpuMonitor = CPUMonitor.shared
    private let processMonitor = ProcessMonitor.shared

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
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

        button.action = #selector(togglePopover(_:))
        button.target = self
        print("[MacMechanic] Status item created — image: \(button.image != nil ? "set" : "nil")")
    }

    private func setupPopover() {
        let hostingVC = NSHostingController(
            rootView: PopoverView(monitor: monitor, battery: batteryMonitor,
                                  cpu: cpuMonitor, processes: processMonitor)
        )
        // Track SwiftUI ideal size so the popover resizes when tabs change
        hostingVC.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = hostingVC
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let buttonFrame = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Reposition and hide arrow frame after the popover window is created
            DispatchQueue.main.async {
                if let popoverWindow = self.popover.contentViewController?.view.window {
                    // Hide the system arrow/frame view
                    if let frameView = popoverWindow.contentView?.superview {
                        for subview in frameView.subviews
                            where NSStringFromClass(type(of: subview)).contains("Frame") {
                            subview.isHidden = true
                        }
                    }
                    // Center below the menu bar icon
                    let popoverSize = popoverWindow.frame.size
                    let x = buttonFrame.midX - popoverSize.width / 2
                    let y = buttonFrame.minY - popoverSize.height - 4
                    popoverWindow.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
    }

}
