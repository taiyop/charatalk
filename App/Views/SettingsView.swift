import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
#if os(iOS) && canImport(IrodoriSpeechCpp)
import IrodoriSpeechCpp
#endif
#if os(iOS) && canImport(LlamaCpp)
import LlamaCpp
#endif

/// 設定画面のタブ種別
public enum SettingsTab: String, CaseIterable, Identifiable {
    case character = "キャラクター"
    case voice = "声・話し方"
    case connection = "接続・モデル"
    
    public var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .character: return "figure.stand"
        case .voice: return "waveform"
        case .connection: return "slider.horizontal.3"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject var settings: AppSettings = .shared
    @ObservedObject var ttsManager: SpeechTTSManager = .shared
    @ObservedObject var voiceManager: VoiceReferenceManager = .shared
    @ObservedObject var characterController: VRMCharacterController = .shared
    @ObservedObject var localLLM: LocalLLMManager = .shared
    @ObservedObject var chatGPTAuth: ChatGPTAuthManager = .shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: SettingsTab = .character
    
    // インポーター開閉状態
    @State private var showVRMImporter: Bool = false
    @State private var showAudioImporter: Bool = false
    @State private var showAPIKey: Bool = false
    
    // エラーメッセージ
    @State private var downloadError: String?
    @State private var localLLMDownloadError: String?
    @State private var referenceError: String?
    @State private var vrmError: String?
    
    // 段階的開示（Progressive Disclosure）の開閉状態
    @State private var isVoiceReferenceExpanded: Bool = false
    @State private var isAudioAdvancedExpanded: Bool = false
    @State private var isTtsConfigAdvancedExpanded: Bool = false
    @State private var isLLMAdvancedExpanded: Bool = false
    @State private var isChatGPTAdvancedExpanded: Bool = false
    @State private var isPromptEditorExpanded: Bool = false
    
    // VRM対応UTType定義
    private static let vrmContentTypes: [UTType] = [
        UTType("org.vrm-consortium.vrm"),
        UTType(filenameExtension: "vrm"),
        UTType(filenameExtension: "glb"),
        .data,
        .item
    ].compactMap { $0 }
    
    // 話し方プリセット
    private let captionPresets: [(label: String, caption: String)] = [
        ("落ち着いた", "落ち着いた、やさしい話し方。自然な抑揚で話す。"),
        ("明るく元気", "明るく元気で、ハキハキとした愛嬌のある話し方。"),
        ("知的・クール", "知的で落ち着いた、大人の女性の話し方。"),
        ("囁き声", "耳元で囁くようなウィスパーボイス。"),
        ("アニメ声", "アニメの可愛いキャラクター風の高めの声。"),
        ("標準", "")
    ]
    
