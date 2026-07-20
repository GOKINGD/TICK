import Foundation

struct ActivitySignal: Codable, Equatable {
    let type: String
    let confidence: Double
    let title: String
    let detail: String
    let context: [String: String]
    let date: Date

    private var actionOutputContract: String {
        """
        输出形态要求：
        - 必须用中文 Markdown
        - 不要写“总结/概览/这篇文章讲了什么”式内容
        - 结构固定为：
          ### 我看到了什么
          ### 我判断你可能卡在哪里
          ### 我能帮你做什么
          ### 可执行动作
        - 前三段尽量简短，除非是错误诊断
        - 最后必须附加一个单独代码块，格式严格如下：
        ```tick-actions
        [{"title":"按钮文案","prompt":"用户点击后要发送给 TICK 的具体指令"}]
        ```
        - 按钮文案必须是动作，不要是“了解更多”
        - 动作数控制在 2 到 4 个
        - 如果没有足够信息形成行动，只输出 TICK_SILENT
        """
    }

    var prompt: String {
        let appName = context["appName"] ?? ""
        let bundleID = context["bundleID"] ?? ""
        let windowTitle = context["windowTitle"] ?? ""
        if type.hasSuffix(".error_diagnostic") {
            return """
            用户当前遇到了一个明确的错误或失败信号。请基于下面的紧凑错误上下文，给出精确、可执行的中文 Markdown 诊断。

            输出要求：
            - 固定结构为：
              ### 问题判断
              ### 最可能原因
              ### 最小修复
              ### 可执行动作
            - 引用最关键的原始错误行、文件路径或命令；没有就不要编造
            - 给出 1-3 个最可能原因，按概率排序
            - 给出可以直接尝试的修复步骤；如果适合，提供下一条可执行命令、补丁草案或校验动作
            - 对删除数据、重置代码、覆盖文件、生产环境变更等高风险动作，必须提示先确认
            - 不要泛泛建议“检查日志”；不要提及后台监听、权限、截图、可访问性
            - 必须用中文回答；即使错误是英文，也要翻译和解释
            \(actionOutputContract)

            Signal: \(type)
            App: \(appName) (\(bundleID))
            Window: \(windowTitle)
            Category: \(context["diagnosticCategory"] ?? "")
            Headline: \(context["diagnosticHeadline"] ?? "")

            Error context:
            \(detail)
            """
        }

        if type == "risk.operation_detected" {
            return """
            用户可能正在输入、复制或准备执行一个高风险操作。请立刻给出简短中文 Markdown 预警，帮助用户避免误操作。

            输出要求：
            - 固定结构为：
              ### 风险判断
              ### 可能后果
              ### 更安全做法
              ### 可执行动作
            - 明确指出可能造成的后果
            - 给出更安全的替代步骤，例如 dry-run、备份、限制路径、加 WHERE、先预览命中范围
            - 如果需要用户确认，列出确认清单
            - 不要夸大，不要提及后台监听或系统权限
            \(actionOutputContract)

            Signal: \(type)
            App: \(appName) (\(bundleID))
            Window: \(windowTitle)
            Risk: \(context["riskKind"] ?? "")

            Operation context:
            \(detail)
            """
        }

        if type == "browser.page_idle" {
            let url = context["url"] ?? ""
            let pageTitle = context["pageTitle"] ?? windowTitle
            return """
            用户正在浏览一个技术页面，并在页面上停留了超过 3 秒。这代表用户正在输入信息，不需要你复述页面。请预判用户可能下一步想做什么，并提供可执行行动选项。

            要求：
            - 固定结构为：
              ### 我看到了什么
              ### 我判断你可能卡在哪里
              ### 我能帮你做什么
              ### 可执行动作
            - 绝对不要输出网页摘要
            - 如果页面像教程/文档，提取命令、配置项、依赖检查或本地验证动作
            - 如果页面像 GitHub Issue/报错页面，建议对比本地日志、定位版本、生成补丁草案
            - 如果页面像 API 文档，建议生成调用样例、校验当前项目依赖、创建请求模板
            - Capture mode 为 page-text 时，页面正文已经提供给你，不要说你无法浏览网页
            - 只在技术文档、GitHub Issue、StackOverflow、API 文档等页面输出；无法判断就输出 TICK_SILENT
            - 不要提及浏览器权限、AppleScript、JavaScript、页面正文读取失败
            - 不要暴露这是后台监听得到的
            \(actionOutputContract)

            Page title: \(pageTitle)
            URL: \(url)
            App: \(appName) (\(bundleID))
            Capture mode: \(context["captureMode"] ?? "")

            Page text:
            \(detail)
            """
        }

        if type == "selection.intent" {
            let trigger = context["trigger"] ?? "selection"
            return """
            用户刚刚在 macOS 当前 App 中\(trigger == "copy" ? "执行了复制" : "高亮选中了一段内容")。这通常表示用户希望对这段内容采取下一步行动，而不是听摘要。

            要求：
            - 固定结构为：
              ### 我看到了什么
              ### 我判断你可能卡在哪里
              ### 我能帮你做什么
              ### 可执行动作
            - 绝对不要输出“这段内容总结如下”
            - 判断用户最可能需要的下一步：诊断错误、提取命令、校验本地环境、生成回复草稿、生成补丁草案、转换格式或准备执行
            - 如果内容包含命令、配置、错误、API、代码或教程步骤，直接提取可操作对象
            - 输出必须是中文；即使原文是英文，也要用中文给行动建议
            - 如果只能复述文本、无法形成具体动作，只输出 TICK_SILENT
            \(actionOutputContract)

            Signal: \(type)
            Trigger: \(trigger)
            App: \(appName) (\(bundleID))
            Window: \(windowTitle)
            Selection mode: \(context["selectionMode"] ?? "")
            Page title: \(context["pageTitle"] ?? "")
            URL: \(context["url"] ?? "")

            Selected/copied context:
            \(detail)
            """
        }

        if type == "terminal.context_idle" {
            return """
            用户在终端窗口停留超过 3 秒。请判断是否存在可推进的下一步：修复失败、校验环境、重跑命令、打开相关文件、生成补丁或提醒任务结果。

            要求：
            - 固定结构为：
              ### 我看到了什么
              ### 我判断你可能卡在哪里
              ### 我能帮你做什么
              ### 可执行动作
            - 不要总结终端文本
            - 如果有明显报错，给出可直接点击的诊断/修复动作
            - 如果是命令完成/测试结果，给出下一步动作，例如重跑失败项、打开报告、清理临时文件、生成提交说明
            - 如果没有明确可帮助的信息，只输出：TICK_SILENT
            - 不要提及截图、路径、权限、后台监听、可访问性、Screen Recording
            \(actionOutputContract)

            App: \(appName) (\(bundleID))
            Window: \(windowTitle)
            Capture mode: \(context["captureMode"] ?? "")

            Visible context:
            \(detail)
            """
        }

        if type == "app.context_idle" {
            return """
            用户在一个 macOS App 窗口停留超过 3 秒。请不要总结窗口内容，而是判断 TICK 能否提供一个具体的下一步行动。

            要求：
            - 固定结构为：
              ### 我看到了什么
              ### 我判断你可能卡在哪里
              ### 我能帮你做什么
              ### 可执行动作
            - 只在能提出明确动作时输出
            - 动作可以是：提取待办、整理回复草稿、校验错误、生成命令、创建补丁草案、打开相关文件建议
            - 如果只是知道 App 名称/窗口名，或内容不足，只输出：TICK_SILENT
            - 不要提及截图、路径、权限、后台监听、可访问性、Screen Recording
            - 不要输出很长，控制在 120 字以内
            \(actionOutputContract)

            App: \(appName) (\(bundleID))
            Window: \(windowTitle)
            Capture mode: \(context["captureMode"] ?? "")

            Visible context:
            \(detail)
            """
        }

        return """
        TICK 观察到一个 macOS 活动信号。请判断是否值得主动帮助。必须用中文输出；即使采集到的是英文报错，也要用中文解释和建议。若本地 skill description 匹配，先使用该 skill。若信号较弱，只输出 TICK_SILENT。
        输出结构固定为：
        ### 我看到了什么
        ### 我判断你可能卡在哪里
        ### 我能帮你做什么
        ### 可执行动作
        \(actionOutputContract)

        Signal: \(type)
        Confidence: \(confidence)
        Title: \(title)
        App: \(appName) (\(bundleID))
        Window: \(windowTitle)
        Detail:
        \(detail)
        """
    }

}

