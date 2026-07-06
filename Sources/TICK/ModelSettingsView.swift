import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject var store: LLMSettingsStore
    let close: () -> Void

    @State private var revealKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TICK")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.10, green: 0.16, blue: 0.20))
                    Text("OpenAI-compatible endpoint")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(text: store.isConfigured ? "Ready" : "Setup", ready: store.isConfigured)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Base URL")
                    TextField("https://your-provider.example/v1", text: $store.settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("API Key")
                    HStack(spacing: 8) {
                        if revealKey {
                            TextField("Paste API key", text: $store.apiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Required", text: $store.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(revealKey ? "Hide" : "Show") {
                            revealKey.toggle()
                        }

                        Button(store.isLoadingModels ? "Loading" : "Models") {
                            store.loadModels()
                        }
                        .disabled(store.isLoadingModels)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Model")
                    HStack(spacing: 8) {
                        Picker("", selection: $store.settings.model) {
                            if store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No model selected").tag("")
                            }
                            ForEach(store.availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                            if !store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               !store.availableModels.contains(store.settings.model) {
                                Text(store.settings.model).tag(store.settings.model)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 190)

                        TextField("Model name", text: $store.settings.model)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                }
            }

            HStack {
                Text(store.statusMessage.isEmpty ? store.missingConfigurationMessage : store.statusMessage)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(store.isConfigured ? Color(red: 0.08, green: 0.44, blue: 0.36) : Color(red: 0.64, green: 0.27, blue: 0.16))

                Spacer()

                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    store.save()
                    if store.isConfigured {
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 340)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.98, blue: 0.98),
                    Color(red: 0.91, green: 0.95, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

private struct StatusBadge: View {
    let text: String
    let ready: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(ready ? Color(red: 0.06, green: 0.34, blue: 0.28) : Color(red: 0.48, green: 0.30, blue: 0.10))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(ready ? Color(red: 0.72, green: 0.94, blue: 0.86) : Color(red: 0.98, green: 0.86, blue: 0.58))
            .clipShape(Capsule())
    }
}
