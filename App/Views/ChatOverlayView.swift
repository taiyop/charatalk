import SwiftUI

public struct ChatOverlayView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject var speechService: SpeechAnalyzerService = .shared
    @ObservedObject var ttsManager: SpeechTTSManager = .shared
    @ObservedObject var characterController: VRMCharacterController = .shared
    @ObservedObject var characterLibrary: VRMCharacterLibrary = .shared
    @ObservedObject var warmup: ConversationWarmup = .shared
    let onShowCharacterList: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isInputFocused: Bool
    @State private var showHistoryOverlay: Bool = false
    @State private var showResetConfirmation: Bool = false
    @State private var showViewpointSavedToast: Bool = false
    @State private var toastDismissTask: Task<Void, Never>?
    
    public init(viewModel: ConversationViewModel, onShowCharacterList: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onShowCharacterList = onShowCharacterList
    }
    
    public var body: some View {
        ZStack {
            // MARK: - メインコンテンツ層
            VStack(spacing: 0) {
                // MARK: - トップバー
                HStack {
                    // 表示中のキャラクター（タップでキャラクター一覧へ戻る）
                    Button(action: onShowCharacterList) {
                        HStack(spacing: 8) {
                            if let id = characterLibrary.activeID, let image = characterLibrary.thumbnails[id] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundColor(AppTheme.puppyPink)
                                    .font(.title3)
                            }
                            Text(characterLibrary.activeEntry?.name ?? "CharaTalk")
                                .font(.headline)
                                .fontWeight(.heavy)
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 14)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: AppTheme.puppyPink.opacity(0.18), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("キャラクター一覧に戻る")
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        // 過去の会話（履歴）アイコンボタン
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                showHistoryOverlay.toggle()
                            }
                        } label: {
                            Image(systemName: showHistoryOverlay ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                                .font(.headline)
                                .foregroundColor(showHistoryOverlay ? .white : AppTheme.puppyPink)
                                .padding(10)
                                .background(
                                    Group {
                                        if showHistoryOverlay {
                                            Circle().fill(AppTheme.primaryButtonGradient)
                                        } else {
                                            Circle().fill(.ultraThinMaterial)
                                        }
                                    }
                                )
                                .overlay(
                                    Circle()
                                        .stroke(
                                            showHistoryOverlay ? Color.white.opacity(0.4) : AppTheme.puppySoftPink.opacity(0.6),
                                            lineWidth: 1
                                        )
                                )
                                .shadow(color: AppTheme.puppyPink.opacity(showHistoryOverlay ? 0.35 : 0.15), radius: 6, x: 0, y: 2)
                        }
                        .accessibilityLabel(showHistoryOverlay ? "会話履歴を閉じる" : "過去の会話を表示")
                        
                        // 会話リセットボタン
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.headline)
                                .foregroundColor(AppTheme.puppyPink)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                                .shadow(color: AppTheme.puppyPink.opacity(0.15), radius: 6, x: 0, y: 2)
                        }
                        .accessibilityLabel("会話をリセット")
                    
                    // 設定ボタン
                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.headline)
                            .foregroundColor(AppTheme.puppyPink)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: AppTheme.puppyPink.opacity(0.15), radius: 6, x: 0, y: 2)
                    }
                    .accessibilityLabel("設定")
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // キャラクター選択直後のLLM・音声合成の事前読み込み
            warmupBanner
            
            // モデル未ダウンロード時の通知バナー
            if !ttsManager.isModelInstalled {
                Button {
                    viewModel.showSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(AppTheme.puppyPink)
                        Text("音声合成モデルが未取得です。タップして準備してください。")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(AppTheme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.92))
                            .shadow(color: AppTheme.puppyPink.opacity(0.2), radius: 8, x: 0, y: 3)
                    )
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }
            
            // MARK: - 視点保存・リセットボタン（アバター操作時にふわっと表示）
            if characterController.isTransformed {
                HStack(spacing: 8) {
                    Spacer()
                    
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            characterController.saveCurrentTransformAsDefault()
                            showViewpointSavedToast = true
                        }
                        toastDismissTask?.cancel()
                        toastDismissTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            if !Task.isCancelled {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    showViewpointSavedToast = false
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Text("デフォルトとして保存")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppTheme.primaryButtonGradient, in: Capsule())
                        .shadow(color: AppTheme.puppyPink.opacity(0.3), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(SoftPressButtonStyle())
                    .accessibilityLabel("現在の視点をデフォルトとして保存")
                    
                    Button {
                        characterController.resetTransformWithAnimation()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "camera.rotate.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppTheme.puppyPink)
                            Text("視点リセット")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(AppTheme.textPrimary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AppTheme.puppySoftPink.opacity(0.8), lineWidth: 1)
                        )
                        .shadow(color: AppTheme.puppyPink.opacity(0.18), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(SoftPressButtonStyle())
                    .accessibilityLabel("視点をリセット")
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)),
                    removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing))
                ))
            } else if showViewpointSavedToast {
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                        Text("デフォルト視点を保存しました")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.puppySoftPink.opacity(0.8), lineWidth: 1)
                    )
                    .shadow(color: AppTheme.puppyPink.opacity(0.18), radius: 8, x: 0, y: 3)
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)),
                    removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing))
                ))
            }
            
            Spacer()
            
            // MARK: - 会話字幕表示（オーバーレイ非表示時に最新メッセージを表示）
            if !showHistoryOverlay, let lastMsg = viewModel.subtitleMessage {
                HStack {
                    if lastMsg.role == .user {
                        Spacer(minLength: 32)
                        ViewThatFits(in: .vertical) {
                            Text(lastMsg.content)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(lastMsg.content)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.white)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxHeight: 220)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(AppTheme.userBubbleGradient, in: RoundedRectangle(cornerRadius: 20))
                        .shadow(color: AppTheme.puppyPink.opacity(0.35), radius: 8, x: 0, y: 4)
                    } else {
                        ViewThatFits(in: .vertical) {
                            Text(lastMsg.content)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(AppTheme.textPrimary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            ScrollView(.vertical, showsIndicators: true) {
                                Text(lastMsg.content)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(AppTheme.textPrimary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxHeight: 220)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.white.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(AppTheme.puppySoftPink, lineWidth: 1.5)
                                )
                        )
                        .shadow(color: AppTheme.puppyPink.opacity(0.15), radius: 10, x: 0, y: 4)
                        Spacer(minLength: 32)
                    }
                }
                .layoutPriority(1)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            
            // MARK: - エラー表示（文字ステータスピルは全廃止し、エラーのみ表示）
            if let err = viewModel.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(AppTheme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        viewModel.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "#FFF1F2"))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.puppyPink.opacity(0.5), lineWidth: 1))
                )
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
            
            // MARK: - テキスト・音声入力バー（一体型モーフィング）
            let isVoiceActive = speechService.isListening || speechService.isPreparing
            let isVoiceSessionRunning = isVoiceActive || viewModel.isVoiceSessionActive
            
            HStack(spacing: 10) {
                // 左下マイクボタン (音声対話の開始／停止)
                Button {
                    isInputFocused = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        viewModel.toggleVoiceListening()
                    }
                } label: {
                    ZStack {
                        if speechService.isPreparing {
                            // 準備中
                            Circle()
                                .fill(AppTheme.puppySoftPink.opacity(0.35))
                                .frame(width: 42, height: 42)
                                .overlay(
                                    Circle().stroke(AppTheme.puppyPink, lineWidth: 2)
                                )
                            ProgressView()
                                .tint(AppTheme.puppyPink)
                                .scaleEffect(0.85)
                        } else if speechService.isListening {
                            // 音声対話中：ユーザー発話時は声量連動、待機時は呼吸パルス
                            if speechService.isUserSpeaking {
                                Circle()
                                    .stroke(AppTheme.puppyPink.opacity(0.45), lineWidth: 3)
                                    .scaleEffect(1.0 + CGFloat(speechService.audioLevel) * 0.55)
                                    .animation(.easeOut(duration: 0.12), value: speechService.audioLevel)
                            } else {
                                BreathingPulseRing()
                            }
                            
                            Circle()
                                .fill(AppTheme.primaryButtonGradient)
                                .frame(width: 42, height: 42)
                            
                            Image(systemName: speechService.isUserSpeaking ? "waveform" : "mic.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.white)
                        } else {
                            Circle()
                                .fill(viewModel.isVoiceSessionActive ? AppTheme.puppySoftPink.opacity(0.35) : Color.white)
                                .frame(width: 42, height: 42)
                                .overlay(
                                    Circle().stroke(
                                        viewModel.isVoiceSessionActive ? AppTheme.puppyPink : AppTheme.puppySoftPink,
                                        lineWidth: viewModel.isVoiceSessionActive ? 2 : 1.5
                                    )
                                )
                            
                            Image(systemName: "mic.fill")
                                .font(.system(size: 18))
                                .foregroundColor(AppTheme.puppyPink)
                        }
                    }
                    .frame(width: 42, height: 42)
                    .shadow(
                        color: isVoiceSessionRunning
                            ? AppTheme.puppyPink.opacity(0.35)
                            : Color.black.opacity(0.04),
                        radius: 6,
                        x: 0,
                        y: 2
                    )
                }
                .accessibilityLabel(isVoiceActive ? "音声入力を停止" : "音声入力を開始")
                
                // 中央：一体型モーフィングエリア
                // 音声対話中はスリムなオーディオカプセルに変形し、手動入力時は通常のテキストフィールドに展開
                ZStack {
                    if isVoiceSessionRunning {
                        // 音声対話モーフィングカプセル（音声対話時は透明なすりガラスカプセル）
                        Button {
                            // タップで手動テキスト入力に切り替え
                            viewModel.stopVoiceSession()
                            isInputFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                if speechService.isPreparing {
                                    ProgressView()
                                        .tint(AppTheme.puppyPink)
                                        .scaleEffect(0.8)
                                } else if !speechService.liveTranscript.isEmpty {
                                    // 発話中のリアルタイム字幕
                                    Image(systemName: "waveform")
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.puppyPink)
                                    Text(speechService.liveTranscript)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(AppTheme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                } else if speechService.isUserSpeaking {
                                    // 声量イコライザー波形
                                    WaveformLiveBar(audioLevel: speechService.audioLevel)
                                } else if viewModel.isThinking {
                                    ProgressView()
                                        .tint(AppTheme.puppyPink)
                                        .scaleEffect(0.8)
                                } else if viewModel.isSpeaking {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundColor(AppTheme.puppyPink)
                                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                                } else {
                                    // 聞き取り待機中の呼吸ドット
                                    BreathingDotsView()
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: !speechService.liveTranscript.isEmpty ? .infinity : 180)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(AppTheme.puppyPink, lineWidth: 1.5)
                            )
                            .shadow(color: AppTheme.puppyPink.opacity(0.25), radius: 8, x: 0, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("音声対話")
                        .accessibilityValue(voiceStatusAccessibilityValue)
                        .accessibilityHint("ダブルタップで文字入力に切り替えます")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    } else {
                        // 通常の手動テキスト入力フィールド
                        TextField(
                            viewModel.isThinking ? "" : "メッセージを入力…",
                            text: $viewModel.inputText
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22)
                                        .stroke(
                                            viewModel.isThinking
                                                ? AppTheme.puppyPink
                                                : (isInputFocused ? AppTheme.puppyPink : AppTheme.puppySoftPink.opacity(0.8)),
                                            lineWidth: viewModel.isThinking ? 2 : 1.5
                                        )
                                )
                        )
                        .foregroundColor(AppTheme.textPrimary)
                        .focused($isInputFocused)
                        .submitLabel(.send)
                        .onSubmit {
                            viewModel.sendCurrentMessage()
                        }
                        .onChange(of: isInputFocused) { _, focused in
                            if focused {
                                viewModel.stopVoiceSession()
                            }
                        }
                        .disabled(viewModel.isThinking)
                        .accessibilityLabel(viewModel.isThinking ? "返答を準備中" : "メッセージ入力")

                        // シマーは入力欄のサイズに影響しない重ね表示にする
                        .overlay {
                            if viewModel.isThinking {
                                ShimmerWaveOverlay()
                            }
                        }
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isVoiceSessionRunning)
                .animation(.easeInOut(duration: 0.25), value: viewModel.isThinking)
                
                // 右側アクションボタン（発話停止 ■ / テキスト送信 ↑）
                if viewModel.isBusy {
                    // AI発話中または処理中の停止ボタン（対話ステータス文字は全廃止、■ボタンのみ表示）
                    Button {
                        viewModel.stopSpeaking(resetVoiceSession: true)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(AppTheme.puppyDeepPink)
                            .frame(width: 38, height: 38)
                            .shadow(color: AppTheme.puppyDeepPink.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .accessibilityLabel("発話を停止")
                } else if !isVoiceSessionRunning {
                    let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        viewModel.sendCurrentMessage()
                        isInputFocused = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    !canSend
                                        ? LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                                        : AppTheme.primaryButtonGradient
                                )
                                .frame(width: 38, height: 38)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .shadow(
                            color: !canSend ? Color.clear : AppTheme.puppyPink.opacity(0.4),
                            radius: 6,
                            x: 0,
                            y: 2
                        )
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("メッセージを送信")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                Group {
                    if isVoiceSessionRunning {
                        Color.clear
                    } else {
                        Color.white.opacity(0.85)
                            .background(.ultraThinMaterial)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            )
            .animation(.easeInOut(duration: 0.25), value: isVoiceSessionRunning)
        }
        
        // MARK: - 過去の会話オーバーレイ
        if showHistoryOverlay {
            historyOverlay
        }
    }
    .alert("会話をリセット", isPresented: $showResetConfirmation) {
        Button("キャンセル", role: .cancel) {}
        Button("リセット", role: .destructive) {
            withAnimation {
                viewModel.resetConversation()
            }
        }
    } message: {
        Text("会話履歴がリセットされ、最初の状態に戻ります。よろしいですか？")
    }
}

    // VoiceOver retains meaningful state descriptions without visible status
    // text or provider names. Recognized speech remains conversation content.
    private var voiceStatusAccessibilityValue: String {
        if speechService.isPreparing { return "マイク準備中" }
        if !speechService.liveTranscript.isEmpty { return speechService.liveTranscript }
        if speechService.isUserSpeaking { return "聞き取り中" }
        if viewModel.isThinking { return "返答を準備中" }
        if viewModel.isSpeaking { return "音声再生中" }
        return "音声入力待機中"
    }

    // MARK: - 事前読み込みの状態表示
private var warmupBanner: some View {
    Group {
        switch warmup.phase {
        case .warming(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text(text)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(AppTheme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 6)
            .transition(.opacity)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(message)
                    .font(.caption)
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.top, 6)
            .transition(.opacity)
        case .idle, .ready:
            EmptyView()
        }
    }
    .animation(.easeInOut(duration: 0.25), value: warmup.phase)
}

    // MARK: - 過去の会話オーバーレイビュー
private var historyOverlay: some View {
    ZStack {
        // 背景透過バックドロップ（タップで閉じる）
        Color.black.opacity(0.18)
            .background(.ultraThinMaterial.opacity(0.75))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    showHistoryOverlay = false
                }
            }
        
        // 会話履歴フローティングカード
        VStack(spacing: 0) {
            // カード内ヘッダーバー
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.title3)
                        .foregroundColor(AppTheme.puppyPink)
                    
                    Text("過去の会話")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(AppTheme.textPrimary)
                    
                    Text("\(viewModel.messages.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(AppTheme.puppyDeepPink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(AppTheme.puppySoftPink.opacity(0.6), in: Capsule())
                }
                
                Spacer()
                
                // 履歴クリアボタン
                if !viewModel.messages.isEmpty {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.caption2)
                            Text("クリア")
                                .font(.caption2)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.red.opacity(0.85))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.08), in: Capsule())
                    }
                    .accessibilityLabel("会話履歴をクリア")
                }
                
                // 閉じるボタン
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        showHistoryOverlay = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(8)
                        .background(Color.black.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("会話履歴を閉じる")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.35))
            
            Divider()
                .background(AppTheme.puppySoftPink.opacity(0.6))
            
            // メッセージリスト または 空状態
            if viewModel.messages.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 46))
                        .foregroundColor(AppTheme.puppySoftPink)
                    Text("過去の会話はありません")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(AppTheme.textSecondary)
                    Text("マイクまたはメッセージ入力から\n話しかけてみてね！")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { msg in
                                messageRow(msg: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onAppear {
                        if let last = viewModel.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.messages.count) { _, _ in
                        if let last = viewModel.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.68))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.85),
                                    AppTheme.puppySoftPink.opacity(0.7),
                                    Color.white.opacity(0.45)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: AppTheme.puppyPink.opacity(0.2), radius: 24, x: 0, y: 10)
        )
        .padding(.horizontal, 16)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }
    .transition(.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)),
        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing))
    ))
}

