// SPDX-License-Identifier: AGPL-3.0-only
// Generates synthetic, independently decodable H.264 frames. No game footage or credentials.
import AVFoundation
import Foundation
import VideoToolbox

final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: Data] = [:]
    func store(_ index: Int, _ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var data = Data()
        for i in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
            data.append(contentsOf: [0, 0, 0, 1]); data.append(pointer, count: size)
        }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: &bytes) == noErr else { return }
        var offset = 0
        while offset + 4 <= size {
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, offset + length <= size else { return }
            data.append(contentsOf: [0, 0, 0, 1]); data.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        lock.lock(); frames[index] = data; lock.unlock()
    }
    func write(_ destination: URL, count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard frames.count == count else { fatalError("Incomplete synthetic encoding") }
        var file = Data("VRPA1".utf8)
        for i in 0..<count {
            let frame = frames[i]!
            var length = UInt32(frame.count).bigEndian
            file.append(withUnsafeBytes(of: &length) { Data($0) }); file.append(frame)
        }
        try file.write(to: destination, options: .atomic)
    }
}

@main enum GenerateAmbientFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass one fixture output path") }
        let width = 320, height = 180, count = 96
        let frames = EncodedFrames()
        var session: VTCompressionSession?
        precondition(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session) == noErr)
        let encoder = session!
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFNumber)
        for frame in 0..<count {
            var pixels: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess)
            let buffer = pixels!
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let t = (sin(Double(frame) / Double(count) * 2 * .pi) + 1) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let p = address.advanced(by: y * stride + x * 4)
                    let left = x < width / 2
                    let v = 0.45 + 0.55 * Double(y) / Double(height)
                    p[0] = UInt8((left ? 0.12 + 0.30 * t : 0.85 - 0.2 * t) * v * 255)
                    p[1] = UInt8((left ? 0.10 + 0.40 * t : 0.35 + 0.4 * t) * v * 255)
                    p[2] = UInt8((left ? 0.95 - 0.15 * t : 0.10 + 0.40 * t) * v * 255)
                    p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let index = frame
            precondition(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: Int64(frame), timescale: 24),
                duration: CMTime(value: 1, timescale: 24), frameProperties: nil,
                infoFlagsOut: nil) { status, _, sample in
                    if status == noErr, let sample { frames.store(index, sample) }
                } == noErr)
        }
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(encoder)
        try frames.write(URL(fileURLWithPath: CommandLine.arguments[1]), count: count)
        print("Generated \(count) synthetic H.264 proof frames.")
    }
}
