// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Metal
import RealityKit
import SwiftUI
import simd

// The completion callback only touches this locked receipt, never scene entities.
final class ExtremeGPUReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0, failed = 0
    private var milliseconds = 0.0
    func record(_ buffer: MTLCommandBuffer) {
        lock.lock(); defer { lock.unlock() }
        if buffer.status == .completed { completed += 1 } else { failed += 1 }
        if buffer.gpuEndTime > buffer.gpuStartTime {
            milliseconds = (buffer.gpuEndTime-buffer.gpuStartTime)*1000
        }
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["gpuFramesCompleted": completed, "gpuFramesFailed": failed, "lastGPUWorkMS": milliseconds]
    }
}

/// Four real, GPU-deformed light sheets and three coordinated room projections.
/// Streaming, decoding and the Simple renderer keep their existing ownership.
@available(visionOS 2.0, macOS 15.0, *)
@MainActor final class ExtremeLightRig {
    let root = Entity()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let vertexPipeline: MTLComputePipelineState
    private let sheetPipeline: MTLComputePipelineState
    private let projectionPipeline: MTLComputePipelineState
    private var meshes: [LowLevelMesh] = []
    private var sheetTextures: [LowLevelTexture] = []
    private var projectionTextures: [LowLevelTexture] = []
    private var lights: [Entity] = []
    private let inFlight = DispatchSemaphore(value: 2)
    private let receipt = ExtremeGPUReceipt()
    private var palette = AmbientPalette.black
    private var enabled = false
    private var roomAllowed = false
    private var reduceMotion = false
    private var screenWidth: Float = 1.718
    private var time = 0.0, accumulated = 0.0
    private var submitted = 0, skipped = 0
    private var runtimeError = false
    private var subscription: EventSubscription?
    private var lastRoomActive = false
    private var lastReceiptTime = 0.0
    private(set) var ready = false

    enum Failure: LocalizedError {
        case device, function(String)
        var errorDescription: String? {
            switch self {
            case .device: return "The lighting renderer could not start."
            case .function(let name): return "Missing lighting shader: \(name)."
            }
        }
    }

    init(libraryURL: URL? = nil) async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.device }
        self.device = device; self.queue = queue
        let library = try libraryURL.map { try device.makeLibrary(URL: $0) } ?? device.makeDefaultLibrary(bundle: .main)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw Failure.function(name) }
            return try device.makeComputePipelineState(function: function)
        }
        vertexPipeline = try pipeline("extremeSheetVertices")
        sheetPipeline = try pipeline("extremeSheetTexture")
        projectionPipeline = try pipeline("extremeProjectionTexture")
        root.name = "Extreme light sheets"
        root.isEnabled = false

        // Additive emission avoids camera-dependent alpha sorting between sheets.
        // Texture alpha still feathers the density; RGB energy is bounded in Metal.
        var programDescription = UnlitMaterial.Program.Descriptor()
        programDescription.blendMode = .add
        programDescription.applyPostProcessToneMap = true
        let program = await UnlitMaterial.Program(descriptor: programDescription)
        for index in 0..<4 {
            let mesh = try Self.makeMesh()
            let texture = try Self.makeTexture(width: 512, height: 256)
            let resource = try await TextureResource(from: texture)
            var material = UnlitMaterial(program: program)
            material.color = .init(tint: .white, texture: .init(resource))
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.faceCulling = .none
            material.writesDepth = false
            material.readsDepth = true
            let entity = ModelEntity(mesh: try await MeshResource(from: mesh), materials: [material])
            entity.name = "Light sheet \(index)"
            root.addChild(entity)
            meshes.append(mesh); sheetTextures.append(texture)
        }
        for index in 0..<3 {
            let texture = try Self.makeTexture(width: 512, height: 512)
            let light = Entity()
            light.name = "Projected room light \(index)"
            light.components.set(SpotLightComponent(color: .white, intensity: 0,
                innerAngleInDegrees: 46, outerAngleInDegrees: 94, attenuationRadius: 3.8))
            if #available(visionOS 27.0, macOS 27.0, *) {
                light.components.set(SpotLightComponent.ProjectiveTexture(texture: try await TextureResource(from: texture)))
            }
            root.addChild(light); lights.append(light); projectionTextures.append(texture)
        }
        positionLights()
        // Initialize every GPU resource before RealityKit can make it visible.
        encode(force: true)
        ready = true
    }

    private static func makeTexture(width: Int, height: Int) throws -> LowLevelTexture {
        try LowLevelTexture(descriptor: .init(pixelFormat: .rgba16Float, width: width, height: height,
            textureUsage: [.shaderRead, .shaderWrite]))
    }
    private static func makeMesh() throws -> LowLevelMesh {
        let columns = 129, rows = 41
        let mesh = try LowLevelMesh(descriptor: .init(vertexCapacity: columns*rows,
            vertexAttributes: [.init(semantic: .position, format: .float3, offset: 0),
                               .init(semantic: .normal, format: .float3, offset: 12),
                               .init(semantic: .uv0, format: .float2, offset: 24)],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: 32)],
            indexCapacity: (columns-1)*(rows-1)*6, indexType: .uint32))
        mesh.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt32.self)
            var offset = 0
            for y in 0..<(rows-1) { for x in 0..<(columns-1) {
                let a = UInt32(y*columns+x), b = a+1, c = a+UInt32(columns), d = c+1
                for value in [a,b,c,b,d,c] { indices[offset] = value; offset += 1 }
            }}
        }
        mesh.parts.replaceAll([.init(indexCount: (columns-1)*(rows-1)*6,
            bounds: BoundingBox(min: [-5,-4,-2], max: [5,4,2]))])
        return mesh
    }
