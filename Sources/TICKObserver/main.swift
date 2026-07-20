import AppKit
import ApplicationServices
import Carbon
import Foundation

struct ObserverEvent: Codable {
    let type: String
    let confidence: Double
    let title: String
    let detail: String
    let context: [String: String]
    let date: Date
}

final class TICKObserver {
    private let ignoredBundleIDs: Set<String> = [
        "com.jinshaoqian.tick",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.systemsettings",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.accessibility.universalaccessauthwarn"
    ]
    private let encoder = JSONEncoder()
    private var clipboardChangeCount = NSPasteboard.general.changeCount
    private var lastFrontmostBundleID = ""
    private var lastWindowTitle = ""
    private var foregroundChangedAt = Date()
    private var lastActivityAt = Date()
    private var idlePromptSentForWindow = false
    private var lastBrowserPageKey = ""
    private var lastGenericContextKey = ""
    private var lastTerminalContextKey = ""
    private var lastSelectionKey = ""
    private var lastEmissionByType: [String: Date] = [:]
    private var undoPresses: [Date] = []
    private var backspacePresses: [Date] = []
    private var typedBuffer = ""
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init() {
        encoder.dateEncodingStrategy = .iso8601
    }

    func run() {
        setupEventTap()
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.run()
    }

    private func poll() {
        pollClipboard()
        pollForegroundWindow()
        pollSelectionIntent()
        pollIdleFocus()
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else {
            return
        }
        clipboardChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 12 else {
            return
        }

        if let risk = riskOperation(in: text) {
            var context = currentAppContext()
            context["riskKind"] = risk.kind
            context["signature"] = stableKey([risk.kind, risk.line])
            emit(
                type: "risk.operation_detected",
                confidence: 0.94,
                title: "检测到高风险操作",
                detail: risk.detail,
                context: context
            )
            return
        }

        if let diagnostic = diagnosticSummary(from: text, source: "clipboard") {
            var context = currentAppContext()
            context["diagnosticCategory"] = diagnostic.category
            context["diagnosticHeadline"] = diagnostic.headline
            context["signature"] = diagnostic.signature
            emit(
                type: "clipboard.error_diagnostic",
                confidence: 0.95,
                title: "诊断复制的报错",
                detail: diagnostic.detail,
                context: context
            )
            return
        }

        if looksLikeDiagnosticText(text) {
            emitDiagnosticClipboard(text)
        }
    }

    private func pollSelectionIntent() {
        let context = currentAppContext()
        let bundle = context["bundleID"]?.lowercased() ?? ""
        guard !shouldIgnore(bundleID: bundle, appName: context["appName"] ?? "") else {
            return
        }

        guard let selection = selectedTextSnapshot(bundleID: bundle, appName: context["appName"] ?? ""),
              selection.text.count >= 20 else {
            return
        }

        let key = stableKey([bundle, context["windowTitle"] ?? "", selection.text.prefix(240).description])
        guard key != lastSelectionKey else {
            return
        }
        lastSelectionKey = key

        emitSelectionIntent(
            selection: selection,
            baseContext: context,
            trigger: "selection",
            title: "基于选中文本准备行动",
            confidence: 0.88
        )
    }