    // 性格・プロンプトプリセット
    private let promptPresets: [(label: String, prompt: String)] = [
        ("親しみやすい", "あなたは親しみやすく親切なAIキャラクターです。明るく簡潔に日本語で返答してください。"),
        ("元気・フレンドリー", "あなたは元気いっぱいで明るいキャラクターです。タメ口でフレンドリーに、『〜だよ！』『〜ね！』をつけて楽しく話してください。"),
        ("知的・クール", "あなたは知的で落ち着いた相棒です。冷静かつ的確に、落ち着いた大人のトーンで会話してください。"),
        ("癒し系", "あなたは優しく包容力のあるキャラクターです。ユーザーを気遣い、温かい言葉遣いで優しくお話ししてください。")
    ]
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: - 最上部: セグメントコントロール（近接と整列）
                Picker("設定カテゴリ", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemGroupedBackground))
                
                Divider()
                
                // MARK: - メインコンテンツ
                Form {
                    switch selectedTab {
                    case .character:
                        characterSection
                    case .voice:
                        voiceSection
                    case .connection:
                        connectionSection
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        voiceManager.stopPreview()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(AppTheme.puppyPink)
                }
            }
            .tint(AppTheme.puppyPink)
        }
    }
    
    // =========================================================================
    // MARK: - 1. キャラクター設定 (VRM & 性格)
    // =========================================================================
    @ViewBuilder
    private var characterSection: some View {
        // --- 3Dアバターモデル ---
        Section {
            HStack(spacing: 14) {
                Image(systemName: characterController.hasCustomAvatar ? "person.crop.artframe" : "figure.stand")
                    .font(.title2)
                    .foregroundColor(AppTheme.puppyPink)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.puppyPink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(characterController.hasCustomAvatar ? "カスタムVRMモデル" : "デフォルトアバター")
                        .font(.headline)
                    Text(characterController.hasCustomAvatar ? "インポートしたモデルを適用中" : "vrm_sample（作者：taiyop）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if characterController.hasCustomAvatar {
                    Label("適用中", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
            
            // アクションボタン
            VStack(spacing: 8) {
                Button {
                    showVRMImporter = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text(characterController.hasCustomAvatar ? "別のVRMファイルに変更" : "カスタムVRMファイルを読み込む")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.puppyPink)
                .disabled(characterController.isLoading)
                // ファイルピッカー（ボタン直下に配置しスコープ競合を防止）
                .fileImporter(
                    isPresented: $showVRMImporter,
                    allowedContentTypes: Self.vrmContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first {
                            vrmError = nil
                            Task {
                                do {
                                    try await characterController.importCustomAvatar(from: url)
                                    dismiss()
                                } catch {
                                    vrmError = error.localizedDescription
                                }
                            }
                        }
                    case .failure(let error):
                        vrmError = "ファイル選択エラー: \(error.localizedDescription)"
                    }
                }
                
                if characterController.hasCustomAvatar {
                    Button(role: .destructive) {
                        Task {
                            await characterController.resetToDefaultAvatar()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("デフォルトモデルに戻す")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(characterController.isLoading)
                }
            }
            .padding(.vertical, 4)
            
            if characterController.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("3Dモデルを読み込んでいます…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let err = vrmError ?? characterController.loadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Label("3Dアバター", systemImage: "cube.fill")
        } footer: {
            Text("VRM 0.0 / 1.0 形式の3Dキャラクターモデルファイルを読み込んで利用できます。標準のvrm_sampleは個人の非営利利用のみです。")
                .font(.caption2)
        }
        
        // --- デフォルト視点 (カメラ配置) ---
        Section {
            HStack(spacing: 14) {
                Image(systemName: characterController.hasCustomDefaultTransform ? "pin.circle.fill" : "camera.viewfinder")
                    .font(.title2)
                    .foregroundColor(AppTheme.puppyPink)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.puppyPink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(characterController.hasCustomDefaultTransform ? "カスタム視点（保存済み）" : "標準視点（初期位置）")
                        .font(.headline)
                    let zoomPercent = Int((characterController.defaultScale * 100).rounded())
                    let angleDeg = Int((characterController.defaultRotationY * 180 / .pi).rounded())
                    Text("ズーム: \(zoomPercent)% / 回転: \(angleDeg)°")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if characterController.hasCustomDefaultTransform {
                    Label("保存済", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
            
            if characterController.isTransformed {
                Button {
                    characterController.saveCurrentTransformAsDefault()
                } label: {
                    HStack {
                        Image(systemName: "pin.fill")
                        Text("現在の視点をデフォルトとして保存")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.puppyPink)
            }
            
            if characterController.hasCustomDefaultTransform {
                Button(role: .destructive) {
                    characterController.resetDefaultTransformToFactory()
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("デフォルト視点を初期位置に戻す")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        } header: {
            Label("デフォルト視点", systemImage: "camera.fill")
        } footer: {
            Text("メイン画面でピンチ（拡大・縮小）やスワイプ（回転・高さ調整）した際、右上に表示される「デフォルトとして保存」から好きなアングルを初期視点として記憶できます。")
                .font(.caption2)
        }
        
        // --- キャラクターの性格 (System Prompt) ---
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("性格プリセット:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(promptPresets, id: \.label) { preset in
                            let isSelected = settings.systemPrompt == preset.prompt
                            Button(preset.label) {
                                settings.systemPrompt = preset.prompt
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(isSelected ? AppTheme.puppyPink : .secondary)
                            .font(.caption)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            
            // 段階的開示: プロンプトの詳細直接編集
            DisclosureGroup(isExpanded: $isPromptEditorExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $settings.systemPrompt)
                        .frame(minHeight: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    Text("キャラクターの口調、設定、ルールなどを自由に指示できます。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Image(systemName: "pencil.line")
                        .foregroundColor(.secondary)
                    Text("プロンプトを直接編集する")
                        .font(.subheadline)
                }
            }
        } header: {
            Label("キャラクターの性格・対話スタイル", systemImage: "sparkles")
        }
    }
    
    // =========================================================================
    // MARK: - 2. 声・話し方設定 (Voice & TTS)
    // =========================================================================
    @ViewBuilder
    private var voiceSection: some View {
        // --- 音声対話 (SpeechAnalyzer / SileroVAD) ---
        Section {
            Toggle(isOn: $settings.isHandsFreeMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ハンズフリー対話モード")
                        .font(.subheadline)
                    Text("返答が終わると自動でマイクが再開し、画面タップ不要で会話を続けられます")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: settings.isHandsFreeMode) { _, newValue in
                SpeechAnalyzerService.shared.isHandsFreeEnabled = newValue
            }
        } header: {
            Label("音声対話 (Speech & SileroVAD)", systemImage: "mic.fill")
        } footer: {
            Text("SpeechAnalyzer / SpeechTranscriber による文字起こしと、SileroVAD による発話区間の自動検出でハンズフリー対話が可能です。")
                .font(.caption2)
        }
        
        // --- AI応答の音声合成方式 ---
        Section {
            Picker("音声合成方式", selection: $settings.ttsSynthesisMode) {
                ForEach(TTSSynthesisMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("音声合成方式", systemImage: "waveform")
        } footer: {
            Text("どちらも speech.cpp を使用し、字幕は発話開始に合わせて表示します。「文ごと」は短い文を最大2文・合計48文字までまとめ、最初の音声ができたら再生します。続きは最大2チャンク先読みし、同じプレーヤーへ連続予約します。合成が追いつかない場合は文間で待つことがあります。「全文まとめて」は応答全体の合成完了後に話し始めます。長文ではモデルの上限により失敗する場合があります。その場合は「文ごと」に切り替えてください。")
                .font(.caption2)
        }

        // --- 話し方の指示 (Caption) ---
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("声の雰囲気プリセット:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(captionPresets, id: \.label) { preset in
                            let isSelected = settings.ttsCaption == preset.caption
                            Button(preset.label) {
                                settings.ttsCaption = preset.caption
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(isSelected ? AppTheme.puppyPink : .secondary)
                            .font(.caption)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("現在の話し方指示 (Caption):")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("例: 落ち着いた、やさしい話し方。", text: $settings.ttsCaption)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("話し方・声質 (Caption)", systemImage: "text.bubble.fill")
        } footer: {
            Text("Irodori TTS はテキストの指示に応じて自然に声色や抑揚を変化させます。")
                .font(.caption2)
        }
        
        // --- 段階的開示 1: 音声リファレンス (声質模倣 / クローン) ---
        Section {
            DisclosureGroup(isExpanded: $isVoiceReferenceExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    // 同意トグル
                    Toggle(isOn: $settings.voiceConsent) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("利用できる声を登録")
                                .font(.subheadline)
                            Text("自分の声、または明示的に許可を得た声")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if !settings.voiceConsent {
                        Text("※ 音声リファレンスを利用するには、上の同意トグルをオンにしてください。")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    // 登録状態
                    HStack {
                        Text("現在の参照音声:")
                            .font(.subheadline)
                        Spacer()
                        if settings.referenceAudioURL != nil {
                            Label("登録あり", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Text("なし (デフォルト話者)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // アクションボタン
                    HStack(spacing: 10) {
                        Button {
                            handleRecordAction()
                        } label: {
                            HStack {
                                Image(systemName: voiceManager.isRecording ? "stop.circle.fill" : "record.circle")
                                Text(voiceManager.isRecording ? String(format: "停止 (%.1fs)", voiceManager.recordingDuration) : "マイク録音")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(voiceManager.isRecording ? AppTheme.puppyDeepPink : AppTheme.puppyPink)
                        .disabled(!settings.voiceConsent)
                        
                        Button {
                            showAudioImporter = true
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("ファイル選択")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!settings.voiceConsent || voiceManager.isRecording)
                        .fileImporter(
                            isPresented: $showAudioImporter,
                            allowedContentTypes: [.audio],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let urls):
                                if let url = urls.first {
                                    referenceError = nil
                                    Task {
                                        do {
                                            try await voiceManager.importAudio(from: url)
                                        } catch {
                                            referenceError = error.localizedDescription
                                        }
                                    }
                                }
                            case .failure(let error):
                                referenceError = error.localizedDescription
                            }
                        }
                    }
                    
                    // 試聴と解除
                    if settings.referenceAudioURL != nil {
                        HStack {
                            Button {
                                voiceManager.togglePreview()
                            } label: {
                                Label(voiceManager.isPreviewPlaying ? "停止" : "試聴再生",
                                      systemImage: voiceManager.isPreviewPlaying ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            
                            Spacer()
                            
                            Button(role: .destructive) {
                                Task {
                                    await voiceManager.deleteReference()
                                }
                            } label: {
                                Label("解除", systemImage: "trash")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                    }
                    
                    if !voiceManager.statusMessage.isEmpty {
                        Text(voiceManager.statusMessage)
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    
                    if let err = referenceError ?? voiceManager.errorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    
                    Text("3〜10秒程度の1人が明瞭に話す音声（WAV/MP3/M4A等）が最適です。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.wave.2")
                        .foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("音声リファレンス (声質模倣)")
                            .font(.subheadline)
                        Text(settings.referenceAudioURL != nil ? "カスタム音声が登録されています" : "参照音声を登録して特定の声質を再現")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if settings.referenceAudioURL != nil {
                        Label("登録済", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
        }
        
        // --- 段階的開示 2: Irodori TTS 推論設定 (ステップ数・サンプラー調整) ---
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("サンプリングステップ数")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(stepDescription(for: settings.ttsSteps))
                            .font(.caption2)
                            .foregroundColor(settings.ttsSteps == 4 ? .secondary : AppTheme.puppyPink)
                    }
                    Spacer()
                    Text("\(settings.ttsSteps) steps")
                        .font(.headline)
                        .foregroundColor(AppTheme.puppyPink)
                }
                
                // プリセットチップ
                HStack(spacing: 8) {
                    ForEach([2, 4, 6, 8, 12], id: \.self) { step in
                        let isSelected = settings.ttsSteps == step
                        Button {
                            settings.ttsSteps = step
                        } label: {
                            Text("\(step)")
                                .frame(minWidth: 36)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(isSelected ? AppTheme.puppyPink : .secondary)
                        .font(.caption)
                        .fontWeight(isSelected ? .bold : .regular)
                    }
                }
                
                Slider(value: Binding(
                    get: { Double(settings.ttsSteps) },
                    set: { settings.ttsSteps = Int($0) }
                ), in: 1...16, step: 1)
                
                HStack {
                    Text("1 (超高速)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("4 (標準)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("16 (最高品質)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            
            // 段階的開示: 高度なサンプラー・推論Config
            DisclosureGroup(isExpanded: $isTtsConfigAdvancedExpanded) {
                VStack(spacing: 14) {
                    // モデル生成速度 (Speed)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("モデル生成速度 (Speed)")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2fx", settings.ttsSpeed))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.ttsSpeed, in: 0.5...2.0, step: 0.05)
                        Text("※ 音声合成モデル内部での発話テンポ。自然な早口・ゆっくりを調整できます。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // 発話長スケール (Duration Scale)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("発話長スケール (Duration Scale)")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2fx", settings.ttsDurationScale))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.ttsDurationScale, in: 0.5...1.5, step: 0.05)
                        Text("※ モデルが予測した発話の全体の長さを伸縮します（標準: 1.00x）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // Sway サンプリング係数
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sway サンプリング係数")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f", settings.ttsSwayCoeff))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.ttsSwayCoeff, in: -1.0...1.0, step: 0.05)
                        Text("※ サンプラーの時間ステップ間隔の配分を調整します（0.00: 均等配分）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    // デフォルトに戻す
                    Button(role: .destructive) {
                        settings.resetTTSConfigToDefaults()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("推論Configをデフォルトに戻す")
                        }
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .foregroundColor(.purple)
                    Text("詳細推論Config (話速・発話長・Sway)")
                        .font(.subheadline)
                }
            }
        } header: {
            Label("Irodori TTS 推論Config", systemImage: "cpu")
        } footer: {
            Text("ステップ数を増やすと音質や滑らかさが向上しますが、生成時間が増加します。4〜8 steps がバランス良く推奨されます。")
                .font(.caption2)
        }
        
        // --- 段階的開示 3: 音声の微調整 (詳細設定) ---
        Section {
            DisclosureGroup(isExpanded: $isAudioAdvancedExpanded) {
                VStack(spacing: 14) {
                    // 話速
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("話速 (ピッチ維持)")
                            Spacer()
                            Text(String(format: "%.2fx", settings.speechRate))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.speechRate, in: 0.75...1.5, step: 0.05)
                    }
                    
                    // 音量
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("音声ボリューム")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.speechVolume * 100))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.speechVolume, in: 0.1...1.0, step: 0.05)
                    }
                    
                    // クチパク感度
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("クチパク感度 (LipSync Boost)")
                            Spacer()
                            Text(String(format: "%.1fx", settings.lipSyncBoost))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.lipSyncBoost, in: 1.0...10.0, step: 0.5)
                    }
                    
                    Divider()
                    
                    // シード値
                    Toggle("シード値をランダム生成", isOn: $settings.useRandomSeed)
                    if !settings.useRandomSeed {
                        HStack {
                            Text("固定シード値")
                            Spacer()
                            TextField("12345", value: $settings.speakerSeed, format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                    
                    // 透かし
                    Toggle("音声透かし (Watermark)", isOn: $settings.watermarkEnabled)
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.2.square")
                        .foregroundColor(.blue)
                    Text("音声の詳細調整 (話速・音量・クチパク)")
                        .font(.subheadline)
                }
            }
        }
    }
    
    // =========================================================================
    // MARK: - 3. 接続・モデル設定 (LLM & Engine)
    // =========================================================================
    @ViewBuilder
    private var connectionSection: some View {
        // --- AI対話 (LLM) プロバイダー選択 ---
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("対話エンジン種別:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("LLM方式", selection: $settings.llmProviderTypeRaw) {
                    ForEach(LLMProviderType.allCases) { provider in
                        Label(provider.displayName, systemImage: provider.icon)
                            .tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.vertical, 2)
            
            switch settings.llmProviderType {
            case .localLFM:
                localLFMView
            case .chatGPTSignIn:
                chatGPTSignInView
            case .gemini:
                GeminiSettingsView(settings: settings)
            case .openAICompatible:
                openAICompatibleView
            }
        } header: {
            Label("AI対話エンジン (LLM)", systemImage: "bubble.left.and.bubble.right.fill")
        } footer: {
            switch settings.llmProviderType {
            case .localLFM:
                Text("Liquid AI による日本語特化 1.2B モデル。端末上でオフライン完結し、完全無料でプライベートに動作します。")
                    .font(.caption2)
            case .chatGPTSignIn:
                Text("ChatGPT Plus / Pro 等の契約をお持ちの場合、APIキーの発行不要でご自身のアカウント枠を用いて直接会話できます。")
                    .font(.caption2)
            case .gemini:
                Text("Google AI Studioで発行したGemini APIキーを使用します。会話内容はGoogleに送信され、モデルと推論量に応じてAPI利用料金が発生する場合があります。")
                    .font(.caption2)
            case .openAICompatible:
                Text("OpenAI または OpenAI 互換の API（Groq, Ollama, OpenRouter 等）を利用できます。")
                    .font(.caption2)
            }
        }
        
        // --- 音声合成モデル (speech.cpp) ---
        Section {
            HStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.title2)
                    .foregroundColor(ttsManager.isModelInstalled ? .green : .orange)
                    .frame(width: 36, height: 36)
                    .background((ttsManager.isModelInstalled ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 2) {
                    #if os(iOS) && canImport(IrodoriSpeechCpp)
                    Text("Irodori TTS v4.1 Small MF (\(ttsManager.selectedVariant.shortLabel))")
                        .font(.headline)
                    Text(ttsManager.selectedVariant.benchmarkSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    #else
                    Text("Irodori TTS v4.1 Small MF")
                        .font(.headline)
                    Text("Metal GPU推論モデル")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
                }
                
                Spacer()
                
                if ttsManager.isModelInstalled {
                    Label("準備完了", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Label("未取得", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 4)
            
            #if os(iOS) && canImport(IrodoriSpeechCpp)
            // 量子化モデル選択 (F16 / Q8_0 / Q6_K / Q4_K)
            VStack(alignment: .leading, spacing: 8) {
                Text("量子化フォーマット選択:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(SpeechCppModelVariant.allCases) { variant in
                    let isSelected = ttsManager.selectedVariant == variant
                    let isInstalled = ttsManager.isVariantInstalled(variant)
                    
                    Button {
                        downloadError = nil
                        ttsManager.selectVariant(variant)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(isSelected ? AppTheme.puppyPink : .secondary)
                                .font(.body)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(variant.displayName)
                                        .font(.subheadline)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .foregroundColor(.primary)
                                    
                                    if let badge = variant.badgeText {
                                        Text(badge)
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                (variant == .q6_k ? AppTheme.puppyPink : Color.secondary).opacity(0.15),
                                                in: Capsule()
                                            )
                                            .foregroundColor(variant == .q6_k ? AppTheme.puppyPink : .secondary)
                                    }
                                }
                                
                                Text("容量: \(variant.approximateSizeText)\(variant.sizeReductionText.map { " (\($0))" } ?? "") ・ 最大RAM: \(variant.peakMemoryText)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if isInstalled {
                                Label("取得済", systemImage: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            } else {
                                Text("未取得")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? AppTheme.puppyPink.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? AppTheme.puppyPink.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(ttsManager.isDownloading)
                }
            }
            .padding(.vertical, 4)
            #endif
            
            if !ttsManager.isModelInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    if ttsManager.isDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: ttsManager.downloadProgress)
                            HStack {
                                Text(ttsManager.downloadStatusText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", ttsManager.downloadProgress * 100))
                                    .font(.caption2)
                                    .fontWeight(.bold)
                            }
                        }
                    } else {
                        Button {
                            downloadModel()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                #if os(iOS) && canImport(IrodoriSpeechCpp)
                                Text("\(ttsManager.selectedVariant.shortLabel) モデルをダウンロード (\(ttsManager.selectedVariant.approximateSizeText))")
                                #else
                                Text("音声モデルをダウンロード")
                                #endif
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    Text("推論ステップ数")
                        .font(.subheadline)
                    Spacer()
                    Text("\(settings.ttsSteps) steps (\(stepDescription(for: settings.ttsSteps)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("モデル管理")
                        .foregroundColor(.secondary)
                    Spacer()
                    #if os(iOS) && canImport(IrodoriSpeechCpp)
                    Button("\(ttsManager.selectedVariant.shortLabel) モデルを削除", role: .destructive) {
                        ttsManager.deleteModel(variant: ttsManager.selectedVariant)
                    }
                    .font(.caption)
                    #else
                    Button("モデルを削除して再取得", role: .destructive) {
                        ttsManager.deleteModel()
                    }
                    .font(.caption)
                    #endif
                }
            }
            
            if let err = downloadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        } header: {
            Label("音声合成エンジン (Irodori TTS)", systemImage: "waveform.circle.fill")
        } footer: {
            Text("iPhoneでのローカル実行には省メモリと品質を両立した Q6_K（F16比46%削減）または最小容量の Q4_K（55%削減）がおすすめです。複数取得して聴き比べることも可能です。")
                .font(.caption2)
        }
        
        // --- アプリ情報 ---
        Section {
            HStack {
                Text("バージョン")
                Spacer()
                Text("1.0.0 (Irodori TTS v4.1)")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - LLM プロバイダー別サブビュー
    @ViewBuilder
    private var localLFMView: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu.fill")
                .font(.title2)
                .foregroundColor(localLLM.isModelInstalled ? .green : .orange)
                .frame(width: 36, height: 36)
                .background((localLLM.isModelInstalled ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            
            VStack(alignment: .leading, spacing: 2) {
                #if os(iOS) && canImport(LlamaCpp)
                Text("LFM2.5-1.2B-JP (\(localLLM.selectedVariant.shortLabel))")
                    .font(.headline)
                Text("Liquid AI 日本語特化 1.2B・Metal GPU完全オンデバイス")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                #else
                Text("LFM2.5-1.2B-JP")
                    .font(.headline)
                Text("オンデバイス推論モデル")
                    .font(.caption)
                    .foregroundColor(.secondary)
                #endif
            }
            
            Spacer()
            
            if localLLM.isModelInstalled {
                Label("準備完了", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Label("未取得", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
        
        #if os(iOS) && canImport(LlamaCpp)
        // 量子化フォーマット選択
        VStack(alignment: .leading, spacing: 8) {
            Text("量子化フォーマット選択:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ForEach(LFM2ModelVariant.allCases) { variant in
                let isSelected = localLLM.selectedVariant == variant
                let isInstalled = localLLM.isVariantInstalled(variant)
                
                Button {
                    localLLMDownloadError = nil
                    localLLM.selectVariant(variant)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(isSelected ? AppTheme.puppyPink : .secondary)
                            .font(.body)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(variant.displayName)
                                    .font(.subheadline)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundColor(.primary)
                                
                                if let badge = variant.badgeText {
                                    Text(badge)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            (variant == .q4_k_m ? AppTheme.puppyPink : Color.secondary).opacity(0.15),
                                            in: Capsule()
                                        )
                                        .foregroundColor(variant == .q4_k_m ? AppTheme.puppyPink : .secondary)
                                }
                            }
                            
                            Text("容量: \(variant.approximateSizeText) ・ 必要RAM: \(variant.peakMemoryText)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if isInstalled {
                            Label("取得済", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                        } else {
                            Text("未取得")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? AppTheme.puppyPink.opacity(0.08) : Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? AppTheme.puppyPink.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(localLLM.isDownloading)
            }
        }
        .padding(.vertical, 4)
        #endif
        
        if !localLLM.isModelInstalled {
            VStack(alignment: .leading, spacing: 8) {
                if localLLM.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: localLLM.downloadProgress)
                        HStack {
                            Text(localLLM.downloadStatusText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", localLLM.downloadProgress * 100))
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                    }
                } else {
                    Button {
                        downloadLocalLLMModel()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            #if os(iOS) && canImport(LlamaCpp)
                            Text("LFM2.5 (\(localLLM.selectedVariant.shortLabel)) をダウンロード (\(localLLM.selectedVariant.approximateSizeText))")
                            #else
                            Text("ローカルモデルをダウンロード")
                            #endif
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                Text("モデル管理")
                    .foregroundColor(.secondary)
                Spacer()
                #if os(iOS) && canImport(LlamaCpp)
                Button("LFM2.5 (\(localLLM.selectedVariant.shortLabel)) モデルを削除", role: .destructive) {
                    localLLM.deleteModel(variant: localLLM.selectedVariant)
                }
                .font(.caption)
                #else
                Button("モデルを削除", role: .destructive) {
                    localLLM.deleteModel()
                }
                .font(.caption)
                #endif
            }
        }
        
        if let err = localLLMDownloadError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
    
    @ViewBuilder
    private var chatGPTSignInView: some View {
        if chatGPTAuth.isSignedIn {
            // サインイン完了状態
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundColor(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.hideChatGPTAccountInfo ? "••••••••" : (chatGPTAuth.userName.isEmpty ? "ChatGPT ユーザー" : chatGPTAuth.userName))
                            .font(.headline)
                            .lineLimit(1)
                        Text(settings.hideChatGPTAccountInfo ? "••••••••" : (chatGPTAuth.userEmail.isEmpty ? "ChatGPTアカウント連携中 (Responses API)" : chatGPTAuth.userEmail))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.hideChatGPTAccountInfo.toggle()
                            }
                        } label: {
                            Image(systemName: settings.hideChatGPTAccountInfo ? "eye.slash" : "eye")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(settings.hideChatGPTAccountInfo ? "アカウント情報を表示" : "アカウント情報を隠す")
                        
                        Label("連携済", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                
                Divider()
                
                chatGPTModelPicker

                Picker("推論 Effort", selection: Binding(
                    get: { settings.chatGPTReasoningEffort },
                    set: { settings.chatGPTReasoningEffort = $0 }
                )) {
                    ForEach(ChatGPTReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                .pickerStyle(.menu)
                Text("推論に使う量を指定します。高いほど応答が遅くなる場合があります。対応する値はモデルにより異なるため、エラー時は「自動」に戻してください。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !chatGPTAuth.isChatGPTPlanEnabled {
                    Text("サインイン済みですが、ChatGPTプランの利用が許可されていません。再認証して利用を許可してください。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Button("利用権限を再認証") {
                    chatGPTAuth.startSignIn(requestPlanConsent: true)
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(chatGPTAuth.isAuthenticating)

                if chatGPTAuth.isAuthenticating {
                    ProgressView("ブラウザで再認証してください…")
                        .font(.caption)
                }
                if let error = chatGPTAuth.authErrorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                
                // サインアウト
                Button(role: .destructive) {
                    chatGPTAuth.signOut()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("ChatGPTからサインアウト")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .font(.caption)
                .disabled(chatGPTAuth.isAuthenticating)
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
            .task(id: chatGPTAuth.modelCatalogSession) {
                await refreshChatGPTModels(forceRefresh: true)
            }
        } else {
            // 未サインイン状態
            VStack(alignment: .leading, spacing: 12) {
                Text("ChatGPT Plus / Pro などのアカウントでログインすると、APIキーの発行不要でご自身のプラン枠を使って直接AI対話を行えます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button {
                    chatGPTAuth.startSignIn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Sign in with ChatGPT でサインイン")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.08, green: 0.65, blue: 0.52)) // OpenAI Emerald Green
                .disabled(chatGPTAuth.isAuthenticating)
                
                if chatGPTAuth.isAuthenticating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("認証待機中… ブラウザでサインインしてください")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let err = chatGPTAuth.authErrorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                // 段階的開示: 高度なOAuth設定
                DisclosureGroup(isExpanded: $isChatGPTAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("カスタム OAuth Client ID (任意):")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("空欄で動的登録 (dynamic_agent_client)", text: $chatGPTAuth.customClientId)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: chatGPTAuth.customClientId) { _, val in
                                chatGPTAuth.setCustomClientId(val)
                            }
                        Text("※ 通常は空欄のままで自動的に動的クライアント登録が行われます。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                        Text("高度な設定 (Client ID)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var chatGPTModelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("使用モデル")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await refreshChatGPTModels(forceRefresh: true) }
                } label: {
                    Label("一覧を更新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(chatGPTAuth.isLoadingModels)
            }

            if !chatGPTAuth.availableModels.isEmpty {
                Picker("モデル", selection: Binding(
                    get: {
                        let preferred = settings.chatGPTModelName.trimmingCharacters(in: .whitespacesAndNewlines)
                        return chatGPTAuth.availableModels.contains(where: { $0.slug == preferred }) ? preferred : ""
                    },
                    set: { settings.chatGPTModelName = $0 }
                )) {
                    if let first = chatGPTAuth.availableModels.first {
                        Text("自動（\(first.displayName)）").tag("")
                    }
                    ForEach(chatGPTAuth.availableModels) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
                .pickerStyle(.menu)
                Text("サインイン中のアカウントで利用可能なモデルを表示しています。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if !chatGPTAuth.isLoadingModels && chatGPTAuth.modelsErrorMessage == nil {
                Text("利用可能なモデルがありません。一覧を更新してください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if chatGPTAuth.isLoadingModels {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("モデル一覧を取得中…").font(.caption)
                }
            }
            if let error = chatGPTAuth.modelsErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                if !chatGPTAuth.availableModels.isEmpty {
                    Text("更新前の一覧を表示しています。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @MainActor
    private func refreshChatGPTModels(forceRefresh: Bool) async {
        do {
            _ = try await chatGPTAuth.loadModels(forceRefresh: forceRefresh)
        } catch {
            // The auth manager publishes catalog errors without raw server bodies.
        }
    }
    
    @ViewBuilder
    private var openAICompatibleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API Key")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if settings.openAIKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("未入力", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    Label("入力済", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            
            HStack {
                if showAPIKey {
                    TextField("sk-...", text: $settings.openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-...", text: $settings.openAIKey)
                }
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
        
        // 段階的開示: エンドポイントとモデル名の変更
        DisclosureGroup(isExpanded: $isLLMAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Endpoint URL")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("https://api.openai.com/v1/chat/completions", text: $settings.openAIEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("モデル名")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("gpt-4o-mini", text: $settings.modelName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
                Text("エンドポイント・モデル名の変更")
                    .font(.subheadline)
                Spacer()
                Text(settings.modelName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - 内部アクション
    private func handleRecordAction() {
        referenceError = nil
        Task {
            do {
                try await voiceManager.toggleRecording()
            } catch {
                referenceError = error.localizedDescription
            }
        }
    }
    
    private func downloadLocalLLMModel() {
        localLLMDownloadError = nil
        Task {
            do {
                try await localLLM.downloadModel()
            } catch {
                localLLMDownloadError = error.localizedDescription
            }
        }
    }

    private func downloadModel() {
        downloadError = nil
        Task {
            do {
                try await ttsManager.downloadModel()
            } catch {
                downloadError = error.localizedDescription
            }
        }
    }
    
    private func stepDescription(for step: Int) -> String {
        switch step {
        case ...2:
            return "超高速・低遅延"
        case 3...4:
            return "標準（推奨バランス）"
        case 5...8:
            return "高音質・滑らか"
        default:
            return "最高品質（処理時間長）"
        }
    }
}
