import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class TICKAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: FloatingAgentController?
    private var settingsStore: LLMSettingsStore?
    private var toolStore: AgentToolConfigurationStore?
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?
    private var toolSettingsWindowController: NSWindowController?
    private var traceWindowController: NSWindowController?
    private var activityObserver: ActivityObserverBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let settingsStore = LLMSettingsStore()
        let toolStore = AgentToolConfigurationStore()
        let controller = FloatingAgentController(settingsStore: settingsStore, toolStore: toolStore)
        settingsStore.onSave = { [weak controller] in
            controller?.refreshConfigurationStatus()
        }
        self.settingsStore = settingsStore
        self.toolStore = toolStore
        self.controller = controller
        let activityObserver = ActivityObserverBridge(controller: controller)
        self.activityObserver = activityObserver
        controller.show()
        showModelSettings()
        TraceStore.shared.log("app.launch", "TICK launched")
        settingsStore.loadModels()
        activityObserver.start()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "face.smiling.inverse", accessibilityDescription: "TICK")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = makeStatusMenu()
        self.statusItem = statusItem
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show TICK", action: #selector(showTick), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Model Settings...", action: #selector(showModelSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Tools Settings...", action: #selector(showToolsSettings), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Trace Logs...", action: #selector(showTraceLogs), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TICK", action: #selector(quit), keyEquivalent: "q"))
        return menu
    }

    @MainActor
    @objc private func showTick() {
        controller?.show()
    }

    @MainActor
    @objc private func showModelSettings() {
        guard let settingsStore else {
            return
        }

        if let settingsWindowController {
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ModelSettingsView(
            store: settingsStore,
            close: { [weak self] in
                self?.settingsWindowController?.window?.orderOut(nil)
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TICK Model Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 460, height: 280))
        window.center()

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func showToolsSettings() {
        guard let toolStore else {
            return
        }
        toolStore.refresh()

        if let toolSettingsWindowController {
            toolSettingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = ToolsSettingsView(
            store: toolStore,
            close: { [weak self] in
                self?.toolSettingsWindowController?.window?.orderOut(nil)
            }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TICK Tools Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 660))
        window.center()

        let controller = NSWindowController(window: window)
        toolSettingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func showTraceLogs() {
        if let traceWindowController {
            traceWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: TraceLogView(store: TraceStore.shared))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "TICK Trace Logs"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 600))
        window.center()

        let controller = NSWindowController(window: window)
        traceWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc private func quit() {
        traceLog("app.quit", "TICK quit")
        activityObserver?.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            activityObserver?.stop()
        }
    }
}

