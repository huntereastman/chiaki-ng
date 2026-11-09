// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CoreGraphics
import RealityKit

@main enum LightingRuntimeSupportTests {
    @MainActor static func main() async throws {
        let symbols = LightingRuntimeSupport.projectiveSymbols + LightingRuntimeSupport.surroundingsSymbols
        let complete = LightingRuntimeSupport { symbols.contains($0) }
        precondition(complete.projectiveTexture && complete.surroundingsLight)
        for missing in symbols {
            let partial = LightingRuntimeSupport { symbols.contains($0) && $0 != missing }
            precondition(partial.projectiveTexture == !LightingRuntimeSupport.projectiveSymbols.contains(missing))
            precondition(partial.surroundingsLight == !LightingRuntimeSupport.surroundingsSymbols.contains(missing))
            precondition(partial.missingSymbols == [missing])
        }
        // Reproduce the crash condition: metadata/initializer exist, but the
        // new Swift conformance does not. It must never enter Component.set.
        let beta = LightingRuntimeSupport { !$0.contains("ImplicitlyAnimatable") }
        precondition(!beta.projectiveTexture && beta.surroundingsLight)
        let texture = try await TextureResource(image: CGImage.empty(), options: .init(semantic: .color))
        let entity = Entity()
        let count = entity.components.count
        beta.applyProjectiveTexture(texture, to: entity)
        precondition(entity.components.count == count)
        let absent = LightingRuntimeSupport { _ in false }
        absent.applySurroundingsLight(true, to: entity)
        absent.applySurroundingsLight(false, to: entity)
        precondition(entity.components.count == count)
        print("Lighting runtime checks passed: six missing exports, absent conformance, and safe component omission.")
    }
}

private extension CGImage {
    static func empty() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
