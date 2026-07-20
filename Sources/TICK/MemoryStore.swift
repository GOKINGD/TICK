import Combine
import Foundation

enum MemoryCategory: String, Codable, CaseIterable {
    case preference
    case workflow
    case constraint
    case environment

    var displayName: String {
        switch self {
        case .preference:
            return "Preference"
        case .workflow:
            return "Workflow"
        case .constraint:
            return "Constraint"
        case .environment:
            return "Environment"
        }
    }
}

struct MemoryEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var category: MemoryCategory
    var text: String
    var confidence: Double
    var evidenceCount: Int
    var sourceKind: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        category: MemoryCategory,
        text: String,
        confidence: Double,
        evidenceCount: Int = 1,
        sourceKind: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.text = text
        self.confidence = confidence
        self.evidenceCount = evidenceCount
        self.sourceKind = sourceKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private struct MemoryState: Codable {
    var entries: [MemoryEntry] = []
}

private struct MemoryCandidate {
    let category: MemoryCategory
    let text: String
    let confidence: Double
    let sourceKind: String
}

final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var entries: [MemoryEntry] = []
    @Published private(set) var promptPreview = ""
    @Published private(set) var lastUpdated = Date()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "tick.memory.store", qos: .utility)
    private let maxEntries = 16
    private var state = MemoryState()

    private static let defaultPromptFacts = [
        "偏好中文回复；除非用户明确要求其他语言。",
        "偏好行动型输出：先判断下一步能做什么，不做网页或文本摘要。",
        "偏好小而明确的操作按钮，例如校验环境、提取命令、生成补丁草案、列确认清单。",
        "长期记忆只保留本地脱敏后的稳定偏好、习惯和约束；不保存原始剪贴板、密钥、密码、完整路径或完整页面正文。"
    ]

    private init() {
        fileURL = TICKRuntime.rootURL.appendingPathComponent("memory.json")
        queue.sync {
            state = Self.loadState(from: fileURL) ?? MemoryState()
        }
        publishSnapshot()
    }

    func reload() {
        queue.sync {
            state = Self.loadState(from: fileURL) ?? MemoryState()
        }
        publishSnapshot()
    }

    func clear() {
        queue.sync {
            state = MemoryState()
            persistLocked()
        }
        publishSnapshot()
        traceLog("memory.clear", "Long-term memory cleared.")
    }

    func ingestConversation(userText: String, assistantText: String, source: String, signalType: String? = nil) {
        let candidates = MemoryHeuristics.extract(
            userText: userText,
            assistantText: assistantText,
            source: source,
            signalType: signalType
        )
        guard !candidates.isEmpty else {
            return
        }

        var updatedEntries: [MemoryEntry] = []
        var changed = false
        queue.sync {
            for candidate in candidates {
                changed = upsertLocked(candidate) || changed
            }

            if changed {
                pruneLocked()
                persistLocked()
            }
            updatedEntries = sortedEntriesLocked()
        }

        guard changed else {
            return
        }

        publishSnapshot(updatedEntries)
        let latest = candidates.map(\.text).joined(separator: "\n")
        traceLog("memory.update", "entries=\(updatedEntries.count)\n\(latest)")
    }

    func promptContext() -> String {
        queue.sync {
            Self.promptContext(from: sortedEntriesLocked(), about: nil)
        }
    }

    func promptContext(about transcript: [AgentMessage]) -> String {
        let query = Self.queryText(from: transcript)
        guard !query.isEmpty else {
            return promptContext()
        }

        return queue.sync {
            Self.promptContext(from: sortedEntriesLocked(), about: query)
        }
    }

    var learnedCount: Int {
        queue.sync {
            state.entries.count
        }
    }

    private func upsertLocked(_ candidate: MemoryCandidate) -> Bool {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return false
        }

        let key = Self.normalizedKey(category: candidate.category, text: text)
        if let index = state.entries.firstIndex(where: { Self.normalizedKey(category: $0.category, text: $0.text) == key }) {
            state.entries[index].evidenceCount += 1
            state.entries[index].confidence = min(0.99, max(state.entries[index].confidence, candidate.confidence) + 0.03)
            state.entries[index].sourceKind = mergedSourceKinds(state.entries[index].sourceKind, candidate.sourceKind)
            state.entries[index].updatedAt = Date()
            return true
        }

        state.entries.append(
            MemoryEntry(
                category: candidate.category,
                text: text,
                confidence: candidate.confidence,
                sourceKind: candidate.sourceKind
            )
        )
        return true
    }

    private func pruneLocked() {
        state.entries = sortedEntriesLocked()
        if state.entries.count > maxEntries {
            state.entries.removeLast(state.entries.count - maxEntries)
        }
    }

    private func sortedEntriesLocked() -> [MemoryEntry] {
        state.entries.sorted { lhs, rhs in
            if lhs.evidenceCount != rhs.evidenceCount {
                return lhs.evidenceCount > rhs.evidenceCount
            }
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func publishSnapshot(_ snapshot: [MemoryEntry]? = nil) {
        let entriesSnapshot = snapshot ?? queue.sync { sortedEntriesLocked() }
        let preview = Self.promptContext(from: entriesSnapshot, about: nil)
        DispatchQueue.main.async {
            self.entries = entriesSnapshot
            self.promptPreview = preview
            self.lastUpdated = Date()
        }
    }

    private static func loadState(from fileURL: URL) -> MemoryState? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(MemoryState.self, from: data)
    }

    private static func promptContext(from entries: [MemoryEntry], about query: String?) -> String {
        let learned = selectedEntries(from: entries, about: query)
            .map { "- \($0.category.displayName): \($0.text) [evidence=\($0.evidenceCount)]" }

        let defaults = defaultPromptFacts.map { "- Core: \($0)" }
        let lines = defaults + learned

        return """
        Long-term memory profile for TICK.
        Use this as a soft, sanitized preference profile, not as a factual transcript. Current request always wins if it conflicts with memory.
        \(lines.joined(separator: "\n"))
        """
    }

    private static func selectedEntries(from entries: [MemoryEntry], about query: String?) -> [MemoryEntry] {
        let ranked = entries
            .filter { $0.confidence >= 0.72 }
            .sorted { lhs, rhs in
                if lhs.evidenceCount != rhs.evidenceCount {
                    return lhs.evidenceCount > rhs.evidenceCount
                }
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.updatedAt > rhs.updatedAt
            }

        let fallback = Array(ranked.prefix(6))
        guard let query, !query.isEmpty else {
            return fallback
        }

        let matched = ranked.filter { entryMatchesQuery($0, query: query) }
        let merged = uniqueEntries(matched + fallback)
        return Array(merged.prefix(6))
    }

    private static func entryMatchesQuery(_ entry: MemoryEntry, query: String) -> Bool {
        let loweredQuery = query.lowercased()
        let normalizedQuery = MemorySanitizer.normalized(query)
        let keywords = relevanceKeywords(for: entry)

        return keywords.contains { keyword in
            let loweredKeyword = keyword.lowercased()
            return loweredQuery.contains(loweredKeyword) || normalizedQuery.contains(loweredKeyword)
        }
    }

    private static func relevanceKeywords(for entry: MemoryEntry) -> [String] {
        let text = entry.text
        var keywords: [String] = []

        func add(_ values: [String], when condition: Bool) {
            guard condition else {
                return
            }
            keywords.append(contentsOf: values)
        }

        add(["中文", "英文", "语言", "翻译"], when: text.contains("中文回复"))
        add(["总结", "摘要", "概览", "复述", "页面", "行动", "按钮", "下一步"], when: text.contains("页面摘要") || text.contains("行动型输出"))
        add(["复杂", "简单", "少步骤", "配置", "最少"], when: text.contains("简洁设置"))
        add(["下一步", "按钮", "可执行", "动作", "提取"], when: text.contains("可执行下一步"))
        add(["长期", "长上下文", "个人搭子", "习惯", "记忆"], when: text.contains("长期偏好"))
        add(["脱敏", "隐私", "安全", "密钥", "token", "密码", "剪贴板", "路径"], when: text.contains("脱敏"))
        add(["macOS", "终端", "浏览器", "开发工具", "Swift", "Xcode"], when: text.contains("macOS"))
        add(["开源", "github", "仓库", "repo", "下载", "二进制"], when: text.contains("仓库化方式"))
        add(["报错", "错误", "诊断", "环境", "命令", "校验"], when: text.contains("终端报错") || text.contains("最小修复步骤") || text.contains("可执行校验动作"))
        add(["网页", "页面", "浏览器", "命令", "依赖", "下一步"], when: text.contains("浏览网页停留"))
        add(["复制", "选中", "错误", "命令", "配置", "补丁"], when: text.contains("复制或选中"))
        add(["终端", "报错", "环境", "重跑", "补丁"], when: text.contains("终端停留"))
        add(["高风险", "删除", "覆盖", "重置", "dry-run", "确认"], when: text.contains("高风险命令"))

        return Array(Set(keywords))
    }

    private static func uniqueEntries(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            let key = normalizedKey(category: entry.category, text: entry.text)
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private static func queryText(from transcript: [AgentMessage]) -> String {
        let userLines = transcript
            .suffix(6)
            .compactMap { message in
                guard message.role == .user else {
                    return nil
                }
                return message.text
            }
            .joined(separator: "\n")

        return MemorySanitizer.sanitizeForMemory(userLines) ?? ""
    }

    private static func normalizedKey(category: MemoryCategory, text: String) -> String {
        "\(category.rawValue)|\(MemorySanitizer.normalized(text))"
    }

    private func mergedSourceKinds(_ lhs: String, _ rhs: String) -> String {
        var values = Set(lhs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        values.insert(rhs)
        return values.sorted().joined(separator: ",")
    }
}

private enum MemoryHeuristics {
    static func extract(userText: String, assistantText: String, source: String, signalType: String?) -> [MemoryCandidate] {
        let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAssistantText == "TICK_SILENT" ||
            trimmedAssistantText.hasPrefix("模型返回了空内容") ||
            trimmedAssistantText.hasPrefix("模型这次只返回了推理内容") {
            return []
        }

        var candidates: [MemoryCandidate] = []
        let sourceKind = signalType ?? source

        if let signalType {
            candidates += signalCandidates(for: signalType, sourceKind: sourceKind)
        }

        guard let sanitizedText = MemorySanitizer.sanitizeForMemory(userText) else {
            if !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                traceLog("memory.redacted", "Skipped sensitive memory candidate from \(sourceKind).")
            }
            return unique(candidates)
        }

        let lower = sanitizedText.lowercased()
        if containsAny(lower, ["不要总结", "不要给总结", "不要概览", "不要复述", "不要页面摘要", "别总结", "不是总结"]) {
            candidates.append(MemoryCandidate(category: .preference, text: "偏好行动型输出，不要页面摘要或复述。", confidence: 0.97, sourceKind: sourceKind))
        }

        if containsAny(lower, ["中文回复", "用中文", "必须用中文", "输出要中文", "中文回答", "显示全英文"]) {
            candidates.append(MemoryCandidate(category: .preference, text: "偏好中文回复；英文错误也要翻译和解释成中文。", confidence: 0.96, sourceKind: sourceKind))
        }

        if containsAny(lower, ["太复杂", "做的太复杂", "不要太复杂", "简化", "只要", "就行了", "最少必要"]) {
            candidates.append(MemoryCandidate(category: .preference, text: "偏好简洁设置和最少必要步骤，先去掉非必要配置。", confidence: 0.91, sourceKind: sourceKind))
        }

        if containsAny(lower, ["下一步", "可执行", "行动", "按钮", "帮忙干活", "actionable"]) {
            candidates.append(MemoryCandidate(category: .preference, text: "偏好先给可执行下一步和按钮，再给解释。", confidence: 0.88, sourceKind: sourceKind))
        }

        if containsAny(lower, ["长上下文", "长期上下文", "终身", "个人搭子", "熟悉使用者", "习惯"]) {
            candidates.append(MemoryCandidate(category: .preference, text: "希望 TICK 像个人搭子一样积累长期偏好，但只保留脱敏后的稳定习惯。", confidence: 0.95, sourceKind: sourceKind))
        }

        if containsAny(lower, ["脱敏", "隐私", "泄漏", "泄露", "安全策略", "api key", "密钥", "token"]) {
            candidates.append(MemoryCandidate(category: .constraint, text: "长期记忆必须先脱敏，不保存或复述密钥、token、密码、完整剪贴板和完整路径。", confidence: 0.96, sourceKind: sourceKind))
        }

        if containsAny(lower, ["macos", "swift", "xcode", "终端", "terminal", "浏览器", "browser"]) {
            candidates.append(MemoryCandidate(category: .environment, text: "主要工作场景围绕 macOS、终端、浏览器和开发工具。", confidence: 0.82, sourceKind: sourceKind))
        }

        if containsAny(lower, ["github", "开源", "仓库", "repo", "下载", "二进制"]) {
            candidates.append(MemoryCandidate(category: .workflow, text: "偏好把项目以仓库化方式管理，并提供可直接下载的构建物。", confidence: 0.78, sourceKind: sourceKind))
        }

        return unique(candidates)
    }

    private static func signalCandidates(for signalType: String, sourceKind: String) -> [MemoryCandidate] {
        switch signalType {
        case let value where value.hasSuffix(".error_diagnostic"):
            return [
                MemoryCandidate(category: .workflow, text: "遇到复制或终端报错时，优先给精确原因、最小修复步骤和可执行校验动作。", confidence: 0.90, sourceKind: sourceKind)
            ]
        case "browser.page_idle":
            return [
                MemoryCandidate(category: .workflow, text: "浏览网页停留时，优先提取命令、依赖检查或下一步动作，不做摘要。", confidence: 0.88, sourceKind: sourceKind)
            ]
        case "selection.intent":
            return [
                MemoryCandidate(category: .workflow, text: "复制或选中内容后，优先提取可操作对象：错误、命令、配置、回复草稿或补丁草案。", confidence: 0.90, sourceKind: sourceKind)
            ]
        case "terminal.context_idle":
            return [
                MemoryCandidate(category: .workflow, text: "终端停留后，优先做报错诊断、环境校验、重跑命令或生成补丁。", confidence: 0.88, sourceKind: sourceKind)
            ]
        case "risk.operation_detected":
            return [
                MemoryCandidate(category: .constraint, text: "遇到高风险命令时，先给安全替代方案、dry-run 和确认清单。", confidence: 0.94, sourceKind: sourceKind)
            ]
        default:
            return []
        }
    }

    private static func unique(_ candidates: [MemoryCandidate]) -> [MemoryCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.category.rawValue)|\(MemorySanitizer.normalized(candidate.text))"
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }
}

