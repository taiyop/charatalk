import SwiftUI

@available(iOS 18.0, *)
public struct ContentView: View {
    @StateObject private var conversationViewModel = ConversationViewModel()
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // 背景グラデーション (ふわふわパピー・トークの世界観に合わせた温かいパステルトーン)
            AppTheme.backgroundGradient
                .ignoresSafeArea()
            
            // 3D VRMキャラクター描画
            VRMRealityView(controller: VRMCharacterController.shared)
                .ignoresSafeArea(edges: .top)
            
            // チャットUIオーバーレイ
            ChatOverlayView(viewModel: conversationViewModel)
        }
        .sheet(isPresented: $conversationViewModel.showSettings) {
            SettingsView()
        }
    }
}
