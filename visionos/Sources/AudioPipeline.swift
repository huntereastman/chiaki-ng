// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation

final class AudioPipeline {
    private let queue = DispatchQueue(label: "visionremote.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var pending = 0
    private var channelCount = 2
    private let countLock = NSLock()
    private var scheduledFrames = 0
    var onError: ((String) -> Void)?
    init() { engine.attach(player) }
    func configure(channels: UInt32, rate: UInt32) {
        queue.async { [self] in
            guard (1...2).contains(channels), (8000...96000).contains(rate) else { return }
            player.stop(); engine.stop(); pending = 0
            channelCount = Int(channels)
            guard let next = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: channels) else { return }
            format = next
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: next)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                player.play()
            } catch { onError?("Audio could not start: \(error.localizedDescription)") }
        }
    }
    func consume(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int) {
        guard frames > 0, frames <= 5760, (1...2).contains(channels) else { return }
        let data = Data(bytes: samples, count: frames * channels * MemoryLayout<Int16>.size)
        queue.async { [self] in
            guard let format, engine.isRunning, channels == channelCount,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let output = buffer.floatChannelData else { return }
            // Bound buffered audio instead of accumulating delay on a slow connection.
            if pending >= 12 { player.stop(); pending = 0; player.play() }
            buffer.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                let input = raw.bindMemory(to: Int16.self)
                for channel in 0..<channels {
                    for frame in 0..<frames { output[channel][frame] = Float(input[frame * channels + channel]) / 32768 }
                }
            }
            pending += 1
            countLock.lock(); scheduledFrames += frames; countLock.unlock()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.pending = max(0, self.pending - 1) }
            }
        }
    }
    func stop() { queue.async { self.player.stop(); self.engine.stop(); self.pending = 0; self.format = nil } }
    func frameCount() -> Int { countLock.lock(); defer { countLock.unlock() }; return scheduledFrames }
}
