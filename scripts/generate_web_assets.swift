#!/usr/bin/swift

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let outputDirectory = root
    .appendingPathComponent("docs", isDirectory: true)
    .appendingPathComponent("assets", isDirectory: true)

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

try writeJPEG(drawHero(width: 2200, height: 1300), quality: 0.86, to: outputDirectory.appendingPathComponent("tick-hero.jpg"))
try writeJPEG(drawTrace(width: 1800, height: 1120), quality: 0.88, to: outputDirectory.appendingPathComponent("tick-trace.jpg"))

func drawHero(width: Int, height: Int) -> NSImage {
    drawCanvas(width: width, height: height) { rect in
        fill(rect, color: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.10, alpha: 1))
        drawLinearBackdrop(rect)
        drawDesktopWindow(in: NSRect(x: 220, y: 170, width: 1280, height: 830))
        drawFloatingAgent(in: NSRect(x: 1325, y: 290, width: 515, height: 510))
        drawCursorTrail(in: rect)
    }
}

func drawTrace(width: Int, height: Int) -> NSImage {
    drawCanvas(width: width, height: height) { rect in
        fill(rect, color: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.97, alpha: 1))
        drawTraceWindow(in: NSRect(x: 120, y: 110, width: 1560, height: 900))
    }
}

func drawDesktopWindow(in rect: NSRect) {
    drawShadowedRoundedRect(rect, radius: 34, fillColor: NSColor(calibratedRed: 0.96, green: 0.98, blue: 0.97, alpha: 0.94), shadowAlpha: 0.22)
    drawRoundedRect(NSRect(x: rect.minX, y: rect.maxY - 78, width: rect.width, height: 78), radius: 34, color: NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.16, alpha: 0.96))

    for (index, color) in [
        NSColor(calibratedRed: 0.94, green: 0.32, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.72, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.38, alpha: 1)
    ].enumerated() {
        drawCircle(center: NSPoint(x: rect.minX + 42 + CGFloat(index * 28), y: rect.maxY - 39), radius: 7.5, color: color)
    }

    drawText("TICK Observer", at: NSPoint(x: rect.minX + 118, y: rect.maxY - 50), size: 24, weight: .bold, color: .white)
    drawPill(text: "active", in: NSRect(x: rect.maxX - 145, y: rect.maxY - 53, width: 92, height: 30), fill: NSColor(calibratedRed: 0.37, green: 0.85, blue: 0.68, alpha: 1), text: NSColor(calibratedRed: 0.03, green: 0.18, blue: 0.14, alpha: 1))

    let left = NSRect(x: rect.minX + 54, y: rect.minY + 72, width: 460, height: rect.height - 190)
    let right = NSRect(x: left.maxX + 34, y: left.minY, width: rect.width - left.width - 142, height: left.height)
    drawRoundedRect(left, radius: 24, color: NSColor.white.withAlphaComponent(0.82))
    drawRoundedRect(right, radius: 24, color: NSColor(calibratedRed: 0.98, green: 0.99, blue: 0.98, alpha: 0.92))

    drawText("Live Signals", at: NSPoint(x: left.minX + 28, y: left.maxY - 52), size: 24, weight: .bold, color: ink())
    let signals = [
        ("Clipboard", "Traceback detected", "0.95"),
        ("Terminal", "Build failed after test run", "0.95"),
        ("Browser", "API docs idle for 3s", "0.90"),
        ("Risk", "git reset --hard typed", "0.96")
    ]
    for (index, signal) in signals.enumerated() {
        let row = NSRect(x: left.minX + 24, y: left.maxY - 126 - CGFloat(index * 118), width: left.width - 48, height: 88)
        drawRoundedRect(row, radius: 18, color: index == 1 ? NSColor(calibratedRed: 0.88, green: 0.97, blue: 0.94, alpha: 1) : NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.96, alpha: 1))
        drawText(signal.0, at: NSPoint(x: row.minX + 22, y: row.maxY - 35), size: 18, weight: .bold, color: ink())
        drawText(signal.1, at: NSPoint(x: row.minX + 22, y: row.minY + 22), size: 15, weight: .regular, color: muted())
        drawText(signal.2, at: NSPoint(x: row.maxX - 62, y: row.maxY - 35), size: 17, weight: .bold, color: accent())
    }

    drawText("Extracted Actions", at: NSPoint(x: right.minX + 34, y: right.maxY - 60), size: 34, weight: .bold, color: ink())
    drawText("我猜你正在把教程落到本机环境", at: NSPoint(x: right.minX + 36, y: right.maxY - 122), size: 20, weight: .bold, color: accent())
    drawText("已从页面提取 3 条命令、2 个依赖和一个风险点。选择一个动作继续。", at: NSPoint(x: right.minX + 36, y: right.maxY - 164), size: 22, weight: .regular, color: ink())

    let code = NSRect(x: right.minX + 36, y: right.maxY - 350, width: right.width - 72, height: 124)
    drawRoundedRect(code, radius: 18, color: NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.12, alpha: 1))
    drawText("swift build --product TICKObserver", at: NSPoint(x: code.minX + 24, y: code.maxY - 42), size: 19, weight: .medium, color: NSColor(calibratedRed: 0.70, green: 0.95, blue: 0.86, alpha: 1), mono: true)
    drawText("error: cannot find 'riskOperation' in scope", at: NSPoint(x: code.minX + 24, y: code.minY + 30), size: 19, weight: .regular, color: NSColor(calibratedRed: 1.00, green: 0.67, blue: 0.56, alpha: 1), mono: true)

    let fixes = [
        "校验本地 Docker 环境",
        "提取并准备执行部署命令",
        "生成回滚与安全检查清单"
    ]
    for (index, fix) in fixes.enumerated() {
        let y = code.minY - 70 - CGFloat(index * 58)
        let actionRect = NSRect(x: right.minX + 36, y: y - 12, width: 420, height: 42)
        drawRoundedRect(actionRect, radius: 14, color: accent())
        drawText(fix, at: NSPoint(x: actionRect.minX + 20, y: actionRect.minY + 12), size: 18, weight: .bold, color: .white)
    }
}