@main
struct TICKApp: App {
    @NSApplicationDelegateAdaptor(TICKAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class FloatingAgentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum FloatingAgentLayout {
    static let panelSize = NSSize(width: 484, height: 334)
    static let panelPadding: CGFloat = 10
    static let faceSize: CGFloat = 74
    static let bubbleWidth: CGFloat = 374
    static let bubbleHeight: CGFloat = 304
}

final class FloatingAgentHostingView: NSHostingView<FloatingAgentView> {
    private weak var controller: FloatingAgentController?
    private var isDraggingFace = false
    private var dragDidMove = false
    private var dragStartMouseLocation = NSPoint.zero
    private var dragStartWindowOrigin = NSPoint.zero

    init(rootView: FloatingAgentView, controller: FloatingAgentController) {
        self.controller = controller
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init(rootView: FloatingAgentView) {
        fatalError("Use init(rootView:controller:) instead.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(rootView:controller:) instead.")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, robotFaceHitRect(in: window).contains(event.locationInWindow) else {
            super.mouseDown(with: event)
            return
        }

        isDraggingFace = true
        dragDidMove = false
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        controller?.prepareForDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingFace, let window else {
            super.mouseDragged(with: event)
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - dragStartMouseLocation.x
        let deltaY = currentLocation.y - dragStartMouseLocation.y

        if abs(deltaX) > 3 || abs(deltaY) > 3 {
            dragDidMove = true
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.setFrameOrigin(
                NSPoint(
                    x: dragStartWindowOrigin.x + deltaX,
                    y: dragStartWindowOrigin.y + deltaY
                )
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingFace else {
            super.mouseUp(with: event)
            return
        }

        isDraggingFace = false
        controller?.finishDrag()

        if !dragDidMove {
            controller?.toggleExpanded()
        }
    }

    private func robotFaceHitRect(in window: NSWindow) -> NSRect {
        let contentSize = window.contentView?.bounds.size ?? bounds.size
        return NSRect(
            x: contentSize.width - FloatingAgentLayout.panelPadding - FloatingAgentLayout.faceSize,
            y: FloatingAgentLayout.panelPadding,
            width: FloatingAgentLayout.faceSize,
            height: FloatingAgentLayout.faceSize
        )
        .insetBy(dx: -16, dy: -16)
    }
}

@MainActor
final class FloatingAgentController: ObservableObject {
    @Published var isExpanded = false
    @Published var isDragging = false
    @Published var latestMessage = "TICK is quietly watching for useful moments."
    @Published var transcript: [AgentMessage] = []
    @Published var isRequesting = false
    @Published var peekMessage = ""
    @Published var peekActions: [AgentAction] = []

    var hasPeekSuggestion: Bool {
        !peekMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum PromptSource {
        case user
        case activity
    }

    private let panel: FloatingAgentPanel
    private let settingsStore: LLMSettingsStore
    private let toolStore: AgentToolConfigurationStore
    private var collapseWorkItem: DispatchWorkItem?

    init(settingsStore: LLMSettingsStore, toolStore: AgentToolConfigurationStore) {
        self.settingsStore = settingsStore
        self.toolStore = toolStore
        let contentRect = NSRect(origin: .zero, size: FloatingAgentLayout.panelSize)
        panel = FloatingAgentPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let rootView = FloatingAgentView(controller: self)
        panel.contentView = FloatingAgentHostingView(rootView: rootView, controller: self)
        positionNearLowerRight()
        latestMessage = settingsStore.isConfigured ? "Model connected. Ask me anything." : "Choose a model and add your API key to start."
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func prepareForDrag() {
        collapseWorkItem?.cancel()
        isDragging = true
    }

    func finishDrag() {
        collapseWorkItem?.cancel()
        isDragging = false
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpandedFromDrop() {
        setExpanded(true, autoCollapse: false)
    }

    func collapse() {
        setExpanded(false)
    }

    func refreshConfigurationStatus() {
        latestMessage = settingsStore.isConfigured ? "Model connected. Ask me anything." : settingsStore.missingConfigurationMessage
        if transcript.isEmpty {
            setExpanded(true, autoCollapse: !settingsStore.isConfigured)
        }
    }

    func sendReply(_ text: String) {
        sendReply(text, attachments: [])
    }

    func previewActivitySignal(_ signal: ActivitySignal) {
        latestMessage = signal.title
    }

    func handleActivitySignal(_ signal: ActivitySignal) {
        if signal.type == "risk.operation_detected" {
            showImmediateRiskWarning(signal)
        }

        guard settingsStore.isConfigured, !isRequesting else {
            if signal.type != "risk.operation_detected" {
                latestMessage = signal.title
            }
            return
        }

        if signal.type != "risk.operation_detected" {
            latestMessage = signal.title
        }
        sendSystemPrompt(
            signal.prompt,
            visibleUserText: signal.title,
            attachments: [],
            includeTranscriptHistory: false,
            source: .activity,
            activitySignalType: signal.type
        )
    }

    private func showImmediateRiskWarning(_ signal: ActivitySignal) {
        let riskKind = signal.context["riskKind"] ?? "高风险操作"
        let message = """
        ### 我看到了什么
        先别急着执行：\(riskKind)

        ### 我判断你可能卡在哪里
        这一步可能会删除、覆盖或重置重要内容。

        ### 我能帮你做什么
        我可以先帮你生成更安全的替代命令，或者列一份确认清单。
        """
        let actions = [
            AgentAction(title: "生成安全替代命令", prompt: "请基于刚才检测到的高风险操作，生成更安全的替代命令。要求包含 dry-run、备份或影响范围预览。原始操作：\(signal.detail)"),
            AgentAction(title: "列确认清单", prompt: "请把刚才检测到的高风险操作转换成执行前确认清单，并指出哪些信息必须由我确认。原始操作：\(signal.detail)")
        ]
        presentPeek(message: message, actions: actions)
        if transcript.last?.text != message {
            transcript.append(AgentMessage(role: .agent, text: message, actions: actions))
            trimTranscriptIfNeeded()
        }
        traceLog("activity.risk.immediate", "risk=\(riskKind)\n\(signal.detail)")
    }

    func sendReply(_ text: String, attachments: [MessageAttachment]) {
        sendPrompt(text, visibleUserText: text, attachments: attachments)
    }

    private func sendSystemPrompt(
        _ prompt: String,
        visibleUserText: String,
        attachments: [MessageAttachment] = [],
        includeTranscriptHistory: Bool = true,
        source: PromptSource = .user,
        activitySignalType: String? = nil
    ) {
        sendPrompt(
            prompt,
            visibleUserText: visibleUserText,
            attachments: attachments,
            includeTranscriptHistory: includeTranscriptHistory,
            source: source,
            activitySignalType: activitySignalType
        )
    }

    private func sendPrompt(
        _ prompt: String,
        visibleUserText: String,
        attachments: [MessageAttachment],
        includeTranscriptHistory: Bool = true,
        source: PromptSource = .user,
        activitySignalType: String? = nil
    ) {
        let trimmedText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVisibleText = visibleUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmedText.isEmpty || !attachments.isEmpty), !isRequesting else {
            return
        }

        guard settingsStore.isConfigured else {
            latestMessage = settingsStore.missingConfigurationMessage
            transcript.append(AgentMessage(role: .agent, text: "Please finish model settings first: \(settingsStore.missingConfigurationMessage)."))
            traceLog("chat.blocked", settingsStore.missingConfigurationMessage)
            setExpanded(true, autoCollapse: false)
            return
        }

        if source == .user {
            clearPeek()
        }

        if source == .user {
            transcript.append(AgentMessage(role: .user, text: trimmedVisibleText.isEmpty ? "Activity signal" : trimmedVisibleText, attachments: attachments))
            trimTranscriptIfNeeded()
            latestMessage = "Thinking..."
            setExpanded(true, autoCollapse: false)
        } else {
            latestMessage = "TICK 注意到了一些内容..."
        }
        isRequesting = true

        let wasExpanded = isExpanded
        let requestMessage = AgentMessage(
            role: .user,
            text: trimmedText.isEmpty ? "Image" : trimmedText,
            attachments: attachments
        )
        var requestTranscript = includeTranscriptHistory ? transcript : [requestMessage]
        if includeTranscriptHistory, !requestTranscript.isEmpty {
            requestTranscript[requestTranscript.count - 1] = requestMessage
        }
        let requestSettings = settingsStore.settings
        let requestAPIKey = settingsStore.apiKey
        let requestToolConfiguration = toolStore.refreshFromDiskForRequest()
        let traceID = TraceContext.makeID()
        traceLog(
            "chat.request",
            "model=\(requestSettings.model)\nuser=\(trimmedVisibleText)\nprompt_chars=\(trimmedText.count)\nattachments=\(attachments.count)\ninclude_history=\(includeTranscriptHistory)\nmemory_entries=\(MemoryStore.shared.learnedCount)",
            traceID: traceID
        )

        Task {
            await TraceContext.$currentID.withValue(traceID) {
                do {
                    let result = try await AgentLoop.run(
                        transcript: requestTranscript,
                        settings: requestSettings,
                        apiKey: requestAPIKey,
                        toolConfiguration: requestToolConfiguration
                    )

                    await MainActor.run {
                        if source == .activity, self.shouldSuppressActivityOutput(result.finalText) {
                            self.latestMessage = "TICK 正在安静观察合适的时机。"
                            self.clearPeek()
                            self.isRequesting = false
                            traceLog(
                                "chat.suppressed",
                                "reason=low_value_activity_output\nresponse=\(result.finalText)",
                                tokenUsage: result.usage
                            )
                            return
                        }

                        if source == .activity {
                            self.transcript.append(AgentMessage(role: .user, text: trimmedVisibleText.isEmpty ? "Activity signal" : trimmedVisibleText, attachments: attachments))
                        }

                        let actionOutput = AgentActionParser.parse(result.finalText)
                        self.transcript.append(AgentMessage(role: .agent, text: actionOutput.text, thoughts: result.thoughts, toolExecutions: result.toolExecutions, actions: actionOutput.actions))
                        self.trimTranscriptIfNeeded()
                        let previewText = self.previewText(from: actionOutput.text, fallback: trimmedVisibleText)
                        self.latestMessage = previewText
                        self.isRequesting = false

                        MemoryStore.shared.ingestConversation(
                            userText: trimmedText,
                            assistantText: actionOutput.text,
                            source: source == .activity ? "activity" : "user",
                            signalType: activitySignalType
                        )

                        let toolSummary = result.toolExecutions.map { "\($0.kind) \($0.name): \($0.output)" }.joined(separator: "\n")
                        traceLog(
                            "chat.response",
                            """
                            model=\(requestSettings.model)
                            response=\(actionOutput.text)
                            actions=\(actionOutput.actions.count)
                            thoughts=\(result.thoughts.count)
                            tools=\(result.toolExecutions.count)
                            \(toolSummary)
                            """,
                            tokenUsage: result.usage
                        )
                        if source == .activity {
                            self.presentPeek(message: previewText, actions: actionOutput.actions)
                            if wasExpanded {
                                self.setExpanded(true, autoCollapse: false)
                            }
                        } else {
                            self.clearPeek()
                            self.setExpanded(true, autoCollapse: false)
                        }
                    }
                } catch {
                    await MainActor.run {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        self.transcript.append(AgentMessage(role: .agent, text: message))
                        self.trimTranscriptIfNeeded()
                        self.latestMessage = message
                        self.isRequesting = false
                        self.clearPeek()
                        traceLog("chat.error", message)
                        self.setExpanded(true, autoCollapse: false)
                    }
                }
            }
        }
    }

    private func trimTranscriptIfNeeded() {
        if transcript.count > 6 {
            transcript.removeFirst(transcript.count - 6)
        }
    }

    private func shouldSuppressActivityOutput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "TICK_SILENT" {
            return true
        }

        let lower = trimmed.lowercased()
        if lower.contains("```tick-actions") ||
            trimmed.contains("### 我看到了什么") ||
            trimmed.contains("### 我判断你可能卡在哪里") ||
            trimmed.contains("### 我能帮你做什么") ||
            trimmed.contains("### 可执行动作") ||
            trimmed.contains("我猜你") ||
            trimmed.contains("我检测到") ||
            trimmed.contains("我看到了") ||
            trimmed.contains("我判断") ||
            trimmed.contains("我能帮你") {
            return false
        }

        let internalFailureSignals = [
            "截图路径",
            "screen-",
            "screenshot",
            "screen recording",
            "可访问性",
            "accessibility",
            "授权",
            "权限",
            "暂无可读文本",
            "未获取到",
            "无法读取",
            "无法解析",
            "不能判断",
            "信息不足",
            "后台监听",
            "捕获到截图兜底",
            "需要进一步视觉识别"
        ]

        if internalFailureSignals.contains(where: { lower.contains($0.lowercased()) }) {
            return true
        }

        if !containsChinese(trimmed) {
            return true
        }

        let meaningfulSignals = [
            "错误", "异常", "失败", "建议", "下一步", "原因", "风险", "注意", "完成",
            "error", "failed", "exception", "warning", "todo", "fix", "api", "test", "build"
        ]
        if meaningfulSignals.contains(where: { lower.contains($0.lowercased()) }) {
            return false
        }

        return trimmed.count < 24
    }

    private func setExpanded(_ expanded: Bool, autoCollapse: Bool = true) {
        collapseWorkItem?.cancel()

        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isExpanded = expanded
        }

        if expanded && autoCollapse {
            scheduleAutoCollapse()
        }
    }

    private func presentPeek(message: String, actions: [AgentAction]) {
        let compact = message.trimmingCharacters(in: .whitespacesAndNewlines)
        peekMessage = compact.isEmpty ? "TICK 已整理出一个可执行建议。" : String(compact.prefix(260))
        peekActions = Array(actions.prefix(2))
        latestMessage = peekMessage
    }

    private func clearPeek() {
        peekMessage = ""
        peekActions = []
    }

    private func previewText(from output: String, fallback: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(260))
        }
        return fallback.isEmpty ? "TICK 已给出一个动作建议。" : String(fallback.prefix(260))
    }

    private func containsChinese(_ text: String) -> Bool {
        text.range(of: #"[一-龥]"#, options: .regularExpression) != nil
    }

    private func scheduleAutoCollapse() {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }

                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    self.isExpanded = false
                }
            }
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: workItem)
    }

    private func positionNearLowerRight() {
        guard let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            panel.center()
            return
        }

        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - 34,
            y: screenFrame.minY + 88
        )
        panel.setFrameOrigin(origin)
    }
}