// MARK: - 会話行ビュー
private func messageRow(msg: ChatMessage) -> some View {
    HStack(alignment: .bottom, spacing: 6) {
        if msg.role == .user {
            Spacer(minLength: 32)
            
            Text(Self.timeFormatter.string(from: msg.timestamp))
                .font(.system(size: 10))
                .foregroundColor(AppTheme.textSecondary.opacity(0.75))
                .padding(.bottom, 2)
                .fixedSize()
            
            Text(msg.content)
                .font(.subheadline)
                .foregroundColor(.white)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(AppTheme.userBubbleGradient.opacity(0.92), in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: AppTheme.puppyPink.opacity(0.25), radius: 6, x: 0, y: 3)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.puppyPink)
                    Text("CharaTalk")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppTheme.puppyDeepPink)
                }
                .padding(.leading, 4)
                
                Text(msg.content)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color.white.opacity(0.85))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(AppTheme.puppySoftPink.opacity(0.9), lineWidth: 1)
                            )
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
            }
            
            Text(Self.timeFormatter.string(from: msg.timestamp))
                .font(.system(size: 10))
                .foregroundColor(AppTheme.textSecondary.opacity(0.75))
                .padding(.bottom, 2)
                .fixedSize()
            
            Spacer(minLength: 32)
        }
    }
}
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// ボタン押下時にわずかに縮むフィードバックを提供するスタイル
private struct SoftPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 音声対話・ステータス用 UI/UX モーフィングコンポーネント

