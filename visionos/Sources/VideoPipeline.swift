// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import QuartzCore
import SwiftUI
import VideoToolbox

// Mutable decode/display state is protected by lock; VT outputs enter through outputQueue.
final class VideoPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var origin = CACurrentMediaTime()
    private var lastVideoTime = 0.0
    private var generation: UInt64 = 0
    private let outputQueue = DispatchQueue(label: "visionremote.video-output", qos: .userInteractive)
    private var decoder: VTDecompressionSession?
    private var decodeRequested = false
    private var decodedMode = false
    private var decoderUnavailable = false
    private var waitingForKeyframe = false
    private var pendingDecodes = 0
    private var decodedPixels: CVPixelBuffer?
    private var decodedSequence: UInt64 = 0
    private var submittedSequence: UInt64 = 0
    private var decoderError: OSStatus = noErr
    private(set) var acceptedFrames = 0
    private(set) var lostFrames = 0
    private(set) var lastError: String?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); defer { lock.unlock() }
        displayLayer = layer
    }
    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); defer { lock.unlock() }
        if displayLayer === layer { displayLayer = nil }
    }
    struct AmbientFrame {
        let pixels: CVPixelBuffer?
        let lastVideoTime: Double
        let generation: UInt64
        let rendererRate: Double?
        let source: String
        let decoderStatus: Int32
    }
    func requestDecodedAmbientFrames() {
        guard lock.try() else { return }
        if !decoderUnavailable { decodeRequested = true }
        lock.unlock()
    }
    @MainActor func ambientFrame(includePixels: Bool) -> AmbientFrame? {
        // Never wait for the transport's enqueue lock to collect an optional color sample.
        guard lock.try() else { return nil }
        let layer = displayLayer, timestamp = lastVideoTime, currentGeneration = generation
        let directPixels = decodedPixels, isDecoded = decodedMode
        let currentDecoderStatus = decoderError
        lock.unlock()
        guard let layer else { return nil }
        let renderer = layer.sampleBufferRenderer
        return AmbientFrame(pixels: includePixels ? (isDecoded ? directPixels : renderer.displayedPixelBuffer()) : nil,
            lastVideoTime: timestamp, generation: currentGeneration,
            rendererRate: includePixels ? CMTimebaseGetRate(renderer.timebase) : nil,
            source: isDecoded ? "shared-decoder" : "renderer", decoderStatus: currentDecoderStatus)
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        sps = nil; pps = nil; format = nil
        acceptedFrames = 0; lostFrames = 0; lastError = nil
        origin = CACurrentMediaTime()
        lastVideoTime = 0; generation &+= 1
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; decodedPixels = nil; pendingDecodes = 0
        decodeRequested = false; decodedMode = false; decoderUnavailable = false
        waitingForKeyframe = false; decoderError = noErr
        submittedSequence = 0; decodedSequence = 0
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
            case 7: if sps != unit { sps = unit; format = nil; invalidateDecoderFormat() }
            case 8: if pps != unit { pps = unit; format = nil; invalidateDecoderFormat() }
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
        if decodeRequested && !decodedMode && !decoderUnavailable {
            // Flush the renderer's compressed decode path before submitting anything to VT.
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            decodedMode = true; waitingForKeyframe = true
            generation &+= 1; lastVideoTime = 0
        }
        if decodedMode && waitingForKeyframe && !imageUnits.contains(where: { ($0.first! & 0x1f) == 5 }) {
            return false // The transport's existing corrupt-frame response requests a fresh IDR.
        }
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
        if decodedMode { return decode(sample, format: format) }
        markImmediate(sample)
        renderer.enqueue(sample)
        acceptedFrames += 1
        lastVideoTime = CACurrentMediaTime()
        lastError = nil
        return true
    }
    private func markImmediate(_ sample: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
    private func invalidateDecoderFormat() {
        guard decodedMode else { return }
        generation &+= 1
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; decodedPixels = nil; pendingDecodes = 0
        waitingForKeyframe = true
    }
    // Called only while holding lock. Completion never tries to acquire that lock synchronously.
    private func decode(_ sample: CMSampleBuffer, format: CMVideoFormatDescription) -> Bool {
        if decoder == nil {
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey: true]
            let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                formatDescription: format, decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &decoder)
            guard result == noErr, let decoder else {
                decoderError = result; decoderUnavailable = true
                decodedMode = false; decodeRequested = false
                return false
            }
            VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        }
        guard let decoder, pendingDecodes < 3 else { return false }
        pendingDecodes += 1; submittedSequence &+= 1
        let token = generation, sequence = submittedSequence
        let result = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { [weak self] status, _, pixels, _, _ in
                guard let self else { return }
                let frame = pixels.map { AmbientReadOnlyPixels(buffer: $0) }
                self.outputQueue.async { [weak self, frame] in
                    self?.displayDecoded(frame?.buffer, status: status, token: token, sequence: sequence)
                }
            }
        if result != noErr {
            pendingDecodes -= 1; decoderError = result; waitingForKeyframe = true
            return false
        }
        waitingForKeyframe = false
        return true
    }
    private func displayDecoded(_ pixels: CVPixelBuffer?, status: OSStatus, token: UInt64, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard generation == token, decodedMode else { return }
        pendingDecodes = max(0, pendingDecodes - 1)
        guard status == noErr, let pixels else {
            decoderError = status; waitingForKeyframe = true; return
        }
        guard sequence > decodedSequence, let layer = displayLayer else { return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.isReadyForMoreMediaData else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime() - origin, preferredTimescale: 90000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        markImmediate(sample)
        renderer.enqueue(sample)
        decodedPixels = pixels; decodedSequence = sequence
        decoderError = noErr
        acceptedFrames += 1; lastVideoTime = CACurrentMediaTime(); lastError = nil
    }
    deinit {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
    }
}

#if canImport(UIKit)
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
    func makeCoordinator() -> VideoPipeline { pipeline }
    func makeUIView(context: Context) -> StreamSurface {
        let view = StreamSurface(frame: .zero)
        pipeline.attach(view.videoLayer)
        return view
    }
    func updateUIView(_ uiView: StreamSurface, context: Context) {}
    static func dismantleUIView(_ uiView: StreamSurface, coordinator: VideoPipeline) {
        coordinator.detach(uiView.videoLayer)
    }
}
#endif