struct AgentMessage: Identifiable, Equatable {
    enum Role {
        case agent
        case user
    }

    let id = UUID()
    let role: Role
    let text: String
    var attachments: [MessageAttachment] = []
    var toolUses: [LLMToolUse] = []
    var thoughts: [AgentThought] = []
    var toolExecutions: [AgentToolExecution] = []
    var actions: [AgentAction] = []
}

struct AgentAction: Identifiable, Codable, Equatable {
    let id = UUID()
    let title: String
    let prompt: String

    enum CodingKeys: String, CodingKey {
        case title
        case prompt
    }
}

enum AgentActionParser {
    struct Output {
        let text: String
        let actions: [AgentAction]
    }

    static func parse(_ rawText: String) -> Output {
        let pattern = #"(?s)```tick-actions\s*(.*?)\s*```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawText, range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)),
              let jsonRange = Range(match.range(at: 1), in: rawText),
              let blockRange = Range(match.range(at: 0), in: rawText) else {
            return Output(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines), actions: [])
        }

        let jsonText = String(rawText[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = decodeActions(jsonText)
        var visibleText = rawText
        visibleText.removeSubrange(blockRange)
        return Output(
            text: visibleText.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions
        )
    }

    private static func decodeActions(_ jsonText: String) -> [AgentAction] {
        guard let data = jsonText.data(using: .utf8),
              let actions = try? JSONDecoder().decode([AgentAction].self, from: data) else {
            return []
        }

        return actions
            .map {
                AgentAction(
                    title: String($0.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(36)),
                    prompt: $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.title.isEmpty && !$0.prompt.isEmpty }
            .prefix(4)
            .map { $0 }
    }
}

struct MessageAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let mediaType: String
    let base64Data: String

    init(id: UUID = UUID(), filename: String, mediaType: String, base64Data: String) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.base64Data = base64Data
    }
}

