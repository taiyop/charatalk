import SwiftUI
import RealityKit

@available(iOS 18.0, *)
public struct VRMRealityView: View {
    @ObservedObject var controller: VRMCharacterController
    @ObservedObject var player: AudioSpeechPlayer = .shared
    
    // 操作トラッキング
    @State private var dragStartRotationY: Float = 0.0
    @State private var dragStartOffsetY: Float = 0.0
    @State private var pinchStartScale: Float = 1.0
    @State private var isDragging: Bool = false
    @State private var isPinching: Bool = false
    
    public init(controller: VRMCharacterController) {
        self.controller = controller
    }
    
    public var body: some View {
        ZStack {
            // MARK: - 3D RealityView
            RealityView { content in
                let root = Entity()
                content.add(root)
                controller.setup(root: root)
                
                // アバターの初期ロード（カスタムVRMがあればそれを、なければデフォルト）
                await controller.loadInitialAvatar()
            }
            .gesture(
                // 回転・移動（ドラッグ）と拡大縮小（ピンチ）の同時合成ジェスチャー
                SimultaneousGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartRotationY = controller.rotationY
                                dragStartOffsetY = controller.positionOffset.y
                            }
                            // 左右スワイプで水平回転（360度）
                            let deltaX = Float(value.translation.width) * 0.012
                            controller.rotationY = dragStartRotationY + deltaX
                            
                            // 上下スワイプで高さ調整
                            let deltaY = Float(value.translation.height) * 0.002
                            controller.positionOffset.y = dragStartOffsetY - deltaY
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragStartRotationY = controller.rotationY
                            dragStartOffsetY = controller.positionOffset.y
                        },
                    MagnificationGesture()
                        .onChanged { value in
                            if !isPinching {
                                isPinching = true
                                pinchStartScale = controller.scale
                            }
                            let newScale = pinchStartScale * Float(value)
                            controller.scale = min(max(newScale, 0.35), 6.0)
                        }
                        .onEnded { _ in
                            isPinching = false
                            pinchStartScale = controller.scale
                        }
                )
            )
            .onTapGesture(count: 2) {
                // ダブルタップでリセット
                resetWithAnimation()
            }
            .onAppear {
                dragStartRotationY = controller.rotationY
                dragStartOffsetY = controller.positionOffset.y
                pinchStartScale = controller.scale
            }
            .onChange(of: player.currentMouthOpen) { _, newValue in
                controller.setMouthOpen(value: newValue)
            }
            .onChange(of: controller.isTransformed) { _, isTransformed in
                if !isTransformed {
                    dragStartRotationY = controller.defaultRotationY
                    dragStartOffsetY = controller.defaultOffsetY
                    pinchStartScale = controller.defaultScale
                }
            }
            
            // MARK: - ローディング中インジケータ
            if controller.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.4)
                        .tint(.white)
                    Text("3Dモデルを読み込んでいます…")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            }
            
            // MARK: - エラー表示
            if let error = controller.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.title2)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .padding(32)
            }
        }
    }
    
    private func resetWithAnimation() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            controller.resetTransform()
            dragStartRotationY = controller.defaultRotationY
            dragStartOffsetY = controller.defaultOffsetY
            pinchStartScale = controller.defaultScale
        }
    }
}
