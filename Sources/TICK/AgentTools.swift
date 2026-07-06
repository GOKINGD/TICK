import AppKit
import Foundation

struct TickSkillConfig: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var instruction: String
    var directoryPath: String? = nil
}

struct TickMCPServerConfig: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var transport: String
    var endpoint: String
    var command: String
    var authorizationHeader: String
}

struct TickHookConfig: Codable, Equatable, Identifiable {
    var id: String { event }
    var event: String
    var description: String
    var command: String
}

struct AgentToolConfiguration: Codable, Equatable {
    var maxIterations: Int
    var skills: [TickSkillConfig]
    var mcpServers: [TickMCPServerConfig]
    var hooks: [TickHookConfig]

    static let defaultConfiguration = AgentToolConfiguration(
        maxIterations: 4,
        skills: [],
        mcpServers: [],
        hooks: [
            TickHookConfig(event: "before_tool", description: "Runs before a tool is executed.", command: ""),
            TickHookConfig(event: "after_tool", description: "Runs after a tool result is available.", command: ""),
            TickHookConfig(event: "after_response", description: "Runs after the final answer is produced.", command: "")
        ]
    )

    var normalized: AgentToolConfiguration {
        AgentToolConfiguration(
            maxIterations: min(max(maxIterations, 1), 8),
            skills: skills.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            mcpServers: mcpServers.filter { $0.isUsable },
            hooks: hooks.filter { !$0.event.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    var systemPromptContext: String {
        let skillLines = skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let usableMCPServers = mcpServers.filter(\.isUsable)
        let mcpLines = usableMCPServers.map { "- \($0.name) (\($0.transport))" }.joined(separator: "\n")
        let mcpContext = usableMCPServers.isEmpty
            ? ""
            : """

        Configured MCP servers are available through tick_mcp when useful:
        \(mcpLines)
        """

        return """
        TICK has Claude Code-style skills. Use them only when they materially improve the answer.
        - Only the skill name and description are available before activation.
        - Treat each description as the trigger condition.
        - First compare the user's request against installed skill descriptions.
        - If one local skill description matches, call tick_skill with action="load" for that skill before using it.
        - If a loaded skill asks you to run one of its bundled scripts, call tick_skill again with action="run_script" and the script path.
        - Use skill-recommender only when no installed local skill is appropriate and a remote skill may help.
        Installed skills:
        \(skillLines.isEmpty ? "- none configured" : skillLines)
        \(mcpContext)
        After a tool result is returned, continue reasoning from the result and produce a final answer when no more tools are needed.
        """
    }

    var definitions: [[String: Any]] {
        let usableMCPServers = mcpServers.filter(\.isUsable)
        return [skillDefinition] + (usableMCPServers.isEmpty ? [] : [mcpDefinition(servers: usableMCPServers)])
    }

    private var skillDefinition: [String: Any] {
        [
            "name": "tick_skill",
            "description": "Load and apply a configured TICK skill. Available skills: \(names(skills.map(\.name))).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "name": enumSchema(values: skills.map(\.name), fallbackDescription: "Skill name."),
                    "input": [
                        "type": "string",
                        "description": "Natural language input for the skill."
                    ],
                    "action": [
                        "type": "string",
                        "enum": ["load", "run_script"],
                        "description": "Use load to read SKILL.md after a description match. Use run_script only after SKILL.md instructs you to run a bundled script."
                    ],
                    "script": [
                        "type": "string",
                        "description": "Bundled script path such as scripts/fetch_skills.py. Required for action=run_script."
                    ],
                    "arguments": [
                        "type": "object",
                        "description": "Arguments for the bundled script. Use {\"args\":[...]} for positional CLI arguments."
                    ]
                ],
                "required": ["name", "input"]
            ]
        ]
    }

    private func mcpDefinition(servers: [TickMCPServerConfig]) -> [String: Any] {
        [
            "name": "tick_mcp",
            "description": "Call a configured MCP server tool. Available MCP servers: \(names(servers.map(\.name))).",
            "input_schema": [
                "type": "object",
                "properties": [
                    "server": enumSchema(values: servers.map(\.name), fallbackDescription: "Configured MCP server name."),
                    "tool": [
                        "type": "string",
                        "description": "Tool name on the MCP server."
                    ],
                    "input": [
                        "type": "object",
                        "description": "JSON input object for the MCP tool."
                    ]
                ],
                "required": ["server", "tool", "input"]
            ]
        ]
    }

    private func enumSchema(values: [String], fallbackDescription: String) -> [String: Any] {
        let cleanValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleanValues.isEmpty {
            return [
                "type": "string",
                "description": fallbackDescription
            ]
        }

        return [
            "type": "string",
            "enum": cleanValues,
            "description": fallbackDescription
        ]
    }

    private func names(_ values: [String]) -> String {
        let cleanValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleanValues.isEmpty ? "none" : cleanValues.joined(separator: ", ")
    }
}

private extension TickMCPServerConfig {
    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
         !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

enum ToolFileSystem {
    static var rootURL: URL {
        TICKRuntime.toolsURL
    }