func drawFloatingAgent(in rect: NSRect) {
    drawShadowedRoundedRect(rect, radius: 36, fillColor: NSColor(calibratedRed: 0.97, green: 0.99, blue: 0.98, alpha: 0.92), shadowAlpha: 0.28)
    drawText("TICK", at: NSPoint(x: rect.minX + 34, y: rect.maxY - 58), size: 28, weight: .heavy, color: ink())
    drawPill(text: "proactive", in: NSRect(x: rect.maxX - 168, y: rect.maxY - 67, width: 126, height: 34), fill: NSColor(calibratedRed: 0.82, green: 0.95, blue: 0.91, alpha: 1), text: accent())

    let face = NSRect(x: rect.minX + 34, y: rect.maxY - 182, width: 118, height: 118)
    drawRoundedRect(face, radius: 38, color: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.24, alpha: 1))
    drawCircle(center: NSPoint(x: face.minX + 39, y: face.midY + 18), radius: 9, color: NSColor.white)
    drawCircle(center: NSPoint(x: face.maxX - 39, y: face.midY + 18), radius: 9, color: NSColor.white)
    drawSmile(in: NSRect(x: face.minX + 34, y: face.minY + 34, width: 50, height: 24), color: NSColor.white)

    drawText("不是总结，是下一步", at: NSPoint(x: rect.minX + 180, y: rect.maxY - 104), size: 22, weight: .bold, color: ink())
    drawText("TICK 把当前页面/终端状态变成可确认的 Computer Use 动作。", at: NSPoint(x: rect.minX + 180, y: rect.maxY - 146), size: 18, weight: .regular, color: muted())

    let checklist = [
        "校验本地依赖",
        "准备执行命令",
        "生成补丁草案"
    ]
    for (index, item) in checklist.enumerated() {
        let row = NSRect(x: rect.minX + 42, y: rect.minY + 170 - CGFloat(index * 58), width: rect.width - 84, height: 42)
        drawRoundedRect(row, radius: 15, color: NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.95, alpha: 1))
        drawText(item, at: NSPoint(x: row.minX + 20, y: row.minY + 12), size: 18, weight: .medium, color: ink())
    }
}

