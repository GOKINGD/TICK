#!/usr/bin/swift

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("Usage: generate_icon.swift <output-iconset-dir>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default

try? fileManager.removeItem(at: outputDirectory)
try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let specs: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for spec in specs {
    let pixelSize = spec.points * spec.scale
    let image = drawIcon(size: pixelSize)
    let name = "icon_\(spec.points)x\(spec.points)\(spec.scale == 2 ? "@2x" : "").png"
    let destination = outputDirectory.appendingPathComponent(name)
    try writePNG(image: image, to: destination)
}

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let backgroundRect = rect.insetBy(dx: CGFloat(size) * 0.05, dy: CGFloat(size) * 0.05)
    let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: CGFloat(size) * 0.23, yRadius: CGFloat(size) * 0.23)

    NSGraphicsContext.saveGraphicsState()
    backgroundPath.addClip()

    let backgroundGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.90, green: 0.97, blue: 0.99, alpha: 1),
        NSColor(calibratedRed: 0.67, green: 0.90, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.84, blue: 0.72, alpha: 1)
    ])!
    backgroundGradient.draw(in: backgroundPath, angle: -45)

    let glow1 = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(size) * 0.05,
        y: CGFloat(size) * 0.57,
        width: CGFloat(size) * 0.5,
        height: CGFloat(size) * 0.5
    ))
    NSColor.white.withAlphaComponent(0.35).setFill()
    glow1.fill()

    let glow2 = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(size) * 0.55,
        y: CGFloat(size) * 0.08,
        width: CGFloat(size) * 0.28,
        height: CGFloat(size) * 0.28
    ))
    NSColor(calibratedRed: 0.19, green: 0.64, blue: 0.84, alpha: 0.22).setFill()
    glow2.fill()

    NSGraphicsContext.restoreGraphicsState()

    let cardRect = NSRect(
        x: CGFloat(size) * 0.15,
        y: CGFloat(size) * 0.13,
        width: CGFloat(size) * 0.70,
        height: CGFloat(size) * 0.74
    )
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: CGFloat(size) * 0.16, yRadius: CGFloat(size) * 0.16)

    NSColor.white.withAlphaComponent(0.72).setFill()
    cardPath.fill()

    NSColor.white.withAlphaComponent(0.62).setStroke()
    cardPath.lineWidth = max(2, CGFloat(size) * 0.01)
    cardPath.stroke()

    let symbolArea = NSRect(
        x: cardRect.minX,
        y: cardRect.minY + CGFloat(size) * 0.12,
        width: cardRect.width,
        height: cardRect.height * 0.58
    )
    drawSymbols(in: symbolArea, size: size)

    let pillRect = NSRect(
        x: cardRect.midX - CGFloat(size) * 0.18,
        y: cardRect.minY + CGFloat(size) * 0.08,
        width: CGFloat(size) * 0.36,
        height: CGFloat(size) * 0.09
    )
    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
    NSColor(calibratedRed: 0.15, green: 0.47, blue: 0.73, alpha: 0.95).setFill()
    pillPath.fill()

    image.unlockFocus()
    return image
}

func drawSymbols(in rect: NSRect, size: Int) {
    let dropConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.23, weight: .medium)
    let walkConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.24, weight: .medium)

    if let drop = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: nil)?.withSymbolConfiguration(dropConfig) {
        let dropRect = NSRect(
            x: rect.midX - CGFloat(size) * 0.19,
            y: rect.midY + CGFloat(size) * 0.01,
            width: CGFloat(size) * 0.18,
            height: CGFloat(size) * 0.22
        )
        drawTintedSymbol(drop, in: dropRect, color: NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.83, alpha: 1))
    }

    if let walk = NSImage(systemSymbolName: "figure.walk.motion", accessibilityDescription: nil)?.withSymbolConfiguration(walkConfig) {
        let walkRect = NSRect(
            x: rect.midX - CGFloat(size) * 0.01,
            y: rect.midY - CGFloat(size) * 0.02,
            width: CGFloat(size) * 0.20,
            height: CGFloat(size) * 0.24
        )
        drawTintedSymbol(walk, in: walkRect, color: NSColor(calibratedRed: 0.13, green: 0.34, blue: 0.58, alpha: 1))
    }
}

func drawTintedSymbol(_ image: NSImage, in rect: NSRect, color: NSColor) {
    color.set()
    image.draw(in: rect, from: .zero, operation: .sourceAtop, fraction: 1)
}

func writePNG(image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let representation = NSBitmapImageRep(data: tiff),
        let data = representation.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "GenerateIcon", code: 1)
    }

    try data.write(to: url)
}