    static var skillsURL: URL {
        let url = rootURL.appendingPathComponent("skills", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    static var mcpURL: URL {
        let url = rootURL.appendingPathComponent("mcp", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    static var hooksURL: URL {
        let url = rootURL.appendingPathComponent("hooks", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    static func ensureDirectory(_ url: URL) {
        TICKRuntime.ensureDirectory(url)
    }
}

enum SkillScanner {
    static func installedSkills() -> [TickSkillConfig] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: ToolFileSystem.skillsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var seen = Set<String>()
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            guard let skill = skill(at: url), !seen.contains(skill.name) else {
                return nil
            }
            seen.insert(skill.name)
            return skill
        }
        .sorted { $0.name < $1.name }
    }

    static func skill(at directory: URL) -> TickSkillConfig? {
        let skillURL = directory.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return nil
        }

        let parsed = parseSkillMarkdown(text)
        guard let rawName = parsed.frontmatter["name"],
              let rawDescription = parsed.frontmatter["description"] else {
            return nil
        }

        let name = normalizeSkillName(rawName)
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty else {
            return nil
        }

        return TickSkillConfig(
            name: name,
            description: description,
            instruction: parsed.body,
            directoryPath: directory.path
        )
    }

    static func readSkillMarkdown(_ skill: TickSkillConfig) -> String {
        guard let directoryPath = skill.directoryPath else {
            return skill.instruction
        }

        let skillURL = URL(fileURLWithPath: directoryPath).appendingPathComponent("SKILL.md")
        return (try? String(contentsOf: skillURL, encoding: .utf8)) ?? skill.instruction
    }

    static func importSkill(from sourceURL: URL) throws -> TickSkillConfig {
        let preparedURL = try preparedSkillDirectory(from: sourceURL)
        guard let importedSkill = skill(at: preparedURL) else {
            throw ToolInstallError.invalidSkill("Missing valid SKILL.md with name and description.")
        }

        let destination = ToolFileSystem.skillsURL.appendingPathComponent(importedSkill.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: preparedURL, to: destination)
        return skill(at: destination) ?? importedSkill
    }

    static func installGeneratedSkill(name: String, description: String, instruction: String) throws -> TickSkillConfig {
        let cleanName = normalizeSkillName(name)
        guard !cleanName.isEmpty else {
            throw ToolInstallError.invalidSkill("Skill name is empty.")
        }

        let destination = ToolFileSystem.skillsURL.appendingPathComponent(cleanName, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let markdown = """
        ---
        name: \(cleanName)
        description: \(description.replacingOccurrences(of: "\n", with: " "))
        ---
        \(instruction)
        """
        try markdown.write(to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        guard let skill = skill(at: destination) else {
            throw ToolInstallError.invalidSkill("Generated skill could not be read.")
        }
        return skill
    }

    private static func preparedSkillDirectory(from sourceURL: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ToolInstallError.invalidSkill("File does not exist.")
        }

        if isDirectory.boolValue {
            return sourceURL
        }

        if sourceURL.pathExtension.lowercased() == "zip" {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tick-skill-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let result = AgentToolExecutor.runCommandSynchronously("unzip -q \(shellQuote(sourceURL.path)) -d \(shellQuote(destination.path))", input: "")
            guard result.success else {
                throw ToolInstallError.invalidSkill(result.output)
            }
            return try findSkillDirectory(in: destination)
        }

        if sourceURL.lastPathComponent == "SKILL.md" {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tick-skill-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destination.appendingPathComponent("SKILL.md"))
            return destination
        }

        throw ToolInstallError.invalidSkill("Choose a skill folder, a SKILL.md file, or a .zip archive.")
    }

    private static func findSkillDirectory(in root: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) {
            return root
        }

        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if FileManager.default.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) {
                return entry
            }
        }
        throw ToolInstallError.invalidSkill("No SKILL.md found in archive.")
    }