private enum MemorySanitizer {
    static func sanitizeForMemory(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        guard !containsHardSecret(trimmed) else {
            return nil
        }

        var sanitized = trimmed
        sanitized = replacing(pattern: #"(?s)```.*?```"#, in: sanitized, with: "<code block>")
        sanitized = replacing(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, in: sanitized, with: "<email>")
        sanitized = replacing(pattern: #"https?://[^\s\]\)>"']+"#, in: sanitized, with: "<url>")
        sanitized = replacing(pattern: #"(?:(?:/|~\/|\./|\.\./)[A-Za-z0-9_@%+=:,. \-\/]+)"#, in: sanitized, with: "<path>")
        sanitized = replacing(pattern: #"\b\d{9,}\b"#, in: sanitized, with: "<number>")
        sanitized = replacing(pattern: #"\s+"#, in: sanitized, with: " ")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return nil
        }
        return String(sanitized.prefix(900))
    }

    static func normalized(_ text: String) -> String {
        let lower = text.lowercased()
        let compact = replacing(pattern: #"[^a-z0-9\u{4e00}-\u{9fff}]+"#, in: lower, with: " ")
        return compact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsHardSecret(_ text: String) -> Bool {
        let patterns = [
            #"(?i)\bsk-[A-Za-z0-9]{20,}\b"#,
            #"(?i)\bgh[pousr]_[A-Za-z0-9_]{20,}\b"#,
            #"(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,
            #"(?i)\bAKIA[0-9A-Z]{16}\b"#,
            #"(?i)-----BEGIN [A-Z ]+PRIVATE KEY-----"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._\-=/+]{16,}\b"#,
            #"(?i)\b(api key|token|secret|password|passwd|passcode|otp|verification code|验证码|密码)\b\s*[:=]\s*[^,\s]{6,}"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
}
