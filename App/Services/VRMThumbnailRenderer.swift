import Foundation
import RealityKit
import Metal
import CoreGraphics

public enum VRMThumbnailError: LocalizedError {
    case metalUnavailable

    public var errorDescription: String? {
        "顔写真の撮影に Metal を利用できませんでした。"
    }
}

/// 読み込み済みのVRMを画面外で描き、顔のアップを撮る。
/// 表示中の Entity は複製して使う。メッシュは元と共有されるので、複製しても今のポーズのまま写る。
@available(iOS 18.0, *)
@MainActor
enum VRMThumbnailRenderer {
    static func render(_ source: Entity, faceCenterY: Float, size: Int = 384) async throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw VRMThumbnailError.metalUnavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw VRMThumbnailError.metalUnavailable }

        let renderer = try RealityRenderer()
        // 一覧カードと同じパステル背景
        renderer.cameraSettings.colorBackground = .color(CGColor(srgbRed: 0.99, green: 0.92, blue: 0.95, alpha: 1))

        let scene = Entity()
        let model = source.clone(recursive: true)
        model.transform = .identity
        scene.addChild(model)

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 24
        let target = SIMD3<Float>(0, faceCenterY, 0)
        camera.look(at: target, from: target + SIMD3<Float>(0, 0.01, 0.85), relativeTo: nil)
        scene.addChild(camera)

        // 会話画面のキーライト・フィルライトと同じ向き
        for (position, intensity) in [(SIMD3<Float>(0.5, 0.6, 1.5), Float(1500)), (SIMD3<Float>(-0.8, 0.3, 1.0), Float(800))] {
            let light = DirectionalLight()
            light.light.intensity = intensity
            light.look(at: target, from: target + position, relativeTo: nil)
            scene.addChild(light)
        }

        renderer.entities.append(scene)
        renderer.activeCamera = camera
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        // 1フレーム目はリソースの初回転送が混じるので2回描く
        for _ in 0..<2 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: output, onComplete: { _ in
                        continuation.resume()
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        renderer.entities.removeAll()
        return try makeImage(from: texture)
    }

    private static func makeImage(from texture: MTLTexture) throws -> CGImage {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw VRMThumbnailError.metalUnavailable
        }
        return image
    }
}