    private static func parseSkillMarkdown(_ text: String) -> (frontmatter: [String: String], body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], text)
        }

        var frontmatter: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                let body = lines.dropFirst(index + 1).joined(separator: "\n")
                return (frontmatter, body)
            }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                frontmatter[key] = value
            }
            index += 1
        }

        return (frontmatter, text)
    }

    static func normalizeSkillName(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum ToolInstallError: LocalizedError {
    case invalidSkill(String)

    var errorDescription: String? {
        switch self {
        case .invalidSkill(let message):
            return message
        }
    }
}

@MainActor
final class AgentToolConfigurationStore: ObservableObject {
    @Published private(set) var configuration: AgentToolConfiguration
    @Published var maxIterations: Int
    @Published private(set) var skills: [TickSkillConfig]
    @Published private(set) var mcpServers: [TickMCPServerConfig]
    @Published private(set) var hooks: [TickHookConfig]
    @Published var statusMessage = ""

    init() {
        let loaded = Self.loadConfiguration()
        configuration = loaded
        maxIterations = loaded.maxIterations
        skills = loaded.skills
        mcpServers = loaded.mcpServers
        hooks = loaded.hooks
    }

    func save() {
        let parsed = AgentToolConfiguration(
            maxIterations: maxIterations,
            skills: SkillScanner.installedSkills(),
            mcpServers: mcpServers,
            hooks: hooks
        ).normalized
        guard AgentToolPersistence.save(parsed) else {
            statusMessage = "Save failed"
            return
        }

        apply(parsed)
        statusMessage = "Saved"
        traceLog("tools.save", "skills=\(parsed.skills.count)\nmcp=\(parsed.mcpServers.count)\nhooks=\(parsed.hooks.count)\nmaxIterations=\(parsed.maxIterations)")
    }

    func reset() {
        let defaults = AgentToolConfiguration(
            maxIterations: AgentToolConfiguration.defaultConfiguration.maxIterations,
            skills: SkillScanner.installedSkills(),
            mcpServers: [],
            hooks: AgentToolConfiguration.defaultConfiguration.hooks
        )
        apply(defaults.normalized)
        statusMessage = "Reset"
    }

    func refreshFromDiskForRequest() -> AgentToolConfiguration {
        let refreshed = configurationByScanningDisk(save: false)
        apply(refreshed)
        return refreshed
    }

    func refresh() {
        let refreshed = configurationByScanningDisk(save: true)
        apply(refreshed)
        statusMessage = "Refreshed"
    }

    func importSkill(from url: URL) {
        do {
            let skill = try SkillScanner.importSkill(from: url)
            refresh()
            save()
            statusMessage = "Added \(skill.name)"
            traceLog("tools.skill.import", "name=\(skill.name)\npath=\(skill.directoryPath ?? "")")
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            traceLog("tools.skill.error", statusMessage)
        }
    }

    func addMCPServer(name: String, transport: String, endpoint: String, command: String, authorizationHeader: String) {
        let server = TickMCPServerConfig(name: name, transport: transport, endpoint: endpoint, command: command, authorizationHeader: authorizationHeader)
        guard server.isUsable else {
            statusMessage = "MCP needs endpoint or command"
            return
        }

        mcpServers.removeAll { $0.name == server.name }
        mcpServers.append(server)
        save()
    }

    func addHook(event: String, description: String, command: String) {
        let hook = TickHookConfig(event: event, description: description, command: command)
        hooks.removeAll { $0.event == hook.event }
        hooks.append(hook)
        save()
    }

    func openToolsFolder() {
        NSWorkspace.shared.open(ToolFileSystem.rootURL)
    }

    private func configurationByScanningDisk(save shouldSave: Bool) -> AgentToolConfiguration {
        let refreshed = Self.mergedWithBuiltIns(
            AgentToolConfiguration(
                maxIterations: maxIterations,
                skills: SkillScanner.installedSkills(),
                mcpServers: mcpServers,
                hooks: hooks
            )
            .normalized
        )
        if shouldSave {
            AgentToolPersistence.save(refreshed)
        }
        return refreshed
    }

    private static func loadConfiguration() -> AgentToolConfiguration {
        let diskSkills = SkillScanner.installedSkills()
        guard let saved = AgentToolPersistence.load() else {
            let defaults = AgentToolConfiguration(
                maxIterations: AgentToolConfiguration.defaultConfiguration.maxIterations,
                skills: diskSkills,
                mcpServers: [],
                hooks: AgentToolConfiguration.defaultConfiguration.hooks
            )
            AgentToolPersistence.save(defaults.normalized)
            return defaults
        }

        let merged = mergedWithBuiltIns(
            AgentToolConfiguration(
                maxIterations: saved.maxIterations,
                skills: diskSkills,
                mcpServers: saved.mcpServers,
                hooks: saved.hooks
            )
            .normalized
        )
        AgentToolPersistence.save(merged)
        return merged
    }

    private static func mergedWithBuiltIns(_ configuration: AgentToolConfiguration) -> AgentToolConfiguration {
        var merged = configuration
        for builtInHook in AgentToolConfiguration.defaultConfiguration.hooks where !merged.hooks.contains(where: { $0.event == builtInHook.event }) {
            merged.hooks.append(builtInHook)
        }
        return merged.normalized
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return try JSONDecoder().decode(type, from: data)
    }

    private static func prettyJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private func apply(_ configuration: AgentToolConfiguration) {
        self.configuration = configuration
        maxIterations = configuration.maxIterations
        skills = configuration.skills
        mcpServers = configuration.mcpServers
        hooks = configuration.hooks
    }
}

enum AgentToolPersistence {
    static let defaultsKey = "tick.agent.tools"
    static let fileName = "config.json"

    static func load() -> AgentToolConfiguration? {
        let fileURL = ToolFileSystem.rootURL.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: fileURL),
           let configuration = try? JSONDecoder().decode(AgentToolConfiguration.self, from: data) {
            return configuration
        }

        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let configuration = try? JSONDecoder().decode(AgentToolConfiguration.self, from: data) else {
            return nil
        }
        return configuration
    }

    @discardableResult
    static func save(_ configuration: AgentToolConfiguration) -> Bool {
        let fileURL = ToolFileSystem.rootURL.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let persisted = AgentToolConfiguration(
            maxIterations: configuration.maxIterations,
            skills: configuration.skills.map {
                TickSkillConfig(
                    name: $0.name,
                    description: $0.description,
                    instruction: "",
                    directoryPath: $0.directoryPath
                )
            },
            mcpServers: configuration.mcpServers,
            hooks: configuration.hooks
        )
        guard let data = try? encoder.encode(persisted) else {
            return false
        }
        do {
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    static func installSkill(_ skill: TickSkillConfig, into configuration: AgentToolConfiguration) -> AgentToolConfiguration {
        _ = try? SkillScanner.installGeneratedSkill(name: skill.name, description: skill.description, instruction: skill.instruction)
        return configurationByScanningDisk(from: configuration)
    }

    static func configurationByScanningDisk(from configuration: AgentToolConfiguration) -> AgentToolConfiguration {
        let updated = AgentToolConfiguration(
            maxIterations: configuration.maxIterations,
            skills: SkillScanner.installedSkills(),
            mcpServers: configuration.mcpServers,
            hooks: configuration.hooks
        ).normalized
        save(updated)
        return updated
    }
}

struct AgentThought: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
}

struct AgentToolExecution: Identifiable, Codable, Equatable {
    var id = UUID()
    var toolUseID: String
    var name: String
    var kind: String
    var input: String
    var output: String
    var success: Bool
    var updatedConfiguration: AgentToolConfiguration?

    init(id: UUID = UUID(), toolUseID: String, name: String, kind: String, input: String, output: String, success: Bool, updatedConfiguration: AgentToolConfiguration? = nil) {
        self.id = id
        self.toolUseID = toolUseID
        self.name = name
        self.kind = kind
        self.input = input
        self.output = output
        self.success = success
        self.updatedConfiguration = updatedConfiguration
    }
}

struct AgentRunResult: Codable, Equatable {
    var finalText: String
    var thoughts: [AgentThought]
    var toolExecutions: [AgentToolExecution]
    var usage: LLMTokenUsage?
}

struct AgentLoop {
    static func run(
        transcript: [AgentMessage],
        settings: LLMSettings,
        apiKey: String,
        toolConfiguration: AgentToolConfiguration
    ) async throws -> AgentRunResult {
        var configuration = toolConfiguration.normalized
        let requestConfiguration = configuration
        let usesAnthropicShape = LLMClient.usesAnthropicToolShape(model: settings.model)
        var messages = LLMClient.messages(from: transcript, toolConfiguration: requestConfiguration)
        var thoughts: [AgentThought] = []
        var executions: [AgentToolExecution] = []
        var totalUsage = LLMTokenUsage.empty

        traceLog("agent.loop.start", "model=\(settings.model)\nmaxIterations=\(configuration.maxIterations)")

        for iteration in 1...configuration.maxIterations {
                let response = try await LLMClient.send(
                    messages: messages,
                    settings: settings,
                    apiKey: apiKey,
                    toolConfiguration: requestConfiguration
                )
            totalUsage.merge(response.usage)

            if response.toolUses.isEmpty {
                let finalText = response.displayText
                thoughts.append(AgentThought(title: "Step \(iteration)", detail: "Final answer ready."))
                traceLog("agent.loop.done", "iterations=\(iteration)\ntools=\(executions.count)\nfinal=\(finalText)", tokenUsage: totalUsage)
                _ = await AgentToolExecutor.runHook(event: "after_response", payload: ["final": finalText], configuration: configuration)
                return AgentRunResult(finalText: finalText, thoughts: thoughts, toolExecutions: executions, usage: totalUsage)
            }

            let toolNames = response.toolUses.map(\.name).joined(separator: ", ")
            let detail = response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Requested tools: \(toolNames)."
                : "\(response.text)\nRequested tools: \(toolNames)."
            thoughts.append(AgentThought(title: "Step \(iteration)", detail: detail))
            traceLog("agent.loop.tools", "iteration=\(iteration)\ntools=\(toolNames)")

            messages.append(assistantToolMessage(from: response, usesAnthropicShape: usesAnthropicShape))
            var iterationExecutions: [AgentToolExecution] = []
            for toolUse in response.toolUses {
                let beforeHookExecutions = await AgentToolExecutor.runHook(event: "before_tool", payload: ["tool": toolUse.name, "input": toolUse.input], configuration: configuration)
                executions += beforeHookExecutions
                let execution = await AgentToolExecutor.execute(toolUse, configuration: configuration)
                if let updatedConfiguration = execution.updatedConfiguration {
                    configuration = updatedConfiguration.normalized
                }
                executions.append(execution)
                iterationExecutions.append(execution)
                traceLog("tool.execute", "\(execution.kind) \(execution.name)\nsuccess=\(execution.success)\ninput=\(execution.input)\noutput=\(execution.output)")
                let afterHookExecutions = await AgentToolExecutor.runHook(event: "after_tool", payload: ["tool": execution.name, "success": execution.success, "output": execution.output], configuration: configuration)
                executions += afterHookExecutions
            }
            messages += toolResultMessages(from: iterationExecutions, usesAnthropicShape: usesAnthropicShape)
        }

        let finalText = "Stopped after \(configuration.maxIterations) tool loop iterations. Check the tool results above."
        thoughts.append(AgentThought(title: "Stopped", detail: "The loop reached its configured iteration limit."))
        traceLog("agent.loop.limit", "maxIterations=\(configuration.maxIterations)\ntools=\(executions.count)", tokenUsage: totalUsage)
        return AgentRunResult(finalText: finalText, thoughts: thoughts, toolExecutions: executions, usage: totalUsage)
    }

    private static func assistantToolMessage(from response: LLMResponse, usesAnthropicShape: Bool) -> [String: Any] {
        if usesAnthropicShape {
            var content: [[String: Any]] = []
            if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content.append([
                    "type": "text",
                    "text": response.text
                ])
            }
            content += response.toolUses.map { toolUse in
                [
                    "type": "tool_use",
                    "id": toolUse.id,
                    "name": toolUse.name,
                    "input": jsonObject(from: toolUse.input) ?? [:]
                ]
            }
            return [
                "role": "assistant",
                "content": content
            ]
        }

        return [
            "role": "assistant",
            "content": response.text,
            "tool_calls": response.toolUses.map { toolUse in
                [
                    "id": toolUse.id,
                    "type": "function",
                    "function": [
                        "name": toolUse.name,
                        "arguments": toolUse.input
                    ]
                ]
            }
        ]
    }

    private static func toolResultMessages(from executions: [AgentToolExecution], usesAnthropicShape: Bool) -> [[String: Any]] {
        if usesAnthropicShape {
            return [
                [
                    "role": "user",
                    "content": executions.map { execution in
                        [
                            "type": "tool_result",
                            "tool_use_id": execution.toolUseID,
                            "content": execution.output,
                            "is_error": !execution.success
                        ]
                    }
                ]
            ]
        }

        return executions.map { execution in
            [
                "role": "tool",
                "tool_call_id": execution.toolUseID,
                "name": execution.name,
                "content": execution.output
            ]
        }
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object
    }
}

