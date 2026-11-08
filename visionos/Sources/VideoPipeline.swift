// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import QuartzCore
import SwiftUI

final class VideoPipeline {
    private let lock = NSLock()
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var origin = CACurrentMediaTime()
    private(set) var acceptedFrames = 0
    private(set) var lostFrames = 0
    private(set) var lastError: String?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); defer { lock.unlock() }
        displayLayer = layer
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        sps = nil; pps = nil; format = nil
        acceptedFrames = 0; lostFrames = 0; lastError = nil
        origin = CACurrentMediaTime()
        displayLayer?.flushAndRemoveImage()
    }
    func snapshot() -> (frames: Int, lost: Int, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (acceptedFrames, lostFrames, lastError)
    }
    func consume(_ data: Data, lost: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= 16 * 1024 * 1024 else { return false }
        lostFrames += max(0, Int(lost))
        let units = AnnexB.units(data)
        guard !units.isEmpty else { return false }
        var imageUnits: [Data] = []
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1f {
            case 7: if sps != unit { sps = unit; format = nil }
            case 8: if pps != unit { pps = unit; format = nil }
            case 1, 5, 6, 9: imageUnits.append(unit)
            default: break
            }
        }
        if format == nil, let sps, let pps {
            let result = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p -> OSStatus in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            } }
            if result != noErr { lastError = "Video format error (\(result))."; return false }
        }
        guard imageUnits.contains(where: { ($0.first! & 0x1f) == 1 || ($0.first! & 0x1f) == 5 }) else { return true }
        guard let format, let layer = displayLayer else { return false }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(); lastError = "Video renderer reset." }
        guard renderer.isReadyForMoreMediaData else { return false }
        let payload = AnnexB.lengthPrefixed(imageUnits)
        var block: CMBlockBuffer?
        var result = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block)
        guard result == noErr, let block else { return false }
        result = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard result == noErr else { return false }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime() - origin, preferredTimescale: 90000),
            decodeTimeStamp: .invalid)
        var size = payload.count
        result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard result == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        acceptedFrames += 1
        lastError = nil
        return true
    }
}

final class StreamSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct StreamView: UIViewRepresentable {
    let pipeline: VideoPipeline
    func makeUIView(context: Context) -> StreamSurface {
        let view = StreamSurface(frame: .zero)
        pipeline.attach(view.videoLayer)
        return view
    }
    func updateUIView(_ uiView: StreamSurface, context: Context) {}
}
