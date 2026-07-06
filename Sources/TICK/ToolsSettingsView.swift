import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolsSettingsView: View {
    @ObservedObject var store: AgentToolConfigurationStore
    let close: () -> Void

    @State private var selectedTab = "Skills"
    @State private var mcpName = ""
    @State private var mcpTransport = "command"
    @State private var mcpEndpoint = ""
    @State private var mcpCommand = ""
    @State private var mcpAuthorization = ""
    @State private var hookEvent = ""
    @State private var hookDescription = ""
    @State private var hookCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("", selection: $selectedTab) {
                Text("Skills").tag("Skills")
                Text("MCP").tag("MCP")
                Text("Hooks").tag("Hooks")
            }
            .pickerStyle(.segmented)

            content

            HStack {
                Text(store.statusMessage.isEmpty ? "Ready" : store.statusMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(store.statusMessage.contains("error") || store.statusMessage.contains("Missing") ? Color(red: 0.65, green: 0.20, blue: 0.14) : Color(red: 0.08, green: 0.42, blue: 0.35))

                Spacer()

                Button("Open Folder") {
                    store.openToolsFolder()
                }

                Button("Refresh") {
                    store.refresh()
                }

                Button("Done") {
                    store.save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(minWidth: 780, minHeight: 620)
        .background(Color(red: 0.94, green: 0.97, blue: 0.98))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("TICK Tools")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(ToolFileSystem.rootURL.path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            Stepper(value: $store.maxIterations, in: 1...8) {
                Text("Loop \(store.maxIterations)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .frame(width: 130)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case "MCP":
            mcpPane
        case "Hooks":
            hooksPane
        default:
            skillsPane
        }
    }

    private var skillsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Skills")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                Button("Add Skill") {
                    chooseSkill()
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.skills) { skill in
                        ToolRow(
                            title: skill.name,
                            subtitle: skill.description,
                            detail: skill.directoryPath ?? ToolFileSystem.skillsURL.appendingPathComponent(skill.name).path,
                            systemImage: "sparkle.magnifyingglass"
                        )
                    }
                }
            }
        }
    }

    private var mcpPane: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add MCP Server")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("MCP is exposed to the model only when at least one usable server is configured.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $mcpName)
                Picker("", selection: $mcpTransport) {
                    Text("Command").tag("command")
                    Text("HTTP").tag("http")
                }
                .pickerStyle(.segmented)
                TextField("Endpoint", text: $mcpEndpoint)
                TextField("Command", text: $mcpCommand)
                SecureField("Authorization header", text: $mcpAuthorization)
                Button("Add MCP") {
                    store.addMCPServer(name: mcpName, transport: mcpTransport, endpoint: mcpEndpoint, command: mcpCommand, authorizationHeader: mcpAuthorization)
                    mcpName = ""
                    mcpEndpoint = ""
                    mcpCommand = ""
                    mcpAuthorization = ""
                }
                .buttonStyle(.borderedProminent)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)

            toolList(title: "Configured MCP", rows: store.mcpServers.map { ($0.name, $0.transport, $0.endpoint.isEmpty ? $0.command : $0.endpoint, "server.rack") })
        }
    }

    private var hooksPane: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Hook")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("Hooks run from TICK lifecycle events, not as model-selected tools.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("Event", text: $hookEvent)
                TextField("Description", text: $hookDescription)
                TextField("Command", text: $hookCommand)
                Button("Add Hook") {
                    store.addHook(event: hookEvent, description: hookDescription, command: hookCommand)
                    hookEvent = ""
                    hookDescription = ""
                    hookCommand = ""
                }
                .buttonStyle(.borderedProminent)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)

            toolList(title: "Configured Hooks", rows: store.hooks.map { ($0.event, $0.description, $0.command.isEmpty ? "record only" : $0.command, "link") })
        }
    }

    private func toolList(title: String, rows: [(String, String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.0) { row in
                        ToolRow(title: row.0, subtitle: row.1, detail: row.2, systemImage: row.3)
                    }
                }
            }
        }
    }

    private func chooseSkill() {
        let panel = NSOpenPanel()
        panel.title = "Add TICK Skill"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "zip") ?? .archive
        ]

        if panel.runModal() == .OK,
           let url = panel.url {
            store.importSkill(from: url)
        }
    }
}

private struct ToolRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color(red: 0.09, green: 0.35, blue: 0.42))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.20, green: 0.27, blue: 0.31))
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