    private func pollForegroundWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return
        }

        let bundleID = app.bundleIdentifier ?? app.localizedName ?? ""
        let windowTitle = focusedWindowTitle() ?? ""
        if bundleID != lastFrontmostBundleID || windowTitle != lastWindowTitle {
            foregroundChangedAt = Date()
            lastActivityAt = Date()
            idlePromptSentForWindow = false
            lastFrontmostBundleID = bundleID
            lastWindowTitle = windowTitle
            if shouldIgnore(bundleID: bundleID, appName: app.localizedName ?? "") {
                idlePromptSentForWindow = true
                return
            }
            emit(
                type: "foreground.changed",
                confidence: 0.42,
                title: "前台窗口已切换",
                detail: "\(app.localizedName ?? bundleID)\n\(windowTitle)",
                context: currentAppContext()
            )
        }
    }

    private func pollIdleFocus() {
        let idleSeconds = Date().timeIntervalSince(max(foregroundChangedAt, lastActivityAt))
        guard idleSeconds > 3, !idlePromptSentForWindow else {
            return
        }

        let context = currentAppContext()
        let bundle = context["bundleID"]?.lowercased() ?? ""
        if shouldIgnore(bundleID: bundle, appName: context["appName"] ?? "") {
            idlePromptSentForWindow = true
            return
        }

        if isBrowser(bundleID: bundle),
           let metadataPage = browserPageSnapshot(bundleID: bundle, appName: context["appName"] ?? "", includeText: false),
           isTechnicalBrowserPage(title: metadataPage.title, url: metadataPage.url) {
            let page = browserPageSnapshot(bundleID: bundle, appName: context["appName"] ?? "", includeText: true) ?? metadataPage
            let pageKey = stableKey([page.url, page.title, String(page.text.prefix(1200))])
            guard pageKey != lastBrowserPageKey else {
                idlePromptSentForWindow = true
                return
            }
            lastBrowserPageKey = pageKey
            idlePromptSentForWindow = true

            var enrichedContext = context
            enrichedContext["url"] = page.url
            enrichedContext["pageTitle"] = page.title
            enrichedContext["captureMode"] = page.mode
            emit(
                type: "browser.page_idle",
                confidence: 0.88,
                title: "技术页面已停留",
                detail: actionableContextForPage(page),
                context: enrichedContext
            )
            return
        }

        if isTerminal(bundleID: bundle) {
            let snapshot = appContextSnapshot(maxTextLength: 2400)
            let key = snapshotKey(bundleID: bundle, snapshot: snapshot)
            guard key != lastTerminalContextKey else {
                return
            }
            lastTerminalContextKey = key
            var enrichedContext = context
            enrichedContext["captureMode"] = snapshot.mode
            let visibleText = userVisibleSnapshotText(snapshot)
            if let risk = riskOperation(in: visibleText) {
                enrichedContext["riskKind"] = risk.kind
                enrichedContext["signature"] = stableKey([risk.kind, risk.line])
                idlePromptSentForWindow = true
                emit(
                    type: "risk.operation_detected",
                    confidence: 0.94,
                    title: "检测到终端高风险操作",
                    detail: risk.detail,
                    context: enrichedContext
                )
                return
            }

            if let diagnostic = diagnosticSummary(from: visibleText, source: "terminal") {
                enrichedContext["diagnosticCategory"] = diagnostic.category
                enrichedContext["diagnosticHeadline"] = diagnostic.headline
                enrichedContext["signature"] = diagnostic.signature
                idlePromptSentForWindow = true
                emit(
                    type: "terminal.error_diagnostic",
                    confidence: 0.95,
                    title: "诊断终端报错",
                    detail: diagnostic.detail,
                    context: enrichedContext
                )
                return
            }

            guard terminalContextLooksActionable(visibleText) else {
                idlePromptSentForWindow = true
                return
            }

            idlePromptSentForWindow = true
            emitContextSnapshot(
                type: "terminal.context_idle",
                confidence: 0.88,
                title: "准备推进终端下一步",
                snapshot: snapshot,
                context: enrichedContext
            )
            return
        }

        let snapshot = appContextSnapshot(maxTextLength: 1800)
        guard let confidence = genericContextConfidence(snapshot: snapshot, bundleID: bundle, isBrowserFallback: false) else {
            idlePromptSentForWindow = true
            return
        }
        let key = snapshotKey(bundleID: bundle, snapshot: snapshot)
        guard key != lastGenericContextKey else {
            idlePromptSentForWindow = true
            return
        }
        lastGenericContextKey = key
        var enrichedContext = context
        enrichedContext["captureMode"] = snapshot.mode
        let visibleText = userVisibleSnapshotText(snapshot)
        if let risk = riskOperation(in: visibleText) {
            enrichedContext["riskKind"] = risk.kind
            enrichedContext["signature"] = stableKey([risk.kind, risk.line])
            idlePromptSentForWindow = true
            emit(
                type: "risk.operation_detected",
                confidence: 0.92,
                title: "检测到高风险操作",
                detail: risk.detail,
                context: enrichedContext
            )
            return
        }

        if let diagnostic = diagnosticSummary(from: visibleText, source: "app") {
            enrichedContext["diagnosticCategory"] = diagnostic.category
            enrichedContext["diagnosticHeadline"] = diagnostic.headline
            enrichedContext["signature"] = diagnostic.signature
            idlePromptSentForWindow = true
            emit(
                type: "app.error_diagnostic",
                confidence: 0.91,
                title: "诊断当前窗口错误",
                detail: diagnostic.detail,
                context: enrichedContext
            )
            return
        }

        idlePromptSentForWindow = true
        emitContextSnapshot(
            type: "app.context_idle",
            confidence: confidence,
            title: "准备推进当前窗口任务",
            snapshot: snapshot,
            context: enrichedContext
        )
    }

    private func emitContextSnapshot(type: String, confidence: Double, title: String, snapshot: AppSnapshot, context: [String: String]) {
        let visibleText = userVisibleSnapshotText(snapshot)
        guard visibleText.count >= 80 else {
            emit(
                type: "context.silent",
                confidence: 0.35,
                title: "上下文已忽略",
                detail: "\(context["appName"] ?? "前台应用") 暂无有价值的可读文本。",
                context: context
            )
            return
        }

        emit(
            type: type,
            confidence: confidence,
            title: title,
            detail: visibleText,
            context: context
        )
    }

    private func userVisibleSnapshotText(_ snapshot: AppSnapshot) -> String {
        var sections: [String] = []
        if !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Window title:\n\(snapshot.title)")
        }
        if !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(snapshot.text)
        }
        return compactText(sections.joined(separator: "\n\n"), maxLength: 2600)
    }

    private func shouldIgnore(bundleID: String, appName: String) -> Bool {
        let normalizedBundleID = bundleID.lowercased()
        if ignoredBundleIDs.contains(normalizedBundleID) {
            return true
        }

        let normalizedName = appName.lowercased()
        return normalizedName == "tick" || normalizedName == "tickobserver"
    }

    private func isBrowser(bundleID: String) -> Bool {
        bundleID.contains("chrome") ||
            bundleID.contains("safari") ||
            bundleID.contains("edge") ||
            bundleID.contains("arc")
    }

    private func isTerminal(bundleID: String) -> Bool {
        bundleID.contains("terminal") ||
            bundleID.contains("iterm") ||
            bundleID.contains("warp") ||
            bundleID.contains("wezterm") ||
            bundleID.contains("alacritty")
    }

    private func genericContextConfidence(snapshot: AppSnapshot, bundleID: String, isBrowserFallback: Bool) -> Double? {
        let text = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        guard text.count >= 120 else {
            return nil
        }

        let contentSignals = [
            "error", "exception", "failed", "traceback", "warning", "todo", "fix", "api",
            "http", "json", "swift", "python", "javascript", "typescript", "sql", "markdown",
            "class ", "func ", "def ", "import ", "curl ", "git ", "npm ", "pnpm ",
            "需求", "错误", "异常", "失败", "文档", "接口", "代码", "日志", "行动", "问题"
        ]
        let hasContentSignal = contentSignals.contains { lower.contains($0) }
        let appLooksUseful = bundleID.contains("xcode") ||
            bundleID.contains("vscode") ||
            bundleID.contains("cursor") ||
            bundleID.contains("notes") ||
            bundleID.contains("preview") ||
            bundleID.contains("mail") ||
            bundleID.contains("slack") ||
            bundleID.contains("wechat") ||
            bundleID.contains("feishu") ||
            bundleID.contains("lark")

        if hasContentSignal && appLooksUseful {
            return 0.84
        }

        if appLooksUseful && text.count >= 220 && hasContentSignal {
            return 0.8
        }

        return nil
    }

    private func isTechnicalBrowserPage(title: String, url: String) -> Bool {
        let lower = "\(title)\n\(url)".lowercased()
        let signals = [
            "stackoverflow.com",
            "stack overflow",
            "github.com",
            "/issues",
            "docs.",
            "documentation",
            "developer.apple.com/documentation",
            "readthedocs",
            "api reference",
            "mdn",
            "bug",
            "manual",
            "tutorial"
        ]
        return signals.contains { lower.contains($0) }
    }

    private func terminalContextLooksActionable(_ text: String) -> Bool {
        let lower = text.lowercased()
        if commandLines(in: text.components(separatedBy: .newlines)).count > 0 {
            return true
        }

        let signals = [
            "error", "exception", "failed", "traceback", "warning", "panic",
            "build", "test", "install", "compile", "exit code", "exit status",
            "no such file or directory", "permission denied", "command not found",
            "failed with", "xcodebuild", "swiftc", "npm ", "pnpm ", "yarn ",
            "python ", "git ", "docker ", "kubectl "
        ]
        return signals.contains { lower.contains($0) }
    }

    private func looksLikeDiagnosticText(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "error", "exception", "failed", "traceback", "panic", "fatal",
            "stack trace", "assertion", "warn", "warning", "exception", "崩溃",
            "异常", "失败", "报错", "错误"
        ]
        return signals.contains { lower.contains($0) }
    }

    private func emitDiagnosticClipboard(_ text: String) {
        var context = currentAppContext()
        if let diagnostic = diagnosticSummary(from: text, source: "clipboard") {
            context["diagnosticCategory"] = diagnostic.category
            context["diagnosticHeadline"] = diagnostic.headline
            context["signature"] = diagnostic.signature
            emit(
                type: "clipboard.error_diagnostic",
                confidence: 0.93,
                title: "诊断复制的报错",
                detail: diagnostic.detail,
                context: context
            )
            return
        }

        let lines = compactText(text, maxLength: 1800)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let headline = String((lines.first ?? text).prefix(220))
        context["diagnosticCategory"] = "General Error"
        context["diagnosticHeadline"] = headline
        context["signature"] = stableKey(["clipboard", headline, String(text.prefix(260))])
        emit(
            type: "clipboard.error_diagnostic",
            confidence: 0.9,
            title: "诊断复制的报错",
            detail: """
            来源: clipboard

            错误类型: General Error

            关键错误行:
            \(headline)

            上下文片段:
            \(compactText(text, maxLength: 1600))
            """,
            context: context
        )
    }

    private struct AppSnapshot {
        let title: String
        let text: String
        let mode: String
    }

    private struct DiagnosticSummary {
        let category: String
        let headline: String
        let detail: String
        let signature: String
    }

    private struct RiskOperation {
        let kind: String
        let line: String
        let detail: String
    }

    private struct SelectionSnapshot {
        let text: String
        let page: BrowserPage?
        let mode: String
    }

    private func selectedTextSnapshot(bundleID: String, appName: String) -> SelectionSnapshot? {
        if isBrowser(bundleID: bundleID) {
            guard let selectedText = browserSelectedText(bundleID: bundleID, appName: appName),
                  selectedText.count >= 20 else {
                return nil
            }

            return SelectionSnapshot(
                text: selectedText,
                page: browserPageSnapshot(bundleID: bundleID, appName: appName, includeText: true),
                mode: "browser-selection"
            )
        }

        guard let selectedText = accessibilitySelectedText(),
              selectedText.count >= 20 else {
            return nil
        }
        return SelectionSnapshot(text: selectedText, page: nil, mode: "accessibility-selection")
    }

    private func accessibilitySelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedElement = focusedValue else {
            return nil
        }

        var selectedTextValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
              let selectedText = selectedTextValue as? String else {
            return nil
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : compactText(trimmed, maxLength: 2200)
    }

    private func appContextSnapshot(maxTextLength: Int) -> AppSnapshot {
        let title = focusedWindowTitle() ?? ""
        let uiText = focusedWindowText(maxLength: maxTextLength)
        if uiText.count > 60 {
            return AppSnapshot(title: title, text: uiText, mode: "accessibility-text")
        }

        let text = [
            title.isEmpty ? nil : "Window title: \(title)",
            uiText.isEmpty ? nil : "Visible UI text:\n\(uiText)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
        return AppSnapshot(title: title, text: text, mode: "metadata")
    }

    private func snapshotKey(bundleID: String, snapshot: AppSnapshot) -> String {
        stableKey([
            bundleID,
            snapshot.title,
            snapshot.text
        ])
    }

    private func focusedWindowText(maxLength: Int) -> String {
        guard let window = focusedWindowElement() else {
            return ""
        }
        var texts: [String] = []
        collectText(from: window, into: &texts, maxLength: maxLength, depth: 0)
        return compactText(texts.joined(separator: "\n"), maxLength: maxLength)
    }

    private func collectText(from element: AXUIElement, into texts: inout [String], maxLength: Int, depth: Int) {
        guard depth < 5, texts.joined(separator: "\n").count < maxLength else {
            return
        }

        for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(text)
            }
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return
        }

        for child in children.prefix(80) {
            collectText(from: child, into: &texts, maxLength: maxLength, depth: depth + 1)
        }
    }

    private func compactText(_ text: String, maxLength: Int) -> String {
        var seen = Set<String>()
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                if seen.contains(line) {
                    return false
                }
                seen.insert(line)
                return true
            }
        return String(lines.joined(separator: "\n").prefix(maxLength))
    }

    private func diagnosticSummary(from rawText: String, source: String) -> DiagnosticSummary? {
        let text = compactText(rawText, maxLength: 3200)
        guard text.count >= 20 else {
            return nil
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return nil
        }

        var bestIndex = 0
        var bestScore = 0
        for (index, line) in lines.enumerated() {
            let score = diagnosticLineScore(line)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        let fullScore = diagnosticLineScore(text)
        guard bestScore >= 4 || fullScore >= 8 else {
            return nil
        }

        let headline = String(lines[bestIndex].prefix(260))
        let category = diagnosticCategory(for: text)
        let nearby = contextAround(lines: lines, index: bestIndex, radius: 4, maxLength: 1600)
        let commands = commandLines(in: lines).prefix(4).joined(separator: "\n")
        let files = fileReferences(in: text).prefix(6).joined(separator: "\n")
        let exitCodes = matches(
            in: text,
            pattern: #"(?i)(exit status|exit code|exited with code|status=)\s*[:=]?\s*(-?\d+)"#
        )
        .prefix(3)
        .joined(separator: "\n")

        var sections = [
            "来源: \(source)",
            "错误类型: \(category)",
            "关键错误行:\n\(headline)"
        ]
        if !commands.isEmpty {
            sections.append("相关命令:\n\(commands)")
        }
        if !files.isEmpty {
            sections.append("相关文件/位置:\n\(files)")
        }
        if !exitCodes.isEmpty {
            sections.append("退出码:\n\(exitCodes)")
        }
        sections.append("上下文片段:\n\(nearby)")

        return DiagnosticSummary(
            category: category,
            headline: headline,
            detail: sections.joined(separator: "\n\n"),
            signature: stableKey([category, headline, files, exitCodes])
        )
    }

    private func diagnosticLineScore(_ text: String) -> Int {
        let lower = text.lowercased()
        var score = 0

        let strongSignals = [
            "traceback", "uncaught exception", "segmentation fault", "fatal error",
            "panic:", "npm err!", "build failed", "tests failed", "test failed",
            "assertionerror", "syntaxerror", "typeerror", "valueerror",
            "referenceerror", "runtimeerror", "modulenotfounderror",
            "cannot find module", "command not found", "permission denied",
            "no such file or directory", "address already in use",
            "xcodebuild: error", "swiftc failed", "compilation failed",
            "failed to fetch", "failed to compile", "failed with exit code",
            "exit code", "exit status", "错误", "异常", "构建失败", "编译失败", "测试失败", "找不到"
        ]
        for signal in strongSignals where lower.contains(signal) {
            score += 5
        }

        if matchesAny(text, patterns: [
            #"(?i)\berror\s*[:=]"#,
            #"(?i)\b[a-z_]*error\b"#,
            #"(?i)\b[a-z_]*exception\b"#,
            #"(?i)\bfailed\b"#,
            #"(?i)\b4\d\d\b|\b5\d\d\b"#,
            #"\b[A-Za-z0-9_./~+\-]+?\.(swift|py|js|ts|tsx|jsx|java|go|rs|c|cpp|m|mm|h):\d+"#
        ]) {
            score += 4
        }

        if lower.contains("warning") || lower.contains("warn") || lower.contains("告警") || lower.contains("警告") {
            score += 1
        }

        if lower.contains("error handling") || lower.contains("error boundary") || lower.contains("错误处理") {
            score -= 3
        }

        return max(score, 0)
    }

    private func diagnosticCategory(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("traceback") ||
            lower.contains("modulenotfounderror") ||
            lower.contains("syntaxerror") ||
            lower.contains("pytest") {
            return "Python"
        }
        if lower.contains("npm err") ||
            lower.contains("pnpm") ||
            lower.contains("yarn") ||
            lower.contains("cannot find module") ||
            lower.contains("typeerror") ||
            lower.contains("referenceerror") {
            return "Node/JavaScript"
        }
        if lower.contains("swiftc") ||
            lower.contains("xcodebuild") ||
            lower.contains(".swift:") ||
            lower.contains("package.swift") {
            return "Swift/Xcode"
        }
        if lower.contains("http") ||
            lower.contains("status code") ||
            matchesAny(text, patterns: [#"\b4\d\d\b|\b5\d\d\b"#]) {
            return "HTTP/API"
        }
        if lower.contains("sql") ||
            lower.contains("database") ||
            lower.contains("syntax error at or near") {
            return "SQL/Database"
        }
        if lower.contains("git ") ||
            lower.contains("fatal:") {
            return "Git"
        }
        if lower.contains("build failed") ||
            lower.contains("compilation failed") ||
            lower.contains("编译失败") ||
            lower.contains("构建失败") {
            return "Build/Test"
        }
        return "General Error"
    }

    private func contextAround(lines: [String], index: Int, radius: Int, maxLength: Int) -> String {
        let start = max(0, index - radius)
        let end = min(lines.count - 1, index + radius)
        return String(lines[start...end].joined(separator: "\n").prefix(maxLength))
    }

    private func commandLines(in lines: [String]) -> [String] {
        let commandPrefixes = ["$", "%", ">", "❯"]
        let commandWords = [
            "swift ", "xcodebuild", "npm ", "pnpm ", "yarn ", "node ", "python", "pytest",
            "pip ", "git ", "go test", "cargo ", "mvn ", "gradle", "curl ", "docker ", "kubectl "
        ]
        return lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            return commandPrefixes.contains(where: { trimmed.hasPrefix($0) }) ||
                commandWords.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0)") })
        }
    }

    private func actionableContextForPage(_ page: BrowserPage) -> String {
        let lines = page.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let commands = commandLines(in: lines).prefix(8).joined(separator: "\n")
        let files = fileReferences(in: page.text).prefix(6).joined(separator: "\n")
        let links = matches(in: page.text, pattern: #"https?://[^\s\]\)>"']+"#)
            .prefix(6)
            .joined(separator: "\n")

        var sections = [
            "Page title:\n\(page.title)",
            "URL:\n\(page.url)",
            "Capture mode:\n\(page.mode)"
        ]
        if !commands.isEmpty {
            sections.append("Extracted commands:\n\(commands)")
        }
        if !files.isEmpty {
            sections.append("Referenced files:\n\(files)")
        }
        if !links.isEmpty {
            sections.append("Referenced links:\n\(links)")
        }
        sections.append("Visible page context:\n\(compactText(page.text, maxLength: page.mode == "page-text" ? 3000 : 800))")
        return sections.joined(separator: "\n\n")
    }

    private func emitSelectionIntent(selection: SelectionSnapshot, baseContext: [String: String], trigger: String, title: String, confidence: Double) {
        var context = baseContext
        context["trigger"] = trigger
        context["selectionMode"] = selection.mode
        context["signature"] = stableKey([trigger, selection.text.prefix(260).description])

        var sections = [
            "Trigger:\n\(trigger)",
            "Selected or copied text:\n\(compactText(selection.text, maxLength: 1800))"
        ]

        if let page = selection.page {
            context["url"] = page.url
            context["pageTitle"] = page.title
            context["captureMode"] = page.mode
            sections.append("Page action context:\n\(actionableContextForPage(page))")
        }

        if let diagnostic = diagnosticSummary(from: selection.text, source: trigger) {
            context["diagnosticCategory"] = diagnostic.category
            context["diagnosticHeadline"] = diagnostic.headline
            context["signature"] = diagnostic.signature
            emit(
                type: "selection.error_diagnostic",
                confidence: max(confidence, 0.94),
                title: "诊断选中或复制的错误",
                detail: "\(diagnostic.detail)\n\n\(sections.joined(separator: "\n\n"))",
                context: context
            )
            return
        }

        emit(
            type: "selection.intent",
            confidence: confidence,
            title: title,
            detail: sections.joined(separator: "\n\n"),
            context: context
        )
    }

    private func fileReferences(in text: String) -> [String] {
        unique(matches(in: text, pattern: #"(?:/|~|\./|../)?[A-Za-z0-9_@+.,\- /]+?\.(swift|py|js|ts|tsx|jsx|java|go|rs|rb|php|m|mm|c|cc|cpp|h|hpp|sql|yaml|yml|json|md):\d+(?::\d+)?"#))
    }

    private func riskOperation(in rawText: String) -> RiskOperation? {
        let lines = compactText(rawText, maxLength: 1200)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() {
            let normalized = line
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = normalized.lowercased()

            let checks: [(String, Bool, String)] = [
                ("删除大量文件", matchesAny(lower, patterns: [#"(^|\s)sudo\s+rm\s+-[a-z]*r[a-z]*f"#, #"(^|\s)rm\s+-[a-z]*r[a-z]*f\s+(/|~|\*|\.|\.\.)"#]), "可能递归强制删除系统目录、项目目录或大量文件。"),
                ("Git 破坏性回退", lower.contains("git reset --hard") || lower.contains("git clean -fd"), "可能丢失未提交代码或未跟踪文件。"),
                ("数据库破坏性语句", lower.contains("drop database") || lower.contains("drop table") || lower.contains("truncate table"), "可能直接删除数据库、表或全部数据。"),
                ("SQL 批量删除", lower.contains("delete from") && !lower.contains(" where "), "DELETE 缺少 WHERE，可能删除整张表。"),
                ("Kubernetes 删除资源", lower.contains("kubectl delete") || lower.contains("helm uninstall"), "可能删除线上工作负载或集群资源。"),
                ("基础设施销毁", lower.contains("terraform destroy") || lower.contains("pulumi destroy"), "可能销毁云资源或生产环境基础设施。"),
                ("磁盘擦除/格式化", lower.contains("diskutil erase") || lower.contains("mkfs") || lower.contains("dd if="), "可能擦除磁盘、分区或覆盖设备数据。"),
                ("过宽权限修改", lower.contains("chmod -r 777") || lower.contains("chmod -R 777".lowercased()), "可能把大量文件改成全员可写，带来安全风险。"),
                ("递归属主修改", lower.contains("chown -r") || lower.contains("chown -R".lowercased()), "可能递归改坏系统或项目文件属主。"),
                ("容器/云存储批量清理", lower.contains("docker system prune") || lower.contains("docker volume rm") || lower.contains("aws s3 rm") && lower.contains("--recursive") || lower.contains("gsutil rm -r"), "可能批量删除镜像、卷或远端对象。")
            ]

            if let matched = checks.first(where: { $0.1 }) {
                return RiskOperation(
                    kind: matched.0,
                    line: normalized,
                    detail: """
                    操作:
                    \(normalized)

                    风险:
                    \(matched.2)
                    """
                )
            }
        }

        return nil
    }

    private func matchesAny(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            if seen.contains(value) {
                return false
            }
            seen.insert(value)
            return true
        }
    }

    private func stableKey(_ values: [String]) -> String {
        values.joined(separator: "|")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct BrowserPage {
        let title: String
        let url: String
        let text: String
        let mode: String
    }

    private func browserPageSnapshot(bundleID: String, appName: String, includeText: Bool) -> BrowserPage? {
        if bundleID.contains("chrome") || bundleID.contains("edge") || bundleID.contains("arc") {
            return chromiumPageSnapshot(applicationName: chromiumApplicationName(bundleID: bundleID, appName: appName), includeText: includeText)
        }
        if bundleID.contains("safari") {
            return safariPageSnapshot(includeText: includeText)
        }
        return nil
    }

    private func chromiumApplicationName(bundleID: String, appName: String) -> String {
        if bundleID.contains("edgemac") || bundleID.contains("edge") {
            return "Microsoft Edge"
        }
        if bundleID.contains("arc") {
            return "Arc"
        }
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Google Chrome" : trimmedName
    }

    private func chromiumPageSnapshot(applicationName: String, includeText: Bool) -> BrowserPage? {
        let escapedApplicationName = escapedAppleScriptString(applicationName)
        let metadataScript = """
        tell application "\(escapedApplicationName)"
          if not (exists front window) then return ""
          set pageTitle to title of active tab of front window
          set pageURL to URL of active tab of front window
          return pageTitle & "\nTICK_URL_SEPARATOR\n" & pageURL
        end tell
        """
        guard let metadata = parseBrowserMetadata(runAppleScript(metadataScript, label: "\(applicationName).metadata")) else {
            return nil
        }

        guard includeText else {
            return BrowserPage(
                title: metadata.title,
                url: metadata.url,
                text: "Page title: \(metadata.title)\nURL: \(metadata.url)",
                mode: "metadata-only"
            )
        }

        let textScript = """
        tell application "\(escapedApplicationName)"
          if not (exists front window) then return ""
          set pageText to execute active tab of front window javascript "document.body ? document.body.innerText : ''"
          return pageText
        end tell
        """
        let text = normalizedBrowserText(runAppleScript(textScript, label: "\(applicationName).text"))
        return BrowserPage(
            title: metadata.title,
            url: metadata.url,
            text: text.isEmpty ? "Page title: \(metadata.title)\nURL: \(metadata.url)" : text,
            mode: text.count > 80 ? "page-text" : "metadata-only"
        )
    }

    private func chromiumSelectedText(applicationName: String) -> String? {
        let escapedApplicationName = escapedAppleScriptString(applicationName)
        let script = """
        tell application "\(escapedApplicationName)"
          if not (exists front window) then return ""
          set selectedText to execute active tab of front window javascript "window.getSelection ? window.getSelection().toString() : ''"
          return selectedText
        end tell
        """
        let text = normalizedBrowserText(runAppleScript(script, label: "\(applicationName).selection", emitErrors: false))
        return text.isEmpty ? nil : text
    }

    private func escapedAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func safariPageSnapshot(includeText: Bool) -> BrowserPage? {
        let metadataScript = """
        tell application "Safari"
          if not (exists front document) then return ""
          set pageTitle to name of front document
          set pageURL to URL of front document
          return pageTitle & "\nTICK_URL_SEPARATOR\n" & pageURL
        end tell
        """
        guard let metadata = parseBrowserMetadata(runAppleScript(metadataScript, label: "Safari.metadata")) else {
            return nil
        }

        guard includeText else {
            return BrowserPage(
                title: metadata.title,
                url: metadata.url,
                text: "Page title: \(metadata.title)\nURL: \(metadata.url)",
                mode: "metadata-only"
            )
        }

        let textScript = """
        tell application "Safari"
          if not (exists front document) then return ""
          set pageText to do JavaScript "document.body ? document.body.innerText : ''" in front document
          return pageText
        end tell
        """
        let text = normalizedBrowserText(runAppleScript(textScript, label: "Safari.text"))
        return BrowserPage(
            title: metadata.title,
            url: metadata.url,
            text: text.isEmpty ? "Page title: \(metadata.title)\nURL: \(metadata.url)" : text,
            mode: text.count > 80 ? "page-text" : "metadata-only"
        )
    }

    private func safariSelectedText() -> String? {
        let script = """
        tell application "Safari"
          if not (exists front document) then return ""
          set selectedText to do JavaScript "window.getSelection ? window.getSelection().toString() : ''" in front document
          return selectedText
        end tell
        """
        let text = normalizedBrowserText(runAppleScript(script, label: "Safari.selection", emitErrors: false))
        return text.isEmpty ? nil : text
    }

    private func browserSelectedText(bundleID: String, appName: String) -> String? {
        if bundleID.contains("chrome") || bundleID.contains("edge") || bundleID.contains("arc") {
            return chromiumSelectedText(applicationName: chromiumApplicationName(bundleID: bundleID, appName: appName))
        }
        if bundleID.contains("safari") {
            return safariSelectedText()
        }
        return nil
    }

    private func runAppleScript(_ source: String, label: String, emitErrors: Bool = true) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return nil
        }
        let output = script.executeAndReturnError(&error)
        if let error {
            guard emitErrors else {
                return nil
            }
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            emit(
                type: "browser.applescript_error",
                confidence: 0.35,
                title: "浏览器 AppleScript 错误",
                detail: "\(label): \(message)",
                context: currentAppContext()
            )
            return nil
        }
        return output.stringValue
    }

    private func parseBrowserMetadata(_ raw: String?) -> (title: String, url: String)? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        let urlParts = raw.components(separatedBy: "\nTICK_URL_SEPARATOR\n")
        guard urlParts.count == 2 else {
            return nil
        }

        let title = urlParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !url.isEmpty else {
            return nil
        }
        return (title, url)
    }

    private func normalizedBrowserText(_ raw: String?) -> String {
        (raw ?? "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(4200)
            .description
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard type == .keyDown,
                      let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let observer = Unmanaged<TICKObserver>.fromOpaque(refcon).takeUnretainedValue()
                observer.handleKeyDown(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            emit(
                type: "observer.permission",
                confidence: 0.95,
                title: "需要输入监听权限",
                detail: "TICKObserver 无法创建全局键盘监听。请为 TICK 开启辅助功能/Input Monitoring 权限，才能检测撤销、删除和 ghost trigger。",
                context: currentAppContext()
            )
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKeyDown(_ event: CGEvent) {
        lastActivityAt = Date()
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if keyCode == kVK_ANSI_C && flags.contains(.maskCommand) {
            let context = currentAppContext()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.handleCopyCommand(baseContext: context)
            }
            return
        }

        if keyCode == kVK_ANSI_Z && flags.contains(.maskCommand) {
            recordBurst(&undoPresses, windowSeconds: 3)
            if undoPresses.count >= 3 {
                emit(
                    type: "editing.undo_burst",
                    confidence: 0.86,
                    title: "检测到连续撤销",
                    detail: "3 秒内按下了 \(undoPresses.count) 次 Command+Z。",
                    context: currentAppContext()
                )
                undoPresses.removeAll()
            }
            return
        }

        if keyCode == kVK_Delete {
            if !typedBuffer.isEmpty {
                typedBuffer.removeLast()
            }
            recordBurst(&backspacePresses, windowSeconds: 3)
            if backspacePresses.count >= 8 {
                emit(
                    type: "editing.delete_burst",
                    confidence: 0.78,
                    title: "检测到连续删除",
                    detail: "3 秒内连续按下了 Backspace/Delete。",
                    context: currentAppContext()
                )
                backspacePresses.removeAll()
            }
            return
        }

        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            let trimmed = typedBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let risk = riskOperation(in: trimmed) {
                var context = currentAppContext()
                context["riskKind"] = risk.kind
                context["signature"] = stableKey([risk.kind, risk.line])
                emit(
                    type: "risk.operation_detected",
                    confidence: 0.96,
                    title: "准备执行高风险操作",
                    detail: risk.detail,
                    context: context
                )
            }
            typedBuffer.removeAll()
            return
        }

        guard let characters = event.unicodeString, !characters.isEmpty else {
            return
        }

        typedBuffer += characters
        if typedBuffer.count > 160 {
            typedBuffer = String(typedBuffer.suffix(160))
        }

        let trimmed = typedBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let risk = riskOperation(in: trimmed) {
            var context = currentAppContext()
            context["riskKind"] = risk.kind
            context["signature"] = stableKey([risk.kind, risk.line])
            emit(
                type: "risk.operation_detected",
                confidence: 0.9,
                title: "检测到高风险输入",
                detail: risk.detail,
                context: context
            )
        }

        if trimmed.hasSuffix("??") ||
            trimmed.lowercased().contains("// todo:") ||
            trimmed.lowercased().contains("# fix:") {
            emit(
                type: "ghost.trigger",
                confidence: 0.84,
                title: "检测到 ghost trigger 文本",
                detail: trimmed,
                context: currentAppContext()
            )
            typedBuffer.removeAll()
        }
    }

    private func handleCopyCommand(baseContext: [String: String]) {
        let pasteboard = NSPasteboard.general
        clipboardChangeCount = pasteboard.changeCount

        let bundle = baseContext["bundleID"]?.lowercased() ?? ""
        let appName = baseContext["appName"] ?? ""
        guard !shouldIgnore(bundleID: bundle, appName: appName) else {
            return
        }

        let copiedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let selection = selectedTextSnapshot(bundleID: bundle, appName: appName)
        let text = (selection?.text.count ?? 0) >= 20 ? selection?.text : copiedText
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 20 else {
            return
        }

        let page = selection?.page ?? (isBrowser(bundleID: bundle) ? browserPageSnapshot(bundleID: bundle, appName: appName, includeText: true) : nil)
        let mode = selection?.mode ?? (page == nil ? "clipboard-copy" : "browser-copy")
        let snapshot = SelectionSnapshot(text: text, page: page, mode: mode)
        let key = stableKey([bundle, baseContext["windowTitle"] ?? "", "copy", String(text.prefix(240))])
        guard key != lastSelectionKey else {
            return
        }
        lastSelectionKey = key

        emitSelectionIntent(
            selection: snapshot,
            baseContext: baseContext,
            trigger: "copy",
            title: "基于复制内容准备行动",
            confidence: 0.91
        )
    }

    private func recordBurst(_ values: inout [Date], windowSeconds: TimeInterval) {
        let now = Date()
        values.append(now)
        values = values.filter { now.timeIntervalSince($0) <= windowSeconds }
    }

    private func emit(type: String, confidence: Double, title: String, detail: String, context: [String: String]) {
        let now = Date()
        let minimumInterval = minimumIntervalForEvent(type)
        if let last = lastEmissionByType[type], now.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastEmissionByType[type] = now

        let event = ObserverEvent(
            type: type,
            confidence: confidence,
            title: title,
            detail: detail,
            context: context,
            date: Date()
        )
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        if let output = "\(line)\n".data(using: .utf8) {
            FileHandle.standardOutput.write(output)
        }
    }

    private func currentAppContext() -> [String: String] {
        let app = NSWorkspace.shared.frontmostApplication
        return [
            "appName": app?.localizedName ?? "",
            "bundleID": app?.bundleIdentifier ?? "",
            "windowTitle": focusedWindowTitle() ?? ""
        ]
    }

    private func minimumIntervalForEvent(_ type: String) -> TimeInterval {
        switch type {
        case "browser.page_idle":
            return 20
        case "terminal.context_idle":
            return 12
        case "app.context_idle":
            return 30
        case "clipboard.signal":
            return 8
        case "selection.intent", "selection.error_diagnostic":
            return 6
        case "editing.undo_burst", "editing.delete_burst", "ghost.trigger":
            return 8
        default:
            return 3
        }
    }

    private func focusedWindowTitle() -> String? {
        guard let focusedWindow = focusedWindowElement() else {
            return nil
        }

        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }

        return titleValue as? String
    }

    private func focusedWindowElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppValue) == .success,
              let focusedApp = focusedAppValue else {
            return nil
        }

        var focusedWindowValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindow = focusedWindowValue else {
            return nil
        }
        return (focusedWindow as! AXUIElement)
    }
}

private extension CGEvent {
    var unicodeString: String? {
        var length = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return nil
        }
        var chars = [UniChar](repeating: 0, count: length)
        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }
}

TICKObserver().run()