struct FloatingAgentView: View {
    @ObservedObject var controller: FloatingAgentController

    @State private var blink = false
    @State private var smile = false
    @State private var breathe = false
    @State private var replyText = ""
    @State private var attachments: [MessageAttachment] = []
    @State private var isDropTargeted = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if !controller.isExpanded && controller.hasPeekSuggestion {
                ActivityPeekCard(
                    message: controller.peekMessage,
                    actions: controller.peekActions,
                    expand: controller.toggleExpanded,
                    runAction: runAction
                )
                .transition(.move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }

            if controller.isExpanded {
                AgentBubble(
                    latestMessage: controller.latestMessage,
                    transcript: controller.transcript,
                    isRequesting: controller.isRequesting,
                    attachments: $attachments,
                    replyText: $replyText,
                    send: sendReply,
                    runAction: runAction,
                    close: controller.collapse
                )
                .onImageDrop(isTargeted: $isDropTargeted, append: addAttachments)
                .transition(.move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }

            RobotFace(
                isExpanded: controller.isExpanded,
                isAnalyzing: controller.isRequesting && !controller.isDragging,
                hasSuggestion: controller.hasPeekSuggestion && !controller.isExpanded,
                blink: blink,
                smile: smile,
                breathe: breathe && !controller.isDragging
            )
                .frame(width: FloatingAgentLayout.faceSize, height: FloatingAgentLayout.faceSize)
                .contentShape(Circle())
                .accessibilityLabel("TICK floating agent")
                .onImageDrop(isTargeted: $isDropTargeted) { droppedAttachments in
                    addAttachments(droppedAttachments)
                    controller.setExpandedFromDrop()
                }
        }
        .padding(10)
        .frame(
            width: FloatingAgentLayout.panelSize.width,
            height: FloatingAgentLayout.panelSize.height,
            alignment: .bottomTrailing
        )
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(red: 0.18, green: 0.62, blue: 0.72).opacity(isDropTargeted ? 0.85 : 0), lineWidth: 2)
        )
        .onAppear {
            startFaceAnimation()
        }
    }

    private func sendReply() {
        controller.sendReply(replyText, attachments: attachments)
        replyText = ""
        attachments = []
    }

    private func runAction(_ action: AgentAction) {
        controller.sendReply(action.prompt, attachments: attachments)
        replyText = ""
        attachments = []
    }

    private func addAttachments(_ newAttachments: [MessageAttachment]) {
        guard !newAttachments.isEmpty else {
            return
        }

        var merged = attachments
        for attachment in newAttachments where !merged.contains(where: { $0.base64Data == attachment.base64Data }) {
            merged.append(attachment)
        }
        attachments = Array(merged.prefix(6))
        traceLog("image.attach", "attachments=\(attachments.count)")
    }

    private func startFaceAnimation() {
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            breathe = true
        }

        scheduleBlink()
        scheduleSmile()
    }

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.4...4.8)) {
            withAnimation(.easeInOut(duration: 0.08)) {
                blink = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.easeInOut(duration: 0.12)) {
                    blink = false
                }
                scheduleBlink()
            }
        }
    }

    private func scheduleSmile() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 5.0...8.0)) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                smile = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    smile = false
                }
                scheduleSmile()
            }
        }
    }
}