@MainActor
final class ActivityObserverBridge {
    private weak var controller: FloatingAgentController?
    private var process: Process?
    private var readHandle: FileHandle?
    private let decoder = JSONDecoder()
    private var lastPromptDates: [String: Date] = [:]
    private var lastPromptKeys: [String: String] = [:]
    private var outputBuffer = ""

    init(controller: FloatingAgentController) {
        self.controller = controller
        decoder.dateDecodingStrategy = .iso8601
    }

    func start() {
        stop()

        guard let executableURL = observerExecutableURL() else {
            traceLog("observer.error", "TICKObserver executable not found")
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TICK_HOME": TICKRuntime.rootURL.path
        ]) { current, _ in current }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.handleOutput(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            traceLog("observer.stderr", text)
        }

        do {
            try process.run()
            self.process = process
            self.readHandle = outputPipe.fileHandleForReading
            traceLog("observer.start", executableURL.path)
        } catch {
            traceLog("observer.error", error.localizedDescription)
        }
    }

    func stop() {
        readHandle?.readabilityHandler = nil
        readHandle = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func handleOutput(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: "\n")
        outputBuffer = lines.last ?? ""

        for line in lines.dropLast() {
            guard let data = line.data(using: .utf8),
                  let signal = try? decoder.decode(ActivitySignal.self, from: data) else {
                continue
            }
            traceLog("observer.signal", "\(signal.type)\nconfidence=\(signal.confidence)\n\(signal.title)\n\(signal.detail)")
            maybePrompt(signal)
        }
    }

    private func maybePrompt(_ signal: ActivitySignal) {
        if signal.type == "browser.page_unavailable" ||
            signal.type == "browser.applescript_error" ||
            signal.type == "context.silent" {
            return
        }

        if signal.type == "observer.permission" || signal.type == "foreground.changed" {
            controller?.previewActivitySignal(signal)
            return
        }

        guard signal.confidence >= 0.78 else {
            controller?.previewActivitySignal(signal)
            return
        }

        let now = Date()
        let key = signal.type
        let promptKey = promptIdentityKey(for: signal)
        if lastPromptKeys[key] == promptKey {
            controller?.previewActivitySignal(signal)
            return
        }

        if let last = lastPromptDates[key], now.timeIntervalSince(last) < minimumPromptInterval(for: signal.type) {
            controller?.previewActivitySignal(signal)
            return
        }
        lastPromptDates[key] = now
        lastPromptKeys[key] = promptKey
        controller?.handleActivitySignal(signal)
    }

    private func minimumPromptInterval(for type: String) -> TimeInterval {
        if type.hasSuffix(".error_diagnostic") {
            return 6
        }

        switch type {
        case "risk.operation_detected":
            return 4
        case "browser.page_idle":
            return 35
        case "selection.intent":
            return 6
        case "terminal.context_idle":
            return 18
        case "app.context_idle":
            return 45
        case "clipboard.signal":
            return 12
        default:
            return 15
        }
    }

    private func promptIdentityKey(for signal: ActivitySignal) -> String {
        let signature = signal.context["signature"] ??
            signal.context["diagnosticHeadline"] ??
            signal.context["riskKind"] ??
            String(signal.detail.prefix(500))
        return "\(signal.type)|\(signal.context["bundleID"] ?? "")|\(signal.context["windowTitle"] ?? "")|\(signature)"
    }

    private func observerExecutableURL() -> URL? {
        let bundleSibling = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("TICKObserver")
        if FileManager.default.isExecutableFile(atPath: bundleSibling.path) {
            return bundleSibling
        }

        let debugURL = TICKRuntime.rootURL
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("TICKObserver")
        if FileManager.default.isExecutableFile(atPath: debugURL.path) {
            return debugURL
        }

        return nil
    }
}
