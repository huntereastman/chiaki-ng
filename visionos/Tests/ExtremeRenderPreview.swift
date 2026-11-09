// SPDX-License-Identifier: AGPL-3.0-only
// Renders the actual sheet mesh/material/compute path on the Mac. Not headset proof.
import AppKit
import CoreImage
import Foundation
import Metal
import RealityKit

@main enum ExtremeRenderPreview {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("metallib path and output directory required") }
        let output = URL(fileURLWithPath: CommandLine.arguments[2],isDirectory: true)
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        let effect = try await ExtremeLightRig(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let renderer = try RealityRenderer()
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 57
        camera.look(at: [0,0,0],from: [0,0.15,4.25],relativeTo: nil)
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.018,alpha: 1))
        let scene = Entity()
        scene.addChild(effect.root); scene.addChild(camera)
        func box(_ name: String, size: SIMD3<Float>, position: SIMD3<Float>, material: any Material) {
            let entity = ModelEntity(mesh: .generateBox(size: size),materials: [material])
            entity.name = name; entity.position = position; scene.addChild(entity)
        }
        let wall = SimpleMaterial(color: .init(white: 0.24,alpha: 1),roughness: 0.95,isMetallic: false)
        box("Virtual test wall",size: [6,4,0.04],position: [0,0.3,-1.25],material: wall)
        box("Virtual test floor",size: [6,0.04,4],position: [0,-1.25,0],material: wall)
        box("Blue fixture half",size: [0.859,0.967,0.02],position: [-0.4295,0,0],
            material: UnlitMaterial(color: .init(red: 0.04,green: 0.23,blue: 0.48,alpha: 1)))
        box("Amber fixture half",size: [0.859,0.967,0.02],position: [0.4295,0,0],
            material: UnlitMaterial(color: .init(red: 0.62,green: 0.29,blue: 0.06,alpha: 1)))
        renderer.entities.append(scene)
        let device = MTLCreateSystemDefaultDevice()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: 1600,height: 1000,mipmapped: false)
        descriptor.usage = [.renderTarget,.shaderRead,.shaderWrite]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let cameraOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        let palette = AmbientPalette(left: .init(red: 0.02,green: 0.26,blue: 0.70),
            right: .init(red: 0.85,green: 0.32,blue: 0.045),top: .init(red: 0.22,green: 0.21,blue: 0.45),
            bottom: .init(red: 0.27,green: 0.18,blue: 0.18))
        effect.update(palette: palette,enabled: true,roomAllowed: true,reduceMotion: false)
        let context = CIContext()
        func render() async throws {
            effect.advance(deltaTime: 1.0/60)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0/60,cameraOutput: cameraOutput,
                        onComplete: { _ in continuation.resume() })
                } catch { continuation.resume(throwing: error) }
            }
        }
        func save(_ name: String) throws {
            let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
            let source = CIImage(mtlTexture: texture,options: [.colorSpace: space])!
            let flipped = source.transformed(by: CGAffineTransform(translationX: 0,y: 1000).scaledBy(x: 1,y: -1))
            try context.writePNGRepresentation(of: flipped,to: output.appendingPathComponent(name),format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,options: [:])
        }
        for _ in 0..<5 { try await render() }
        try save("extreme-native-front.png")
        for _ in 0..<115 { try await render() }
        try save("extreme-native-motion.png")
        camera.look(at: [0,0,0],from: [0.55,0.28,3.9],relativeTo: nil)
        for _ in 0..<3 { try await render() }
        try save("extreme-native-angle.png")
        let diagnostics = effect.diagnostics()
        precondition((diagnostics["gpuFramesCompleted"] as? Int ?? 0)>0)
        precondition(diagnostics["gpuFramesFailed"] as? Int == 0)
        effect.stop()
        let before = effect.diagnostics()["framesSubmitted"] as? Int
        effect.advance(deltaTime: 1)
        precondition(effect.diagnostics()["framesSubmitted"] as? Int == before,"Off must stop GPU submissions")
        try JSONSerialization.data(withJSONObject: diagnostics,options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("extreme-native-render.json"))
        print("Native Extreme rendering, GPU completion and off-state checks passed.")
    }
}
