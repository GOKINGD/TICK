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
    let suffix = spec.scale == 2 ? "@2x" : ""
    let name = "icon_\(spec.points)x\(spec.points)\(suffix).png"
    try writePNG(image: image, to: outputDirectory.appendingPathComponent(name))
}

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let baseRect = canvas.insetBy(dx: CGFloat(size) * 0.055, dy: CGFloat(size) * 0.055)
    let corner = CGFloat(size) * 0.22
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: corner, yRadius: corner)

    NSGraphicsContext.saveGraphicsState()
    basePath.addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.09, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.18, blue: 0.17, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.40, blue: 0.35, alpha: 1)
    ])!.draw(in: basePath, angle: -35)

    drawAmbientGlow(size: size, in: baseRect)
    drawGrid(size: size, in: baseRect)
    NSGraphicsContext.restoreGraphicsState()

    drawOuterStroke(path: basePath, size: size)
    drawFace(size: size, baseRect: baseRect)
    drawLetter(size: size, baseRect: baseRect)

    image.unlockFocus()
    return image
}

func drawAmbientGlow(size: Int, in rect: NSRect) {
    let tealGlow = NSBezierPath(ovalIn: NSRect(
        x: rect.minX + CGFloat(size) * 0.42,
        y: rect.minY + CGFloat(size) * 0.48,
        width: CGFloat(size) * 0.58,
        height: CGFloat(size) * 0.50
    ))
    NSColor(calibratedRed: 0.42, green: 0.95, blue: 0.78, alpha: 0.24).setFill()
    tealGlow.fill()

    let warmGlow = NSBezierPath(ovalIn: NSRect(
        x: rect.minX + CGFloat(size) * 0.02,
        y: rect.minY - CGFloat(size) * 0.10,
        width: CGFloat(size) * 0.52,
        height: CGFloat(size) * 0.42
    ))
    NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.45, alpha: 0.17).setFill()
    warmGlow.fill()
}

func drawGrid(size: Int, in rect: NSRect) {
    guard size >= 64 else { return }

    let gridColor = NSColor.white.withAlphaComponent(0.08)
    gridColor.setStroke()

    let step = CGFloat(size) * 0.13
    var x = rect.minX + step
    while x < rect.maxX {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: rect.minY))
        path.line(to: NSPoint(x: x + CGFloat(size) * 0.08, y: rect.maxY))
        path.lineWidth = max(1, CGFloat(size) * 0.002)
        path.stroke()
        x += step
    }

    var y = rect.minY + step
    while y < rect.maxY {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: y))
        path.line(to: NSPoint(x: rect.maxX, y: y + CGFloat(size) * 0.05))
        path.lineWidth = max(1, CGFloat(size) * 0.002)
        path.stroke()
        y += step
    }
}

func drawOuterStroke(path: NSBezierPath, size: Int) {
    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = max(1.5, CGFloat(size) * 0.012)
    path.stroke()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = CGFloat(size) * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(size) * 0.012)
    shadow.set()
}

func drawFace(size: Int, baseRect: NSRect) {
    let faceRect = NSRect(
        x: baseRect.minX + CGFloat(size) * 0.18,
        y: baseRect.minY + CGFloat(size) * 0.20,
        width: CGFloat(size) * 0.64,
        height: CGFloat(size) * 0.50
    )
    let facePath = NSBezierPath(roundedRect: faceRect, xRadius: CGFloat(size) * 0.15, yRadius: CGFloat(size) * 0.15)

    NSColor(calibratedRed: 0.92, green: 0.99, blue: 0.96, alpha: 0.94).setFill()
    facePath.fill()

    NSColor(calibratedRed: 0.53, green: 0.89, blue: 0.77, alpha: 0.85).setStroke()
    facePath.lineWidth = max(1.5, CGFloat(size) * 0.012)
    facePath.stroke()

    drawEye(center: NSPoint(x: faceRect.minX + faceRect.width * 0.35, y: faceRect.midY + faceRect.height * 0.10), size: size)
    drawEye(center: NSPoint(x: faceRect.minX + faceRect.width * 0.65, y: faceRect.midY + faceRect.height * 0.10), size: size)
    drawSmile(in: faceRect, size: size)
    drawAntenna(size: size, faceRect: faceRect)
}

func drawEye(center: NSPoint, size: Int) {
    let radius = CGFloat(size) * 0.035
    let eye = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.13, alpha: 1).setFill()
    eye.fill()
}

func drawSmile(in faceRect: NSRect, size: Int) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: faceRect.midX - CGFloat(size) * 0.09, y: faceRect.midY - CGFloat(size) * 0.08))
    path.curve(
        to: NSPoint(x: faceRect.midX + CGFloat(size) * 0.09, y: faceRect.midY - CGFloat(size) * 0.08),
        controlPoint1: NSPoint(x: faceRect.midX - CGFloat(size) * 0.04, y: faceRect.midY - CGFloat(size) * 0.14),
        controlPoint2: NSPoint(x: faceRect.midX + CGFloat(size) * 0.04, y: faceRect.midY - CGFloat(size) * 0.14)
    )
    NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.13, alpha: 1).setStroke()
    path.lineWidth = max(1.5, CGFloat(size) * 0.015)
    path.lineCapStyle = .round
    path.stroke()
}

func drawAntenna(size: Int, faceRect: NSRect) {
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: faceRect.midX, y: faceRect.maxY))
    stem.line(to: NSPoint(x: faceRect.midX, y: faceRect.maxY + CGFloat(size) * 0.065))
    NSColor(calibratedRed: 0.53, green: 0.89, blue: 0.77, alpha: 0.9).setStroke()
    stem.lineWidth = max(1.5, CGFloat(size) * 0.012)
    stem.lineCapStyle = .round
    stem.stroke()

    let dotRadius = CGFloat(size) * 0.026
    let dot = NSBezierPath(ovalIn: NSRect(
        x: faceRect.midX - dotRadius,
        y: faceRect.maxY + CGFloat(size) * 0.055,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))
    NSColor(calibratedRed: 0.60, green: 0.98, blue: 0.82, alpha: 1).setFill()
    dot.fill()
}

func drawLetter(size: Int, baseRect: NSRect) {
    guard size >= 64 else { return }

    let badgeRect = NSRect(
        x: baseRect.minX + CGFloat(size) * 0.11,
        y: baseRect.maxY - CGFloat(size) * 0.24,
        width: CGFloat(size) * 0.24,
        height: CGFloat(size) * 0.15
    )
    let badge = NSBezierPath(roundedRect: badgeRect, xRadius: CGFloat(size) * 0.04, yRadius: CGFloat(size) * 0.04)
    NSColor(calibratedRed: 0.04, green: 0.11, blue: 0.12, alpha: 0.64).setFill()
    badge.fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.105, weight: .black)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    NSString(string: "T").draw(in: badgeRect.offsetBy(dx: 0, dy: CGFloat(size) * 0.006), withAttributes: attrs)
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