private struct RobotFace: View {
    let isExpanded: Bool
    let isAnalyzing: Bool
    let hasSuggestion: Bool
    let blink: Bool
    let smile: Bool
    let breathe: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    hasSuggestion && !isAnalyzing ? Color(red: 0.46, green: 0.94, blue: 0.72).opacity(breathe ? 0.76 : 0.35) : .clear,
                    lineWidth: hasSuggestion ? 3 : 0
                )
                .frame(width: 84, height: 84)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            topColor,
                            bottomColor
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 52, height: 52)
                .offset(x: -10, y: -12)
                .blur(radius: 8)

            FaceScreen(blink: blink, smile: smile || isExpanded)
                .frame(width: 50, height: 38)

            Circle()
                .fill(statusDotColor)
                .frame(width: activeDotSize, height: activeDotSize)
                .offset(x: 22, y: -24)
                .opacity(isExpanded || isAnalyzing || hasSuggestion ? 1 : 0.64)
        }
        .scaleEffect(breathe ? (isAnalyzing ? 1.06 : (hasSuggestion ? 1.045 : 1.035)) : 0.985)
        .shadow(
            color: glowColor,
            radius: glowRadius,
            x: 0,
            y: 0
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeInOut(duration: 0.9), value: isAnalyzing)
        .animation(.easeInOut(duration: 0.9), value: hasSuggestion)
    }

    private var topColor: Color {
        if isAnalyzing {
            return breathe ? Color(red: 0.99, green: 0.64, blue: 0.24) : Color(red: 0.12, green: 0.78, blue: 0.74)
        }
        if hasSuggestion {
            return breathe ? Color(red: 0.36, green: 0.88, blue: 0.72) : Color(red: 0.17, green: 0.63, blue: 0.76)
        }
        return Color(red: 0.20, green: 0.55, blue: 0.78)
    }

    private var bottomColor: Color {
        if isAnalyzing {
            return breathe ? Color(red: 0.10, green: 0.52, blue: 0.58) : Color(red: 0.07, green: 0.30, blue: 0.44)
        }
        if hasSuggestion {
            return Color(red: 0.08, green: 0.36, blue: 0.46)
        }
        return Color(red: 0.09, green: 0.28, blue: 0.42)
    }

    private var statusDotColor: Color {
        if isAnalyzing {
            return Color(red: 1.00, green: 0.82, blue: 0.34)
        }
        if hasSuggestion {
            return Color(red: 0.54, green: 1.00, blue: 0.65)
        }
        return Color(red: 0.54, green: 0.93, blue: 0.94)
    }

    private var activeDotSize: CGFloat {
        if isAnalyzing && breathe {
            return 10
        }
        if hasSuggestion && breathe {
            return 9
        }
        return 8
    }

    private var glowColor: Color {
        if isAnalyzing {
            return Color(red: 0.17, green: 0.82, blue: 0.74).opacity(breathe ? 0.42 : 0.18)
        }
        if hasSuggestion {
            return Color(red: 0.28, green: 0.88, blue: 0.62).opacity(breathe ? 0.34 : 0.14)
        }
        return .clear
    }

    private var glowRadius: CGFloat {
        if isAnalyzing {
            return breathe ? 16 : 8
        }
        if hasSuggestion {
            return breathe ? 14 : 6
        }
        return 0
    }
}

