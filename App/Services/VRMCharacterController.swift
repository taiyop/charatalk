import Foundation
import SwiftUI
import RealityKit
import simd
import VRMKit
import VRMKitRuntime
#if canImport(VRMRealityKit)
import VRMRealityKit
#endif

@available(iOS 18.0, *)
@MainActor
public final class VRMCharacterController: ObservableObject {
    public static let shared = VRMCharacterController()
    
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var isLoaded: Bool = false
    @Published public private(set) var hasCustomAvatar: Bool = false
    
    // MARK: - インタラクティブ操作パラメータ (拡大・縮小・回転・位置)
    @Published public var scale: Float = 1.0 {
        didSet { updateEntityTransform() }
    }
    @Published public var rotationY: Float = 0.0 { // 水平回転（ラジアン）
        didSet { updateEntityTransform() }
    }
    @Published public var positionOffset: SIMD3<Float> = .zero {
        didSet { updateEntityTransform() }
    }
    
    // デフォルト配置（上半身が中央に見える位置）
    public let defaultBasePosition = SIMD3<Float>(0, -1.2, -0.9)
    public static let factoryDefaultScale: Float = 1.0
    public static let factoryDefaultRotationY: Float = 0.0
    public static let factoryDefaultOffsetY: Float = 0.0
    
    // ユーザーが保存可能なデフォルト視点パラメータ
    @Published public private(set) var defaultScale: Float = 1.0
    @Published public private(set) var defaultRotationY: Float = 0.0
    @Published public private(set) var defaultOffsetY: Float = 0.0
    @Published public private(set) var hasCustomDefaultTransform: Bool = false
    
    private enum TransformDefaultsKey {
        static let hasCustomDefault = "vrm_hasCustomDefaultTransform"
        static let scale = "vrm_defaultScale"
        static let rotationY = "vrm_defaultRotationY"
        static let offsetY = "vrm_defaultOffsetY"
    }
    
    /// デフォルト視点から変更されているかどうか
    public var isTransformed: Bool {
        abs(scale - defaultScale) > 0.02 ||
        abs(rotationY - defaultRotationY) > 0.03 ||
        abs(positionOffset.y - defaultOffsetY) > 0.01
    }
    
    private var vrmEntity: VRMEntity?
    private var rootEntity: Entity?
    private var avatarLoadID: UUID?
    private var blinkTask: Task<Void, Never>?
    private var isBlinking: Bool = false
    
    // 待機モーション（Idle Motion）用
    private var idleTime: Double = 0.0
    private var restBonePoses: [HumanoidBone: (nodeIndex: Int, rotation: simd_quatf)] = [:]
    private var currentBreathOffsetY: Float = 0.0
    private var isSynthesisThrottled: Bool = false
    
    /// ズーム（スケーリング）の中心アンカーとなる頭部・顔のローカル高さ
    public private(set) var focusHeadY: Float = 1.25
    