func drawTraceWindow(in rect: NSRect) {
    drawShadowedRoundedRect(rect, radius: 34, fillColor: NSColor.white, shadowAlpha: 0.18)
    drawRoundedRect(NSRect(x: rect.minX, y: rect.maxY - 82, width: rect.width, height: 82), radius: 34, color: NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.13, alpha: 1))
    drawText("TICK Trace", at: NSPoint(x: rect.minX + 46, y: rect.maxY - 55), size: 28, weight: .heavy, color: .white)
    drawText("raw HTTP, SSE, tools, token usage", at: NSPoint(x: rect.minX + 220, y: rect.maxY - 51), size: 18, weight: .regular, color: NSColor.white.withAlphaComponent(0.70))

    let sidebar = NSRect(x: rect.minX + 34, y: rect.minY + 36, width: 470, height: rect.height - 142)
    let detail = NSRect(x: sidebar.maxX + 28, y: sidebar.minY, width: rect.width - sidebar.width - 96, height: sidebar.height)
    drawRoundedRect(sidebar, radius: 24, color: NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.97, alpha: 1))
    drawRoundedRect(detail, radius: 24, color: NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.12, alpha: 1))

    drawText("Newest first", at: NSPoint(x: sidebar.minX + 28, y: sidebar.maxY - 48), size: 22, weight: .bold, color: ink())
    let rows = [
        ("terminal.error_diagnostic", "prompt 642 | completion 218"),
        ("tick_skill.load", "skill-recommender matched"),
        ("http.chat.done", "SSE 32 chunks | total 1480"),
        ("risk.operation_detected", "git reset --hard"),
        ("browser.page_idle", "metadata-only")
    ]
    for (index, row) in rows.enumerated() {
        let item = NSRect(x: sidebar.minX + 22, y: sidebar.maxY - 122 - CGFloat(index * 118), width: sidebar.width - 44, height: 90)
        drawRoundedRect(item, radius: 18, color: index == 0 ? NSColor(calibratedRed: 0.83, green: 0.94, blue: 0.91, alpha: 1) : NSColor.white)
        drawText(row.0, at: NSPoint(x: item.minX + 20, y: item.maxY - 34), size: 18, weight: .bold, color: ink())
        drawText(row.1, at: NSPoint(x: item.minX + 20, y: item.minY + 24), size: 15, weight: .regular, color: muted())
    }

    drawText("Raw SSE Request", at: NSPoint(x: detail.minX + 36, y: detail.maxY - 54), size: 26, weight: .heavy, color: .white)
    drawText("Trace ID tick-20260706-201201-B6344C", at: NSPoint(x: detail.minX + 36, y: detail.maxY - 94), size: 16, weight: .regular, color: NSColor.white.withAlphaComponent(0.62), mono: true)

    let codeLines = [
        "POST https://api.example.com/v1/chat/completions",
        "Authorization: Bearer <redacted>",
        "Content-Type: application/json",
        "",
        "data: {\"choices\":[{\"delta\":{\"content\":\"问题判断\"}}]}",
        "data: {\"usage\":{\"prompt_tokens\":642,\"completion_tokens\":218}}",
        "data: [DONE]"
    ]
    for (index, line) in codeLines.enumerated() {
        drawText(line, at: NSPoint(x: detail.minX + 40, y: detail.maxY - 154 - CGFloat(index * 38)), size: 18, weight: .regular, color: index == 0 ? NSColor(calibratedRed: 0.73, green: 0.95, blue: 0.86, alpha: 1) : NSColor.white.withAlphaComponent(0.78), mono: true)
    }

    let statsY = detail.minY + 70
    let stats = [("Prompt", "642"), ("Completion", "218"), ("Total", "860"), ("Words", "311")]
    for (index, stat) in stats.enumerated() {
        let box = NSRect(x: detail.minX + 36 + CGFloat(index * 220), y: statsY, width: 178, height: 92)
        drawRoundedRect(box, radius: 18, color: NSColor.white.withAlphaComponent(0.08))
        drawText(stat.0, at: NSPoint(x: box.minX + 20, y: box.maxY - 34), size: 15, weight: .medium, color: NSColor.white.withAlphaComponent(0.58))
        drawText(stat.1, at: NSPoint(x: box.minX + 20, y: box.minY + 22), size: 30, weight: .heavy, color: NSColor.white)
    }
}

