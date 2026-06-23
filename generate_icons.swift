#!/usr/bin/swift
// Run from the project root:  swift generate_icons.swift

import AppKit

// AppKit needs a running application context to resolve SF Symbols
let _ = NSApplication.shared

// Tint a template NSImage to white using a white fill + destinationIn mask
func whiteTinted(_ source: NSImage) -> NSImage {
    let result = NSImage(size: source.size)
    result.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: NSPoint.zero, size: source.size).fill()
    source.draw(
        in: NSRect(origin: NSPoint.zero, size: source.size),
        from: NSRect.zero,
        operation: NSCompositingOperation.destinationIn,
        fraction: 1.0
    )
    result.unlockFocus()
    return result
}

func render(size: Int) -> Data? {
    let s = CGFloat(size)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Rounded square background — #2C2C2E, corner radius ~17.5% (Apple HIG)
    NSColor(red: 44/255, green: 44/255, blue: 46/255, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
        xRadius: s * 0.175, yRadius: s * 0.175
    ).fill()

    // wrench.and.screwdriver.fill, white, centered at ~60% of icon size
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .medium)
    if let raw = NSImage(
        systemSymbolName: "wrench.and.screwdriver.fill",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(cfg) {
        let sym = whiteTinted(raw)
        let sw = sym.size.width, sh = sym.size.height
        sym.draw(
            in: NSRect(x: (s - sw) / 2, y: (s - sh) / 2, width: sw, height: sh),
            from: NSRect.zero,
            operation: NSCompositingOperation.sourceOver,
            fraction: 1.0
        )
    }

    return rep.representation(using: .png, properties: [:])
}

let outDir = "MacMechanic/Assets.xcassets/AppIcon.appiconset"

let specs: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_64x64.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, name) in specs {
    if let data = render(size: size) {
        try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
        print("✓ \(name) (\(size)×\(size))")
    } else {
        print("✗ failed: \(name)")
    }
}
print("Done — \(specs.count) icons written to \(outDir)")