    private var customVRMURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("CustomVRM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_avatar.vrm")
    }
    
    public init() {
        loadSavedDefaultTransform()
        checkCustomAvatarStatus()
    }
    
    private func loadSavedDefaultTransform() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: TransformDefaultsKey.hasCustomDefault) {
            let savedScale = defaults.object(forKey: TransformDefaultsKey.scale) as? Float ?? Self.factoryDefaultScale
            let savedRotationY = defaults.object(forKey: TransformDefaultsKey.rotationY) as? Float ?? Self.factoryDefaultRotationY
            let savedOffsetY = defaults.object(forKey: TransformDefaultsKey.offsetY) as? Float ?? Self.factoryDefaultOffsetY
            
            self.defaultScale = min(max(savedScale, 0.35), 6.0)
            self.defaultRotationY = savedRotationY
            self.defaultOffsetY = savedOffsetY
            self.hasCustomDefaultTransform = true
        } else {
            self.defaultScale = Self.factoryDefaultScale
            self.defaultRotationY = Self.factoryDefaultRotationY
            self.defaultOffsetY = Self.factoryDefaultOffsetY
            self.hasCustomDefaultTransform = false
        }
        
        self.scale = self.defaultScale
        self.rotationY = self.defaultRotationY
        self.positionOffset = SIMD3<Float>(0, self.defaultOffsetY, 0)
    }
    
    /// 現在の視点（拡大率・回転・高さオフセット）をデフォルト視点として保存する
    public func saveCurrentTransformAsDefault() {
        self.defaultScale = scale
        self.defaultRotationY = rotationY
        self.defaultOffsetY = positionOffset.y
        
        let isDifferentFromFactory =
            abs(defaultScale - Self.factoryDefaultScale) > 0.005 ||
            abs(defaultRotationY - Self.factoryDefaultRotationY) > 0.005 ||
            abs(defaultOffsetY - Self.factoryDefaultOffsetY) > 0.005
        self.hasCustomDefaultTransform = isDifferentFromFactory
        
        let defaults = UserDefaults.standard
        if isDifferentFromFactory {
            defaults.set(true, forKey: TransformDefaultsKey.hasCustomDefault)
            defaults.set(defaultScale, forKey: TransformDefaultsKey.scale)
            defaults.set(defaultRotationY, forKey: TransformDefaultsKey.rotationY)
            defaults.set(defaultOffsetY, forKey: TransformDefaultsKey.offsetY)
        } else {
            defaults.removeObject(forKey: TransformDefaultsKey.hasCustomDefault)
            defaults.removeObject(forKey: TransformDefaultsKey.scale)
            defaults.removeObject(forKey: TransformDefaultsKey.rotationY)
            defaults.removeObject(forKey: TransformDefaultsKey.offsetY)
        }
    }
    
    /// 保存されたデフォルト視点を初期状態（工場出荷時）に戻し、現在の視点もリセットする
    public func resetDefaultTransformToFactory() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: TransformDefaultsKey.hasCustomDefault)
        defaults.removeObject(forKey: TransformDefaultsKey.scale)
        defaults.removeObject(forKey: TransformDefaultsKey.rotationY)
        defaults.removeObject(forKey: TransformDefaultsKey.offsetY)
        
        self.defaultScale = Self.factoryDefaultScale
        self.defaultRotationY = Self.factoryDefaultRotationY
        self.defaultOffsetY = Self.factoryDefaultOffsetY
        self.hasCustomDefaultTransform = false
        
        resetTransformWithAnimation()
    }
    
    public func checkCustomAvatarStatus() {
        self.hasCustomAvatar = FileManager.default.fileExists(atPath: customVRMURL.path)
    }
    
    public func setup(root: Entity) {
        self.rootEntity = root
        setupLighting(in: root)
        startBlinkLoop()
    }
    
    private func setupLighting(in root: Entity) {
        // キーライト (DirectionalLight)
        let directionalLight = DirectionalLight()
        directionalLight.light.color = .white
        directionalLight.light.intensity = 1500
        directionalLight.transform.translation = SIMD3<Float>(0.5, 2.0, 1.5)
        directionalLight.look(at: SIMD3<Float>(0, 1.3, 0), from: SIMD3<Float>(0.5, 2.0, 1.5), relativeTo: nil)
        root.addChild(directionalLight)
        
        // フィルライト
        let fillLight = DirectionalLight()
        fillLight.light.color = .init(white: 0.9, alpha: 1.0)
        fillLight.light.intensity = 800
        fillLight.transform.translation = SIMD3<Float>(-0.8, 1.5, 1.0)
        fillLight.look(at: SIMD3<Float>(0, 1.3, 0), from: SIMD3<Float>(-0.8, 1.5, 1.0), relativeTo: nil)
        root.addChild(fillLight)
    }
    
    public func resetTransform() {
        self.scale = defaultScale
        self.rotationY = defaultRotationY
        self.positionOffset = SIMD3<Float>(0, defaultOffsetY, 0)
        updateEntityTransform()
    }
    
    /// アニメーション付きで視点（スケール、回転、オフセット）をデフォルト位置へリセット
    public func resetTransformWithAnimation() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            resetTransform()
        }
    }
    
    public func loadInitialAvatar() async {
        checkCustomAvatarStatus()
        if hasCustomAvatar {
            await loadAvatar(from: customVRMURL)
        } else {
            await loadDefaultAvatar()
        }
    }
    
    public func importCustomAvatar(from sourceURL: URL) async throws {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secured {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        
        isLoading = true
        loadError = nil
        
        let data: Data
        do {
            data = try await Self.performFileOperation {
                try Data(contentsOf: sourceURL)
            }
        } catch {
            isLoading = false
            loadError = "VRMファイルの読み出しに失敗しました: \(error.localizedDescription)"
            throw error
        }
        
        guard !data.isEmpty else {
            isLoading = false
            let err = NSError(domain: "VRM", code: -1, userInfo: [NSLocalizedDescriptionKey: "VRMファイルが空です。"])
            loadError = err.localizedDescription
            throw err
        }
        
        // ローカルに永続化保存
        do {
            let destinationURL = customVRMURL
            try await Self.performFileOperation {
                // Atomic replacement also keeps the previous model if writing fails.
                try data.write(to: destinationURL, options: .atomic)
            }
            checkCustomAvatarStatus()
        } catch {
            isLoading = false
            loadError = "VRMファイルの保存に失敗しました: \(error.localizedDescription)"
            throw error
        }
        
        // ローカルURLからロード
        await loadAvatar(from: customVRMURL)
    }
    
    public func resetToDefaultAvatar() async {
        if FileManager.default.fileExists(atPath: customVRMURL.path) {
            try? FileManager.default.removeItem(at: customVRMURL)
        }
        checkCustomAvatarStatus()
        await loadDefaultAvatar()
    }
    
    public func loadAvatar(from url: URL) async {
        guard let root = rootEntity else { return }
        let loadID = UUID()
        avatarLoadID = loadID
        
        isLoading = true
        loadError = nil
        
        // 既存モデルのクリーンアップ
        if let current = vrmEntity {
            current.removeFromParent()
            vrmEntity = nil
            isLoaded = false
        }
        
        do {
            // File I/O and GLB/JSON parsing must not block gesture handling on MainActor.
            // VRM is Sendable; RealityKit entity creation stays on MainActor.
            let vrm = try await Self.performFileOperation {
                try VRM(withURL: url)
            }
            guard avatarLoadID == loadID else { return }
            // モバイル画面に最適なテクスチャ上限 (1024px) を指定し、2048x2048 等の巨大テクスチャによる GPU メモリ圧迫を大幅に削減
            let loader = VRMEntityLoader(vrm: vrm, shaders: [], maxTextureDimension: 1024)
            let entity = try await loader.loadEntity()
            try Task.checkCancellation()
            guard avatarLoadID == loadID else { return }
            
            root.addChild(entity)
            self.vrmEntity = entity
            self.isLoaded = true
            self.isLoading = false
            
            // 1. ボーン初期姿勢の保存 & 顔の高さ（ズーム中心アンカー）の取得
            restBonePoses.removeAll()
            self.focusHeadY = 1.25
            let bonesToTrack: [HumanoidBone] = [
                .spine, .chest, .neck, .head,
                .leftShoulder, .rightShoulder,
                .leftUpperArm, .rightUpperArm,
                .leftLowerArm, .rightLowerArm,
                .leftHand, .rightHand
            ]
            for bone in bonesToTrack {
                if let node = entity.humanoid.node(for: bone),
                   let nodeIndex = entity.nodeIndex(of: node) {
                    let restRot = entity.pose?.localTransform(ofNode: nodeIndex).rotation ?? node.transform.rotation
                    restBonePoses[bone] = (nodeIndex: nodeIndex, rotation: restRot)
                    if bone == .head {
                        let relativePos = node.position(relativeTo: entity)
                        if relativePos.y > 0.5 {
                            self.focusHeadY = relativePos.y
                        }
                    }
                }
            }
            
            // 全 153 ボーン Entity の毎フレーム Transform 同期を無効化し、GLTFPose 直接更新のみで GPU スキニングを駆動
            entity.nodeEntitySynchronization = .nodes([])
            // ProMotion (120Hz) 端末での過剰な物理・スキニング更新を 60fps (音声合成中は 30fps) に制御
            entity.minimumUpdateInterval = isSynthesisThrottled ? (1.0 / 30.0) : (1.0 / 60.0)
            
            // 2. 視線追従 (LookAt): 画面中央のカメラ・ユーザー位置（Z=0.1付近）を常に見つめる
            entity.lookAtTarget = .position(SIMD3<Float>(0, 0, 0.1))
            
            // 3. 待機モーション更新ハンドラ（毎フレーム実行）の登録
            entity.setUpdateHandler({ [weak self] deltaTime in
                self?.updateIdleMotion(deltaTime: deltaTime)
            }, at: .afterAnimation)
            
            // 4. トランスフォームと立ちポーズの初期適用
            updateEntityTransform()
            updateIdleMotion(deltaTime: 0)
        } catch {
            guard avatarLoadID == loadID else { return }
            self.isLoading = false
            if !(error is CancellationError) {
                self.loadError = "VRMの読み込みに失敗しました: \(error.localizedDescription)"
            }
        }
    }

    /// Explicitly detach blocking work; a Task created on MainActor would still block UI.
    nonisolated private static func performFileOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }
    
    public func loadDefaultAvatar() async {
        if let defaultURL = Bundle.main.url(forResource: "default_avatar", withExtension: "vrm") {
            await loadAvatar(from: defaultURL)
        } else {
            loadError = "デフォルトのVRMモデルが見つかりません。"
        }
    }
    
    /// スケール・回転・オフセット・呼吸を反映した現在ワールド位置
    /// 顔（頭部アンカー）を中心に拡大縮小するよう、拡大率に合わせてベース高さを自動補正
    private var calculatedPosition: SIMD3<Float> {
        let scaleHeadCompensationY = -focusHeadY * (scale - 1.0)
        let targetY = defaultBasePosition.y + scaleHeadCompensationY + positionOffset.y + currentBreathOffsetY
        return SIMD3<Float>(defaultBasePosition.x + positionOffset.x, targetY, defaultBasePosition.z + positionOffset.z)
    }
    
    // MARK: - トランスフォーム更新（拡大・縮小・回転・位置＋呼吸オフセット）
    private func updateEntityTransform() {
        guard let entity = vrmEntity else { return }
        
        entity.position = calculatedPosition
        entity.orientation = simd_quatf(angle: rotationY, axis: SIMD3<Float>(0, 1, 0))
        entity.scale = SIMD3<Float>(repeating: scale)
    }
    
    /// 音声合成 (GPU 推論) 実行中の VRM 更新頻度を 30fps にスロットリングして GPU 競合を抑える
    public func setSynthesisThrottling(_ enabled: Bool) {
        if isSynthesisThrottled != enabled {
            ConversationPerformance.event(enabled ? "VRM throttle enabled" : "VRM throttle disabled")
        }
        isSynthesisThrottled = enabled
        vrmEntity?.minimumUpdateInterval = enabled ? (1.0 / 30.0) : (1.0 / 60.0)
    }
    
    // MARK: - 待機モーション (Idle Motion: 自然な立ち姿 + 呼吸・体幹揺らぎ・腕の脱力スイング)
    private func updateIdleMotion(deltaTime: TimeInterval) {
        guard let entity = vrmEntity, let pose = entity.pose else { return }
        idleTime += deltaTime
        
        // 呼吸周期（約3.6秒周期）
        let breathTime = idleTime * 1.75
        let breathValue = sin(breathTime)
        
        // 体幹の緩やかな揺らぎ（Sway: 約5.5秒周期 & 7秒周期）
        let swayTime1 = idleTime * 1.15
        let swayValue1 = sin(swayTime1)
        let swayTime2 = idleTime * 0.65
        let swayValue2 = cos(swayTime2)
        
        // 1. 胸部（Chest / Spine）の呼吸ピッチ回転 & わずかな左右揺らぎ
        let chestPitch = Float(breathValue) * 0.02 // 約1.1度
        let chestRoll = Float(swayValue1) * 0.006
        let chestDelta = simd_quatf(angle: chestPitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: chestRoll, axis: SIMD3<Float>(0, 0, 1))
        
        if let rest = restBonePoses[.chest] {
            pose.setLocalRotation(rest.rotation * chestDelta, ofNode: rest.nodeIndex)
        } else if let rest = restBonePoses[.spine] {
            pose.setLocalRotation(rest.rotation * chestDelta, ofNode: rest.nodeIndex)
        }
        
        // 2. 頭部（Head）: 呼吸の反動、小首傾げ、およびモデル回転に対する視線サポート
        let headCameraAlign = -rotationY * 0.22
        let headPitch = Float(-breathValue) * 0.012
        let headRoll = Float(-swayValue1) * 0.015
        let headYaw = Float(swayValue2) * 0.01 + headCameraAlign
        
        let headDelta = simd_quatf(angle: headPitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: headRoll, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: headYaw, axis: SIMD3<Float>(0, 1, 0))
        
        if let rest = restBonePoses[.head] {
            pose.setLocalRotation(rest.rotation * headDelta, ofNode: rest.nodeIndex)
        }
        
        // 3. 両肩（Shoulders）: 呼吸の吸気で少し上がり、呼気で脱力
        let shoulderLift = Float(breathValue) * 0.012
        let leftShoulderDelta = simd_quatf(angle: shoulderLift, axis: SIMD3<Float>(0, 0, 1))
        let rightShoulderDelta = simd_quatf(angle: -shoulderLift, axis: SIMD3<Float>(0, 0, 1))
        
        if let rest = restBonePoses[.leftShoulder] {
            pose.setLocalRotation(rest.rotation * leftShoulderDelta, ofNode: rest.nodeIndex)
        }
        if let rest = restBonePoses[.rightShoulder] {
            pose.setLocalRotation(rest.rotation * rightShoulderDelta, ofNode: rest.nodeIndex)
        }
        
        // 4. 自然な立ちポーズ（Tポーズの解除）＋腕の待機スイング
        // ベース角度: Tポーズの真横から腕を下ろす（約 -70度 / +70度）
        // 呼吸・体幹揺らぎに応じて、腕が自然に前後・内外に微動する
        let leftArmSwingZ = -1.22 + Float(breathValue) * 0.015 // 呼吸による腕の自然な開閉
        let leftArmSwingX = 0.12 + Float(swayValue1) * 0.015  // 体幹揺らぎによる前後スイング
        let leftArmRot = simd_quatf(angle: leftArmSwingZ, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: leftArmSwingX, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: -0.06, axis: SIMD3<Float>(0, 1, 0))
        
        let rightArmSwingZ = 1.22 - Float(breathValue) * 0.015
        let rightArmSwingX = 0.12 + Float(swayValue1) * 0.015
        let rightArmRot = simd_quatf(angle: rightArmSwingZ, axis: SIMD3<Float>(0, 0, 1))
            * simd_quatf(angle: rightArmSwingX, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: 0.06, axis: SIMD3<Float>(0, 1, 0))
        
        if let rest = restBonePoses[.leftUpperArm] {
            pose.setLocalRotation(rest.rotation * leftArmRot, ofNode: rest.nodeIndex)
        }
        if let rest = restBonePoses[.rightUpperArm] {
            pose.setLocalRotation(rest.rotation * rightArmRot, ofNode: rest.nodeIndex)
        }
        
        // 5. 前腕（LowerArm / 肘）: 肘を軽く曲げてリラックス
        let leftElbowRot = simd_quatf(angle: -0.28 + Float(swayValue2) * 0.01, axis: SIMD3<Float>(0, 1, 0))
        let rightElbowRot = simd_quatf(angle: 0.28 - Float(swayValue2) * 0.01, axis: SIMD3<Float>(0, 1, 0))
        
        if let rest = restBonePoses[.leftLowerArm] {
            pose.setLocalRotation(rest.rotation * leftElbowRot, ofNode: rest.nodeIndex)
        }
        if let rest = restBonePoses[.rightLowerArm] {
            pose.setLocalRotation(rest.rotation * rightElbowRot, ofNode: rest.nodeIndex)
        }
        
        // 6. 手首（Hands）: 自然な脱力
        let leftHandRot = simd_quatf(angle: -0.05, axis: SIMD3<Float>(0, 0, 1))
        let rightHandRot = simd_quatf(angle: 0.05, axis: SIMD3<Float>(0, 0, 1))
        if let rest = restBonePoses[.leftHand] {
            pose.setLocalRotation(rest.rotation * leftHandRot, ofNode: rest.nodeIndex)
        }
        if let rest = restBonePoses[.rightHand] {
            pose.setLocalRotation(rest.rotation * rightHandRot, ofNode: rest.nodeIndex)
        }
        
        // 7. 全身の呼吸上下動（約4mm）: 変化が閾値以上のときのみルート Entity の位置を更新
        let newBreathOffsetY = Float(breathValue) * 0.004
        if abs(newBreathOffsetY - currentBreathOffsetY) > 0.0002 {
            currentBreathOffsetY = newBreathOffsetY
            entity.position = calculatedPosition
        }
    }
    
    // MARK: - 口パク (Lip Sync)
    public func setMouthOpen(value: Float) {
        guard let entity = vrmEntity else { return }
        let clamped = CGFloat(min(max(value, 0.0), 1.0))
        entity.setExpression(value: clamped, for: .preset(.aa))
    }
    
    // MARK: - まばたき (Blink)
    private func startBlinkLoop() {
        blinkTask?.cancel()
        blinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let intervalSec = Double.random(in: 2.5...5.0)
                try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { break }
                await self.performBlinkAnimation()
            }
        }
    }
    
    private func performBlinkAnimation() async {
        guard let entity = vrmEntity, !isBlinking else { return }
        isBlinking = true
        
        // 閉じる (約60ms)
        let closeSteps = 3
        for step in 1...closeSteps {
            guard !Task.isCancelled else { break }
            let weight = CGFloat(step) / CGFloat(closeSteps)
            entity.setExpression(value: weight, for: .preset(.blink))
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        
        // 開く (約80ms)
        for step in (0..<closeSteps).reversed() {
            guard !Task.isCancelled else { break }
            let weight = CGFloat(step) / CGFloat(closeSteps)
            entity.setExpression(value: weight, for: .preset(.blink))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        
        entity.setExpression(value: 0.0, for: .preset(.blink))
        isBlinking = false
    }
    
    deinit {
        blinkTask?.cancel()
    }
}