/// 音声待機中のゆったりとした呼吸パルスリング
private struct BreathingPulseRing: View {
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .stroke(AppTheme.puppyPink.opacity(0.4), lineWidth: 2.5)
            .scaleEffect(isPulsing ? 1.35 : 1.0)
            .opacity(isPulsing ? 0.0 : 0.8)
            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

/// ユーザー発話中の声量（audioLevel）連動リアルタイムイコライザー波形
private struct WaveformLiveBar: View {
    let audioLevel: Float
    
    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(AppTheme.primaryButtonGradient)
                    .frame(width: 3.5, height: barHeight(for: i))
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            }
        }
        .frame(height: 24)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let baseHeights: [CGFloat] = [6, 12, 18, 11, 7]
        let level = CGFloat(max(0.12, audioLevel))
        return min(22, max(4, baseHeights[index] * (0.6 + level * 1.3)))
    }
}

/// 音声待機中の3つの呼吸ドット
private struct BreathingDotsView: View {
    @State private var phase: Double = 0
    
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppTheme.puppyPink)
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(for: i))
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 1.0
            }
        }
    }
    
    private func scale(for i: Int) -> CGFloat {
        let offset = Double(i) * 0.25
        let val = sin((phase + offset) * .pi)
        return 0.7 + CGFloat(val) * 0.5
    }
    
    private func opacity(for i: Int) -> Double {
        let offset = Double(i) * 0.25
        let val = sin((phase + offset) * .pi)
        return 0.35 + val * 0.65
    }
}

/// AI思考中（LLM推論＋TTS合成）にテキスト枠内を走る光の波（シマー効果）
private struct ShimmerWaveOverlay: View {
    @State private var phase: CGFloat = -1.0
    
    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.clear,
                    AppTheme.puppyPink.opacity(0.18),
                    AppTheme.puppySoftPink.opacity(0.35),
                    AppTheme.puppyPink.opacity(0.18),
                    Color.clear
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(80, geo.size.width * 0.65))
            .offset(x: phase * geo.size.width)
        }
        .mask(RoundedRectangle(cornerRadius: 22))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.6
            }
        }
    }
}
