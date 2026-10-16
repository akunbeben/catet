#!/usr/bin/env xcrun swift
import AppKit
import Foundation

let designSize: CGFloat = 512

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func renderIcon(pixelSize: Int, markOnly: Bool = false) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CatetIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate a \(pixelSize)-pixel icon image."])
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    graphics.shouldAntialias = true
    graphics.cgContext.scaleBy(x: CGFloat(pixelSize) / designSize, y: CGFloat(pixelSize) / designSize)
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: designSize, height: designSize))

    if !markOnly {
        // Match the 80.5% tile footprint used by native macOS application icons.
        graphics.cgContext.translateBy(x: designSize / 2, y: designSize / 2)
        graphics.cgContext.scaleBy(x: 412 / 494, y: 412 / 494)
        graphics.cgContext.translateBy(x: -designSize / 2, y: -designSize / 2)
        NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1).setFill()
        roundedRect(CGRect(x: 9, y: 9, width: 494, height: 494), radius: 108).fill()
    }

    // The supplied Catet mark: six rounded blue bars on a charcoal tile.
    let heights: [CGFloat] = [58, 154, 232, 120, 184, 78]
    let scale: CGFloat = markOnly ? 2 : 1
    let barWidth: CGFloat = 20 * scale
    let centerY: CGFloat = markOnly ? 256 : 240
    NSColor(srgbRed: 0, green: 0.51, blue: 0.92, alpha: 1).setFill()
    for (index, height) in heights.enumerated() {
        roundedRect(
            CGRect(x: 256 + (CGFloat(index) - 2.5) * 42 * scale - barWidth / 2,
                   y: centerY - height * scale / 2, width: barWidth, height: height * scale),
            radius: barWidth / 2
        ).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CatetIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode the \(pixelSize)-pixel icon image."])
    }
    return png
}

func generateIcon(at destination: URL) throws {
    let manager = FileManager.default
    let parent = destination.deletingLastPathComponent()
    try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    let temporaryRoot = manager.temporaryDirectory.appendingPathComponent("CatetIcon-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporaryRoot) }

    let iconset = temporaryRoot.appendingPathComponent("Catet.iconset", isDirectory: true)
    try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
    let representations: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, size) in representations {
        try renderIcon(pixelSize: size).write(to: iconset.appendingPathComponent(name), options: .atomic)
    }

    let generated = temporaryRoot.appendingPathComponent("Catet.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", generated.path, iconset.path]
    let errors = Pipe()
    process.standardError = errors
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        throw NSError(domain: "CatetIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not run /usr/bin/iconutil: \(error.localizedDescription)"])
    }
    guard process.terminationStatus == 0 else {
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw NSError(domain: "CatetIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "iconutil failed to create the ICNS file (status \(process.terminationStatus))." : "iconutil failed: \(detail)"])
    }

    let icnsData = try Data(contentsOf: generated)
    try icnsData.write(to: destination, options: .atomic)
    try renderIcon(pixelSize: 128, markOnly: true).write(to: parent.appendingPathComponent("CatetMark.png"), options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: xcrun swift scripts/make-icon.swift OUTPUT_ICNS\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try generateIcon(at: URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL)
} catch {
    fputs("make-icon: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