enum AgentToolExecutor {
    static func execute(_ toolUse: LLMToolUse, configuration: AgentToolConfiguration) async -> AgentToolExecution {
        switch toolUse.name {
        case "tick_skill":
            return executeSkill(toolUse, configuration: configuration)
        case "tick_mcp":
            return await executeMCP(toolUse, configuration: configuration)
        default:
            return AgentToolExecution(
                toolUseID: toolUse.id,
                name: toolUse.name,
                kind: "Tool",
                input: toolUse.input,
                output: "未知或当前不可用的 TICK 工具：\(toolUse.name)。",
                success: false
            )
        }
    }

    static func runHook(event: String, payload: [String: Any], configuration: AgentToolConfiguration) async -> [AgentToolExecution] {
        let matchingHooks = configuration.hooks.filter { $0.event == event }
        var executions: [AgentToolExecution] = []
        for hook in matchingHooks {
            let command = hook.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                continue
            }

            let input = jsonString(payload)
            let result = await runCommand(command, input: input)
            let output = result.output
            let success = result.success
            traceLog("hook.execute", "event=\(event)\nsuccess=\(success)\ncommand=\(hook.command)\ninput=\(input)\noutput=\(output)")
            executions.append(AgentToolExecution(toolUseID: "hook.\(event)", name: event, kind: "Hook", input: input, output: output, success: success))
        }
        return executions
    }

    private static func executeSkill(_ toolUse: LLMToolUse, configuration: AgentToolConfiguration) -> AgentToolExecution {
        let input = jsonDictionary(from: toolUse.input)
        let requestedName = input["name"] as? String ?? ""
        let name = SkillScanner.normalizeSkillName(requestedName)
        let skillInput = input["input"] as? String ?? ""
        let action = (input["action"] as? String ?? "load").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = configuration.skills.first(where: { $0.name == name }) else {
            return AgentToolExecution(
                toolUseID: toolUse.id,
                name: "tick_skill",
                kind: "Skill",
                input: toolUse.input,
                output: "未找到 skill：\(requestedName)。当前可用 skills：\(configuration.skills.map(\.name).joined(separator: ", ")).",
                success: false
            )
        }

        if action == "run_script" {
            return runSkillScriptTool(toolUse: toolUse, skill: skill, input: input, configuration: configuration)
        }

        return AgentToolExecution(
            toolUseID: toolUse.id,
            name: skill.name,
            kind: "Skill",
            input: toolUse.input,
            output: """
            Skill loaded: \(skill.name)
            Description: \(skill.description)
            SKILL.md:
            \(SkillScanner.readSkillMarkdown(skill))
            Files:
            \(skillFileSummary(skill))
            Input:
            \(skillInput)
            """,
            success: true
        )
    }

    private static func executeMCP(_ toolUse: LLMToolUse, configuration: AgentToolConfiguration) async -> AgentToolExecution {
        let input = jsonDictionary(from: toolUse.input)
        let requestedServer = input["server"] as? String ?? ""
        let toolName = (input["tool"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = input["input"] as? [String: Any] ?? [:]

        guard let server = configuration.mcpServers.first(where: { $0.name == requestedServer && $0.isUsable }) else {
            return AgentToolExecution(
                toolUseID: toolUse.id,
                name: "tick_mcp",
                kind: "MCP",
                input: toolUse.input,
                output: "未配置 MCP server：\(requestedServer)。当前可用 MCP servers：\(configuration.mcpServers.filter(\.isUsable).map(\.name).joined(separator: ", ")).",
                success: false
            )
        }

        guard !toolName.isEmpty else {
            return AgentToolExecution(
                toolUseID: toolUse.id,
                name: server.name,
                kind: "MCP",
                input: toolUse.input,
                output: "缺少 MCP tool 名称。",
                success: false
            )
        }

        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": payload
            ]
        ]

        let result: (output: String, success: Bool)
        if server.transport.lowercased() == "http" || !server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = await postJSON(to: server, body: requestBody)
        } else {
            let command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
            result = await runCommand(command, input: jsonString(requestBody))
        }

        return AgentToolExecution(
            toolUseID: toolUse.id,
            name: "\(server.name):\(toolName)",
            kind: "MCP",
            input: toolUse.input,
            output: result.output,
            success: result.success
        )
    }

    private static func runSkillScriptTool(toolUse: LLMToolUse, skill: TickSkillConfig, input: [String: Any], configuration: AgentToolConfiguration) -> AgentToolExecution {
        let script = (input["script"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            return AgentToolExecution(
                toolUseID: toolUse.id,
                name: skill.name,
                kind: "Skill",
                input: toolUse.input,
                output: "缺少脚本路径。请先 load 读取 SKILL.md，再按 SKILL.md 指令用 run_script 调用 bundled script，例如 scripts/fetch_skills.py。",
                success: false
            )
        }

        let arguments = input["arguments"] as? [String: Any] ?? [:]
        let scriptResult = runSkillScript(skill: skill, scriptPath: script, arguments: arguments)
        let updatedConfiguration: AgentToolConfiguration?
        if scriptResult.success && script.hasSuffix("install_skill.py") {
            updatedConfiguration = AgentToolPersistence.configurationByScanningDisk(from: configuration)
        } else {
            updatedConfiguration = nil
        }
        return AgentToolExecution(
            toolUseID: toolUse.id,
            name: "\(skill.name):\(script)",
            kind: "Skill",
            input: toolUse.input,
            output: scriptResult.output,
            success: scriptResult.success,
            updatedConfiguration: updatedConfiguration
        )
    }

    private static func runSkillScript(skill: TickSkillConfig, scriptPath: String, arguments: [String: Any]) -> (output: String, success: Bool) {
        guard let directoryPath = skill.directoryPath else {
            return ("该 skill 没有关联目录。", false)
        }

        guard !scriptPath.hasPrefix("/"),
              !scriptPath.components(separatedBy: "/").contains("..") else {
            return ("脚本路径不合法：\(scriptPath)", false)
        }

        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let normalizedScriptPath = scriptPath.hasPrefix("scripts/") ? scriptPath : "scripts/\(scriptPath)"
        let scriptURL = directoryURL.appendingPathComponent(normalizedScriptPath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            return ("找不到脚本：\(scriptURL.path)", false)
        }

        let positionalArguments = scriptArguments(for: normalizedScriptPath, arguments: arguments)
        let stdin = jsonString(arguments)
        let command = scriptCommand(for: scriptURL, arguments: positionalArguments)

        var environment = ProcessInfo.processInfo.environment
        environment["TICK_SKILLS_DIR"] = ToolFileSystem.skillsURL.path
        return runCommandSynchronously(command, input: stdin, environment: environment)
    }

    private static func scriptArguments(for scriptPath: String, arguments: [String: Any]) -> [String] {
        if let values = arguments["args"] as? [Any] {
            return values.map { "\($0)" }
        }

        let skillName = (arguments["skill_name"] as? String) ?? (arguments["name"] as? String)
        let downloadURL = (arguments["download_url"] as? String) ?? (arguments["url"] as? String)
        if scriptPath.hasSuffix("get_download_url.py"), let skillName {
            return [skillName]
        }
        if (scriptPath.hasSuffix("preview_skill.py") || scriptPath.hasSuffix("install_skill.py")),
           let skillName,
           let downloadURL {
            return [skillName, downloadURL]
        }
        return []
    }

    private static func scriptCommand(for scriptURL: URL, arguments: [String]) -> String {
        let quotedArgs = arguments.map(shellQuote).joined(separator: " ")
        let suffix = quotedArgs.isEmpty ? "" : " \(quotedArgs)"
        switch scriptURL.pathExtension.lowercased() {
        case "py":
            return "python3 \(shellQuote(scriptURL.path))\(suffix)"
        case "sh":
            return "bash \(shellQuote(scriptURL.path))\(suffix)"
        default:
            return "\(shellQuote(scriptURL.path))\(suffix)"
        }
    }

    private static func skillFileSummary(_ skill: TickSkillConfig) -> String {
        guard let directoryPath = skill.directoryPath else {
            return "No skill directory."
        }

        let directory = URL(fileURLWithPath: directoryPath)
        let groups = ["scripts", "references", "assets"].compactMap { folder -> String? in
            let folderURL = directory.appendingPathComponent(folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
            return "\(folder): \(names.isEmpty ? "empty" : names.joined(separator: ", "))"
        }
        return groups.isEmpty ? "No optional resource directories." : groups.joined(separator: "\n")
    }

    private static func postJSON(to server: TickMCPServerConfig, body: [String: Any]) async -> (output: String, success: Bool) {
        let endpoint = server.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint) else {
            return ("Invalid MCP endpoint: \(endpoint)", false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authorization = server.authorizationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if !authorization.isEmpty {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return ("Invalid MCP request JSON: \(error.localizedDescription)", false)
        }

        let rawBody = jsonString(body)
        traceLog(
            "mcp.http.start",
            "POST \(endpoint)\nserver=\(server.name)",
            rawHTTP: "POST \(endpoint)\nContent-Type: application/json\nAuthorization: \(authorization.isEmpty ? "<none>" : "<redacted>")\n\n\(rawBody)"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let output = String(data: data, encoding: .utf8) ?? ""
            traceLog("mcp.http.done", "status=\(statusCode)\nserver=\(server.name)", rawHTTP: output)
            return (output.isEmpty ? "MCP server returned no output." : output, (200..<300).contains(statusCode))
        } catch {
            traceLog("mcp.http.error", "server=\(server.name)\nerror=\(error.localizedDescription)")
            return (error.localizedDescription, false)
        }
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(value)"
        }
        return text
    }

    private static func runCommand(_ command: String, input: String) async -> (output: String, success: Bool) {
        await Task.detached {
            runCommandSynchronously(command, input: input)
        }
        .value
    }

    static func runCommandSynchronously(_ command: String, input: String, environment: [String: String]? = nil) -> (output: String, success: Bool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            if let environment {
                process.environment = environment
            }

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                if let data = input.data(using: .utf8) {
                    inputPipe.fileHandleForWriting.write(data)
                }
                try? inputPipe.fileHandleForWriting.close()

                let deadline = Date().addingTimeInterval(15)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    return ("Command timed out after 15 seconds.", false)
                }

                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [output, error].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
                return (combined.isEmpty ? "Command completed with no output." : combined, process.terminationStatus == 0)
            } catch {
                return (error.localizedDescription, false)
            }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func jsonDictionary(from text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }

        return dictionary
    }

}