private struct FaceScreen: View {
    let blink: Bool
    let smile: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.83, green: 0.98, blue: 0.97).opacity(0.96))

            HStack(spacing: 10) {
                Eye(blink: blink)
                Eye(blink: blink)
            }
            .offset(y: -4)

            Smile(smile: smile)
                .stroke(Color(red: 0.08, green: 0.26, blue: 0.34), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
                .frame(width: 22, height: smile ? 10 : 6)
                .offset(y: 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct Eye: View {
    let blink: Bool

    var body: some View {
        Capsule()
            .fill(Color(red: 0.08, green: 0.26, blue: 0.34))
            .frame(width: 8, height: blink ? 2 : 10)
    }
}

private struct Smile: Shape {
    let smile: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX + 2, y: smile ? rect.midY - 1 : rect.midY)
        let end = CGPoint(x: rect.maxX - 2, y: smile ? rect.midY - 1 : rect.midY)
        let control = CGPoint(x: rect.midX, y: smile ? rect.maxY + 1 : rect.midY + 1)

        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

private struct ActivityPeekCard: View {
    let message: String
    let actions: [AgentAction]
    let expand: () -> Void
    let runAction: (AgentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.56))

                Text("TICK")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.11, green: 0.18, blue: 0.22))

                Spacer()

                Button(action: expand) {
                    Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.18, green: 0.28, blue: 0.33))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("展开详情")
            }

            MarkdownText(message, size: 13, weight: .semibold)
                .foregroundStyle(Color(red: 0.12, green: 0.19, blue: 0.24))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(actions.prefix(2)) { action in
                        Button {
                            runAction(action)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text(action.title)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(red: 0.09, green: 0.38, blue: 0.42))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(11)
        .frame(width: 252, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
        )
    }
}