func drawLinearBackdrop(_ rect: NSRect) {
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.13, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 0.91, green: 0.67, blue: 0.46, alpha: 1)
    ])!
    gradient.draw(in: rect, angle: -28)

    for index in 0..<10 {
        let y = rect.minY + CGFloat(index) * rect.height / 10
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: y))
        path.line(to: NSPoint(x: rect.maxX, y: y + 220))
        NSColor.white.withAlphaComponent(0.035).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

func drawCursorTrail(in rect: NSRect) {
    let points = [
        NSPoint(x: rect.maxX - 420, y: rect.maxY - 220),
        NSPoint(x: rect.maxX - 320, y: rect.maxY - 290),
        NSPoint(x: rect.maxX - 245, y: rect.maxY - 390)
    ]
    for (index, point) in points.enumerated() {
        drawCircle(center: point, radius: CGFloat(16 - index * 3), color: NSColor.white.withAlphaComponent(0.18 - CGFloat(index) * 0.04))
    }
}

func drawCanvas(width: Int, height: Int, drawing: (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    drawing(NSRect(x: 0, y: 0, width: width, height: height))
    image.unlockFocus()
    return image
}

func fill(_ rect: NSRect, color: NSColor) {
    color.setFill()
    rect.fill()
}

func drawRoundedRect(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawShadowedRoundedRect(_ rect: NSRect, radius: CGFloat, fillColor: NSColor, shadowAlpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.shadowBlurRadius = 42
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    shadow.set()
    drawRoundedRect(rect, radius: radius, color: fillColor)
    NSGraphicsContext.restoreGraphicsState()
}

func drawCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

func drawSmile(in rect: NSRect, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.midY))
    path.curve(to: NSPoint(x: rect.maxX, y: rect.midY), controlPoint1: NSPoint(x: rect.midX - 10, y: rect.minY), controlPoint2: NSPoint(x: rect.midX + 10, y: rect.minY))
    color.setStroke()
    path.lineWidth = 5
    path.lineCapStyle = .round
    path.stroke()
}

func drawPill(text: String, in rect: NSRect, fill: NSColor, text textColor: NSColor) {
    drawRoundedRect(rect, radius: rect.height / 2, color: fill)
    drawText(text, at: NSPoint(x: rect.minX + 18, y: rect.minY + 8), size: 15, weight: .bold, color: textColor)
}

func drawText(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    NSString(string: text).draw(at: point, withAttributes: attributes)
}

func ink() -> NSColor {
    NSColor(calibratedRed: 0.07, green: 0.12, blue: 0.13, alpha: 1)
}

func muted() -> NSColor {
    NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.43, alpha: 1)
}

func accent() -> NSColor {
    NSColor(calibratedRed: 0.03, green: 0.46, blue: 0.39, alpha: 1)
}

func writeJPEG(_ image: NSImage, quality: CGFloat, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    else {
        throw NSError(domain: "TICKWebAssets", code: 1)
    }
    try data.write(to: url)
}
