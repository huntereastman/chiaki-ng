// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import RealityKit

/// Beta releases can report visionOS 27 while lacking the public API's current
/// Swift conformance. An OS-version check alone then reaches a nil witness table.
struct LightingRuntimeSupport {
    static let projectiveSymbols = [
        "$s10RealityKit18SpotLightComponentV0A10FoundationE17ProjectiveTextureV7textureAfA0H8ResourceC_tcfC",
        "$s10RealityKit18SpotLightComponentV0A10FoundationE17ProjectiveTextureVAD028_ImplicitlyAnimatableBuiltinE0ADMc",
        "$s10RealityKit18SpotLightComponentV0A10FoundationE17ProjectiveTextureVMa"
    ]
    static let surroundingsSymbols = [
        "$s10RealityKit18SpotLightComponentV0A10FoundationE012SurroundingsD0VAA0E0ADMc",
        "$s10RealityKit18SpotLightComponentV0A10FoundationE012SurroundingsD0VAFycfC",
        "$s10RealityKit18SpotLightComponentV0A10FoundationE012SurroundingsD0VMa"
    ]
    let projectiveTexture: Bool
    let surroundingsLight: Bool
    let missingSymbols: [String]

    init(lookup: (String) -> Bool) {
        missingSymbols = (Self.projectiveSymbols + Self.surroundingsSymbols).filter { !lookup($0) }
        projectiveTexture = Self.projectiveSymbols.allSatisfy(lookup)
        surroundingsLight = Self.surroundingsSymbols.allSatisfy(lookup)
    }
    static let current = LightingRuntimeSupport { symbol in
        // Check exported symbols of the public APIs; never invoke them through
        // these pointers. Fail closed if the SDK's ABI changes again.
        if #available(visionOS 27.0, macOS 27.0, *) {
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil
        }
        return false
    }

    @MainActor func applyProjectiveTexture(_ texture: TextureResource, to entity: Entity) {
        guard projectiveTexture else { return }
        if #available(visionOS 27.0, macOS 27.0, *) {
            Self.setProjectiveTexture(texture, on: entity)
        }
    }
    @MainActor func applySurroundingsLight(_ active: Bool, to entity: Entity) {
#if os(visionOS)
        guard surroundingsLight else { return }
        if #available(visionOS 27.0, *) {
            Self.setSurroundingsLight(active, on: entity)
        }
#endif
    }

    // Keep new-type metadata and witness access entirely behind the runtime
    // gate. Swift may otherwise resolve them at the beginning of a function,
    // before a conditional in that same function is evaluated.
    @available(visionOS 27.0, macOS 27.0, *)
    @inline(never) @MainActor private static func setProjectiveTexture(_ texture: TextureResource, on entity: Entity) {
        entity.components.set(SpotLightComponent.ProjectiveTexture(texture: texture))
    }
#if os(visionOS)
    @available(visionOS 27.0, *)
    @inline(never) @MainActor private static func setSurroundingsLight(_ active: Bool, on entity: Entity) {
        if active { entity.components.set(SpotLightComponent.SurroundingsLight()) }
        else { entity.components.remove(SpotLightComponent.SurroundingsLight.self) }
    }
#endif
}