private struct AgentBubble: View {
    let latestMessage: String
    let transcript: [AgentMessage]
    let isRequesting: Bool
    @Binding var attachments: [MessageAttachment]
    @Binding var replyText: String
    let send: () -> Void
    let runAction: (AgentAction) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isRequesting ? Color(red: 0.96, green: 0.70, blue: 0.30) : Color(red: 0.38, green: 0.89, blue: 0.78))
                    .frame(width: 8, height: 8)

                Text("TICK")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.12, green: 0.19, blue: 0.24))

                Spacer()

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.22, green: 0.31, blue: 0.36))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            MarkdownText(latestMessage, size: 15, weight: .semibold)
                .foregroundStyle(Color(red: 0.11, green: 0.17, blue: 0.22))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(transcript) { message in
                            MessageRow(message: message, runAction: runAction)
                                .id(message.id)
                        }
                    }
                }
                .frame(height: 124)
                .onChange(of: transcript) { messages in
                    guard let lastMessage = messages.last else {
                        return
                    }
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                Text(attachment.filename)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.62))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(height: 25)
            }

            HStack(spacing: 8) {
                Button(action: chooseImage) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.10, green: 0.42, blue: 0.56))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.62))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)

                TextField("Ask TICK", text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .disabled(isRequesting)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: isRequesting ? "hourglass" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(isRequesting ? Color(red: 0.48, green: 0.55, blue: 0.58) : Color(red: 0.10, green: 0.42, blue: 0.56))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isRequesting)
            }
        }
        .padding(12)
        .frame(width: FloatingAgentLayout.bubbleWidth, height: FloatingAgentLayout.bubbleHeight)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff]

        if panel.runModal() == .OK {
            let newAttachments = panel.urls.compactMap { MessageAttachment.from(url: $0) }
            attachments = Array((attachments + newAttachments).prefix(6))
        }
    }
}

private extension View {
    func onImageDrop(isTargeted: Binding<Bool>, append: @escaping ([MessageAttachment]) -> Void) -> some View {
        onDrop(
            of: [
                UTType.fileURL.identifier,
                UTType.image.identifier,
                UTType.png.identifier,
                UTType.jpeg.identifier,
                UTType.tiff.identifier,
                UTType.gif.identifier,
                UTType.heic.identifier
            ],
            isTargeted: isTargeted
        ) { providers in
            MessageAttachment.load(from: providers, append: append)
            return true
        }
    }
}

private struct MessageRow: View {
    let message: AgentMessage
    let runAction: (AgentAction) -> Void

    var body: some View {
        VStack(alignment: message.role == .agent ? .leading : .trailing, spacing: 4) {
            if message.role == .agent && (!message.thoughts.isEmpty || !message.toolExecutions.isEmpty) {
                AgentRunSummary(message: message, runAction: runAction)
            } else {
                MarkdownText(messageText, size: 12, weight: .medium)
                    .foregroundStyle(message.role == .agent ? Color(red: 0.22, green: 0.32, blue: 0.38) : Color(red: 0.08, green: 0.33, blue: 0.42))
                    .frame(maxWidth: .infinity, alignment: message.role == .agent ? .leading : .trailing)

                ForEach(message.toolUses) { toolUse in
                    ToolUseChip(toolUse: toolUse)
                }

                if message.role == .agent && !message.actions.isEmpty {
                    ActionButtonList(actions: message.actions, runAction: runAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .agent ? .leading : .trailing)
    }

    private var messageText: String {
        guard !message.attachments.isEmpty else {
            return message.text
        }

        return "\(message.text)  [\(message.attachments.count) image\(message.attachments.count == 1 ? "" : "s")]"
    }
}

private struct AgentRunSummary: View {
    let message: AgentMessage
    let runAction: (AgentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.toolExecutions.isEmpty {
                SummarySection(title: "Tools", systemImage: "wrench.and.screwdriver") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(message.toolExecutions) { execution in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(execution.kind) · \(execution.name) · \(execution.success ? "成功" : "失败")")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                MarkdownText(execution.output, size: 10, weight: .medium, design: .monospaced)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }

            if !message.thoughts.isEmpty {
                SummarySection(title: "Thinking", systemImage: "brain.head.profile") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(message.thoughts) { thought in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thought.title)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                MarkdownText(thought.detail, size: 10, weight: .medium)
                                    .lineLimit(4)
                            }
                        }
                    }
                }
            }

            SummarySection(title: "Result", systemImage: "checkmark.circle") {
                MarkdownText(message.text, size: 12, weight: .medium)
                    .foregroundStyle(Color(red: 0.12, green: 0.18, blue: 0.22))
                    .textSelection(.enabled)
            }

            if !message.actions.isEmpty {
                SummarySection(title: "Actions", systemImage: "bolt") {
                    ActionButtonList(actions: message.actions, runAction: runAction)
                }
            }
        }
        .frame(maxWidth: 286, alignment: .leading)
    }
}