#if os(visionOS)
    func subscribe(to content: RealityViewContent, onDiagnostics: @escaping ([String: Any]) -> Void) {
        subscription?.cancel()
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            self.advance(deltaTime: event.deltaTime)
            let now = ProcessInfo.processInfo.systemUptime
            if now-self.lastReceiptTime >= 1 {
                self.lastReceiptTime = now
                onDiagnostics(self.diagnostics())
            }
        }
    }
#endif
    func setScreen(width: Float, center: SIMD3<Float>) {
        guard width.isFinite, width > 0.5, width < 5 else { return }
        root.position = center
        if abs(screenWidth-width)>0.002 { screenWidth = width; positionLights() }
    }
    private func positionLights() {
        guard lights.count == 3 else { return }
        let w = screenWidth
        lights[0].look(at: [-1.2*w,0.18*w,-0.95*w], from: [-0.34*w,0.10*w,-0.08*w], relativeTo: root)
        lights[1].look(at: [1.2*w,0.15*w,-0.95*w], from: [0.34*w,0.10*w,-0.08*w], relativeTo: root)
        lights[2].look(at: [0,-1.0*w,-0.55*w], from: [0,-0.30*w,-0.02*w], relativeTo: root)
    }
    func update(palette: AmbientPalette, enabled: Bool, roomAllowed: Bool, reduceMotion: Bool) {
        self.palette = palette; self.enabled = enabled; self.roomAllowed = roomAllowed
        self.reduceMotion = reduceMotion
        let thermal = ProcessInfo.processInfo.thermalState
        root.isEnabled = enabled && !runtimeError && thermal != .critical
        let roomActive = root.isEnabled && roomAllowed && palette.average.luminance > 0.0005
        if roomActive != lastRoomActive {
            lastRoomActive = roomActive
            for (index, light) in lights.enumerated() {
                var component = light.components[SpotLightComponent.self]!
                // Textured projections lose considerable energy through their
                // soft mask. Qualified in the native virtual-room preview;
                // physical surroundings brightness still needs headset review.
                component.intensity = roomActive ? (index == 2 ? 85000 : 150000) : 0
                light.components.set(component)
#if os(visionOS)
                if #available(visionOS 27.0, *) {
                    if roomActive { light.components.set(SpotLightComponent.SurroundingsLight()) }
                    else { light.components.remove(SpotLightComponent.SurroundingsLight.self) }
                }
#endif
            }
        }
        if !root.isEnabled { accumulated = 0 }
    }
    func advance(deltaTime: TimeInterval) {
        guard enabled, !runtimeError else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .critical else {
            update(palette: palette, enabled: enabled, roomAllowed: false, reduceMotion: reduceMotion)
            return
        }
        // Freeze phase under Reduce Motion; changing live colors still update.
        if !reduceMotion { time += min(0.1, max(0,deltaTime)) }
        accumulated += max(0,deltaTime)
        let interval = thermal == .nominal ? 1.0/60 : 1.0/30
        guard accumulated >= interval else { return }
        accumulated.formTruncatingRemainder(dividingBy: interval)
        encode(force: false)
    }
    private func parameters(index: Int) -> [SIMD4<Float>] {
        func vector(_ c: AmbientRGB) -> SIMD4<Float> { [c.red,c.green,c.blue,0] }
        let peak = max(palette.left.luminance, palette.right.luminance, palette.top.luminance, palette.bottom.luminance)
        let energy = min(1, max(0, peak*5))
        return [[Float(time),Float(index),screenWidth,1], vector(palette.left), vector(palette.right),
                vector(palette.top), vector(palette.bottom), [energy,1,0,0]]
    }
    private func encode(force: Bool) {
        guard force || (enabled && root.isEnabled) else { return }
        guard inFlight.wait(timeout: .now()) == .success else { skipped += 1; return }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            inFlight.signal(); runtimeError = true; root.isEnabled = false; return
        }
        command.label = "Extreme sheets and room projection"
        func dispatch(_ pipeline: MTLComputePipelineState, width: Int, height: Int) {
            encoder.setComputePipelineState(pipeline)
            let x = pipeline.threadExecutionWidth
            let y = min(8, pipeline.maxTotalThreadsPerThreadgroup/x)
            encoder.dispatchThreads(.init(width: width,height: height,depth: 1),
                                    threadsPerThreadgroup: .init(width: x,height: y,depth: 1))
        }
        for index in 0..<meshes.count {
            let values = parameters(index: index)
            encoder.setBuffer(meshes[index].replace(bufferIndex: 0, using: command),offset: 0,index: 0)
            values.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length: $0.count,index: 1) }
            dispatch(vertexPipeline,width: 129,height: 41)
            values.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length: $0.count,index: 0) }
            encoder.setTexture(sheetTextures[index].replace(using: command),index: 0)
            dispatch(sheetPipeline,width: 512,height: 256)
        }
        // No physical-light texture work while surroundings lighting is suppressed.
        if force || (roomAllowed && lastRoomActive) {
            for index in 0..<projectionTextures.count {
                let values = parameters(index: index)
                values.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length: $0.count,index: 0) }
                encoder.setTexture(projectionTextures[index].replace(using: command),index: 0)
                dispatch(projectionPipeline,width: 512,height: 512)
            }
        }
        encoder.endEncoding()
        let semaphore = inFlight, receipt = receipt
        command.addCompletedHandler { buffer in receipt.record(buffer); semaphore.signal() }
        command.commit(); submitted += 1
    }
    func diagnostics() -> [String: Any] {
        var value = receipt.snapshot()
        value["ready"] = ready; value["active"] = root.isEnabled
        value["framesSubmitted"] = submitted; value["framesSkipped"] = skipped
        value["sheetCount"] = meshes.count; value["roomLightsActive"] = lastRoomActive ? lights.count : 0
        value["screenWidthMeters"] = screenWidth; value["animationSeconds"] = time
        value["runtimeError"] = runtimeError
        return value
    }
    func stop() {
        update(palette: .black, enabled: false, roomAllowed: false, reduceMotion: reduceMotion)
        subscription?.cancel(); subscription = nil
    }
}
