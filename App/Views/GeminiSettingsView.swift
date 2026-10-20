import SwiftUI

/// Gemini credentials, model catalog, and model-specific thinking controls.
struct GeminiSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showAPIKey = false
    @State private var models: [GeminiModel] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?
    @State private var catalogRevision = 0
    @State private var catalogKey: String?
    @State private var customModelName = ""
    @FocusState private var isCustomModelFocused: Bool

    private struct CatalogRequest: Equatable {
        let apiKey: String
        let revision: Int
    }

    private var catalogRequest: CatalogRequest {
        CatalogRequest(
            apiKey: settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            revision: catalogRevision
        )
    }

    private var supportedEfforts: [GeminiThinkingEffort] {
        GeminiThinkingEffort.supported(for: settings.geminiModelName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gemini API Key")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Label(catalogRequest.apiKey.isEmpty ? "未入力" : "入力済",
                      systemImage: catalogRequest.apiKey.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(catalogRequest.apiKey.isEmpty ? .orange : .green)
            }
            HStack {
                Group {
                    if showAPIKey {
                        TextField("AIza...", text: $settings.geminiAPIKey)
                    } else {
                        SecureField("AIza...", text: $settings.geminiAPIKey)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showAPIKey ? "APIキーを隠す" : "APIキーを表示")
            }
            .textFieldStyle(.roundedBorder)

            Link("Google AI StudioでAPIキーを取得", destination: URL(string: "https://aistudio.google.com/apikey")!)
                .font(.caption)

            Divider()

            HStack {
                Text("使用モデル")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    catalogRevision += 1
                } label: {
                    Label("一覧を更新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(catalogRequest.apiKey.isEmpty || isLoadingModels)
            }

            Picker("モデル", selection: $settings.geminiModelName) {
                // Keep a saved/custom model selectable even before the catalog loads.
                if !models.contains(where: { $0.id == settings.geminiModelName }) {
                    Text(settings.geminiModelName.isEmpty ? "モデル未選択" : settings.geminiModelName)
                        .tag(settings.geminiModelName)
                }
                ForEach(models) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .pickerStyle(.menu)

            if isLoadingModels {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("モデル一覧を取得中…").font(.caption)
                }
            }
            if let modelsError {
                Text(modelsError)
                    .font(.caption)
                    .foregroundColor(.red)
                if !models.isEmpty {
                    Text("更新前の一覧を表示しています。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            DisclosureGroup("モデルIDを直接入力") {
                TextField(GeminiInference.defaultModel, text: $customModelName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isCustomModelFocused)
                    .onSubmit { applyCustomModel() }
                Text("一覧にないモデルもIDで指定できます。利用できるモデルはAPIキーや提供状況によって異なります。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            Picker("推論 Effort", selection: Binding(
                get: {
                    supportedEfforts.contains(settings.geminiThinkingEffort) ? settings.geminiThinkingEffort : .automatic
                },
                set: { settings.geminiThinkingEffort = $0 }
            )) {
                ForEach(supportedEfforts) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
            .pickerStyle(.menu)

            Text("自動はモデルの標準設定を使用します。Effortが高いほど応答時間・利用料金が増える場合があります。Gemini 2.5では推論トークン量、Gemini 3以降ではThinking Levelを指定します。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: catalogRequest) {
            guard !Task.isCancelled else { return }
            let request = catalogRequest
            // Never keep another key's catalog, but retain this key's list if
            // an explicit refresh fails or is cancelled.
            if catalogKey != request.apiKey {
                models = []
                catalogKey = request.apiKey
            }
            modelsError = nil
            isLoadingModels = false
            guard !request.apiKey.isEmpty else { return }
            // Debounce key entry; changing the key cancels the previous request.
            do {
                try await Task.sleep(for: .milliseconds(800))
                try Task.checkCancellation()
                isLoadingModels = true
                defer {
                    if !Task.isCancelled { isLoadingModels = false }
                }
                let fetched = try await GeminiInference.fetchModels(apiKey: request.apiKey)
                try Task.checkCancellation()
                guard catalogRequest == request else { return }
                models = fetched
                if fetched.isEmpty {
                    modelsError = "利用可能な対話モデルがありません。APIキーの権限を確認するか、モデルIDを直接入力してください。"
                }
            } catch {
                guard !Task.isCancelled, catalogRequest == request else { return }
                modelsError = error.localizedDescription
            }
        }
        .onChange(of: settings.geminiModelName) { _, _ in
            if !isCustomModelFocused { customModelName = settings.geminiModelName }
            if !supportedEfforts.contains(settings.geminiThinkingEffort) {
                settings.geminiThinkingEffort = .automatic
            }
        }
        .onChange(of: isCustomModelFocused) { _, focused in
            if !focused { applyCustomModel() }
        }
        .onAppear {
            customModelName = settings.geminiModelName
            if !supportedEfforts.contains(settings.geminiThinkingEffort) {
                settings.geminiThinkingEffort = .automatic
            }
        }
        .onDisappear {
            if isCustomModelFocused { applyCustomModel() }
        }
    }

    private func applyCustomModel() {
        let model = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.geminiModelName = model
        customModelName = model
    }
}