private struct ActionButtonList: View {
    let actions: [AgentAction]
    let runAction: (AgentAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    runAction(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(action.title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("⌘\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.09, green: 0.38, blue: 0.42))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
            }
        }
    }
}

private struct SummarySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            content
        }
        .foregroundStyle(Color(red: 0.09, green: 0.27, blue: 0.33))
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ToolUseChip: View {
    let toolUse: LLMToolUse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 10, weight: .bold))
                Text(toolUse.name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            MarkdownText(toolUse.input, size: 10, weight: .medium, design: .monospaced)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .foregroundStyle(Color(red: 0.09, green: 0.27, blue: 0.33))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 250, alignment: .leading)
        .background(Color.white.opacity(0.70))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MarkdownText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(_ text: String, size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .rounded) {
        self.text = text
        self.size = size
        self.weight = weight
        self.design = design
    }

    var body: some View {
        markdownText
            .font(.system(size: size, weight: weight, design: design))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var markdownText: some View {
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

extension MessageAttachment {
    static func load(from providers: [NSItemProvider], append: @escaping ([MessageAttachment]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var loadedAttachments: [MessageAttachment] = []

        for provider in providers {
            group.enter()
            load(from: provider) { attachment in
                if let attachment {
                    lock.lock()
                    loadedAttachments.append(attachment)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            append(loadedAttachments)
        }
    }

    private static func load(from provider: NSItemProvider, completion: @escaping (MessageAttachment?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                completion(attachment(fromDroppedFileItem: item))
            }
            return
        }

        let imageTypes = [UTType.png, UTType.jpeg, UTType.heic, UTType.tiff, UTType.gif, UTType.image]
        guard let type = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            completion(nil)
            return
        }

        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
            if let data = item as? Data {
                completion(from(data: data, filename: "dropped-image.\(preferredExtension(for: type))", mediaType: mediaType(for: type)))
            } else if let url = item as? URL {
                completion(from(url: url))
            } else if let image = item as? NSImage {
                completion(from(image: image, filename: "dropped-image.png"))
            } else {
                completion(nil)
            }
        }
    }

    private static func attachment(fromDroppedFileItem item: NSSecureCoding?) -> MessageAttachment? {
        if let url = item as? URL {
            return from(url: url)
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) {
            return from(url: url)
        }

        if let string = item as? String,
           let url = URL(string: string) {
            return from(url: url)
        }

        return nil
    }

    static func from(url: URL) -> MessageAttachment? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let mediaType = mediaType(for: url)
        return MessageAttachment(
            filename: url.lastPathComponent,
            mediaType: mediaType,
            base64Data: data.base64EncodedString()
        )
    }

    static func screenshotAttachment(fromPath path: String) -> MessageAttachment? {
        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url),
              let data = jpegData(from: image, maxDimension: 1280, compression: 0.58) else {
            return from(url: url)
        }

        traceLog("image.screenshot", "path=\(path)\nbytes=\(data.count)")
        return MessageAttachment(
            filename: url.deletingPathExtension().lastPathComponent + ".jpg",
            mediaType: "image/jpeg",
            base64Data: data.base64EncodedString()
        )
    }

    static func from(data: Data, filename: String, mediaType: String) -> MessageAttachment {
        MessageAttachment(
            filename: filename,
            mediaType: mediaType,
            base64Data: data.base64EncodedString()
        )
    }

    static func from(image: NSImage, filename: String) -> MessageAttachment? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return from(data: data, filename: filename, mediaType: "image/png")
    }

    private static func jpegData(from image: NSImage, maxDimension: CGFloat, compression: CGFloat) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let scale = min(1, maxDimension / max(sourceSize.width, sourceSize.height))
        let targetSize = NSSize(
            width: max(1, floor(sourceSize.width * scale)),
            height: max(1, floor(sourceSize.height * scale))
        )
        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        resizedImage.unlockFocus()

        guard let tiff = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    static func mediaType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "image/png"
        }
        return mimeType
    }

    static func mediaType(for type: UTType) -> String {
        type.preferredMIMEType ?? "image/png"
    }

    static func preferredExtension(for type: UTType) -> String {
        type.preferredFilenameExtension ?? "png"
    }
}
