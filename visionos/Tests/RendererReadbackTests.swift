// SPDX-License-Identifier: AGPL-3.0-only
// Native macOS probe of the same compressed renderer. No simulator or device UI.
import AVFoundation
import AppKit
import Foundation
import ImageIO
import SwiftUI

@main enum RendererReadbackTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let video = VideoPipeline(), sampler = AmbientPaletteSampler()
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        video.attach(layer)
        let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var offset = 5, reads = 0
        var rendererRate: Double?
        var previewPixels: CVPixelBuffer?
        for _ in 0..<24 {
            let count = file[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            _ = video.consume(file.subdata(in: offset..<(offset + count)), lost: 0)
            offset += count
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            let current = video.ambientFrame(includePixels: true)
            rendererRate = current?.rendererRate
            if let frame = current, let pixels = frame.pixels,
               let palette = sampler.sample(pixels) {
                reads += 1
                if previewPixels == nil { previewPixels = pixels }
                if reads == 1 {
                    print("Readback rate:", frame.rendererRate ?? -1,
                          "left RGB:", palette.left, "right RGB:", palette.right)
                }
                precondition(palette.left.red > palette.left.blue, "Fixture left must stay warm")
                precondition(palette.right.blue > palette.right.red, "Fixture right must stay cool")
            }
        }
        print("Compressed frames accepted:", video.snapshot().frames, "pixel buffers read:", reads,
              "renderer rate:", rendererRate ?? -1)
        if reads == 0 {
            print("Native readback unavailable; checking the single-decoder fallback with the same H.264 source.")
            video.requestDecodedAmbientFrames()
            for _ in 0..<24 {
                let count = file[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                _ = video.consume(file.subdata(in: offset..<(offset + count)), lost: 0)
                offset += count
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                if let frame = video.ambientFrame(includePixels: true), let pixels = frame.pixels,
                   let palette = sampler.sample(pixels) {
                    precondition(frame.source == "shared-decoder")
                    precondition(palette.left.red > palette.left.blue)
                    precondition(palette.right.blue > palette.right.red)
                    reads += 1
                    if previewPixels == nil { previewPixels = pixels }
                }
            }
            precondition(reads >= 10, "Single decode must produce a continuing sequence of fresh color buffers")
            print("Shared-decoder buffers read:", reads, "display enqueues:", video.snapshot().frames)
        }
        if CommandLine.arguments.count > 2, let previewPixels,
           let palette = sampler.sample(previewPixels) {
            let source = CIImage(cvPixelBuffer: previewPixels)
            let picture = CIContext().createCGImage(source, from: source.extent)!
            let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for enabled in [true, false] {
                // Actual shared halo component, synthetic decoded video. Not a headset capture.
                let composition = ZStack {
                    LinearGradient(colors: [Color(white: 0.025), Color(white: 0.008)], startPoint: .top, endPoint: .bottom)
                    if enabled { AmbientHalo(palette: palette).frame(width: 1460, height: 900) }
                    Image(decorative: picture, scale: 1).resizable()
                        .frame(width: 1180, height: 663.75).clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.65), radius: 28, y: 18)
                }.frame(width: 1580, height: 1060)
                let renderer = ImageRenderer(content: composition)
                renderer.scale = 1
                if let image = renderer.cgImage {
                    let path = folder.appendingPathComponent(enabled ? "ambient-on-preview.png" : "ambient-off-preview.png")
                    let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, image, nil)
                    precondition(CGImageDestinationFinalize(destination))
                }
            }
        }
        video.reset()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(video.snapshot().frames == 0, "Late decoder output must not leak into a reset session")
        precondition(video.ambientFrame(includePixels: true)?.pixels == nil, "Reset must discard held color buffers")
        let replacement = AVSampleBufferDisplayLayer()
        video.attach(replacement); video.detach(layer)
        precondition(video.ambientFrame(includePixels: false) != nil, "Old surface removal must not detach the replacement")
        video.detach(replacement)
        precondition(video.ambientFrame(includePixels: false) == nil, "Final surface must detach")
        print("Native H.264-to-color integration, reset and surface transfer passed. Headset qualification remains separate.")
    }
}
