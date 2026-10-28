import SwiftUI

@available(iOS 18.0, *)
public struct ContentView: View {
    @StateObject private var conversationViewModel = ConversationViewModel()
    @ObservedObject private var warmup: ConversationWarmup = .shared
    /// 起動直後はキャラクター一覧から始める
    @State private var isSelectingCharacter = true

    public init() {}

    public var body: some View {
        ZStack {
            // 背景グラデーション (ふわふわパピー・トークの世界観に合わせた温かいパステルトーン)
            AppTheme.backgroundGradient
                .ignoresSafeArea()

            // 3D VRMキャラクター描画（一覧の裏でも生かしておき、選んだモデルをここに読み込む）
            VRMRealityView(controller: VRMCharacterController.shared)
                .ignoresSafeArea(edges: .top)

            if isSelectingCharacter {
                CharacterSelectionView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isSelectingCharacter = false
                    }
                    // 初回の会話から待たせないよう、LLMと音声合成を先に読み込む
                    warmup.start()
                }
                .transition(.opacity)
            } else {
                // チャットUIオーバーレイ
                ChatOverlayView(viewModel: conversationViewModel, onShowCharacterList: showCharacterList)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $conversationViewModel.showSettings) {
            SettingsView(onShowCharacterList: showCharacterList)
        }
        .onChange(of: conversationViewModel.showSettings) { _, isShowing in
            // プロバイダーや量子化モデルを変えたかもしれないので、閉じたら準備し直す
            if !isShowing && !isSelectingCharacter {
                warmup.start()
            }
        }
    }

    private func showCharacterList() {
        conversationViewModel.showSettings = false
        conversationViewModel.stopVoiceSession()
        conversationViewModel.stopSpeaking(resetVoiceSession: true)
        withAnimation(.easeInOut(duration: 0.3)) {
            isSelectingCharacter = true
        }
    }
}
