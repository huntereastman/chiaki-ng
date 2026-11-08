// SPDX-License-Identifier: AGPL-3.0-only
#if DEBUG
import Foundation

// Opt-in developer fixture. Never starts Remote Play, reads credentials, or changes pairing.
@MainActor final class AmbientProofFeed {
    private var task: Task<Void, Never>?
    private(set) var framesSent = 0

    func start(video: VideoPipeline) -> Bool {
        guard let url = Bundle.main.url(forResource: "AmbientProof", withExtension: "h264frames"),
              let file = try? Data(contentsOf: url), file.prefix(5) == Data("VRPA1".utf8) else { return false }
        var frames: [Data] = [], offset = 5
        while offset + 4 <= file.count {
            let size = file[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, size <= 1024 * 1024, offset + size <= file.count else { return false }
            frames.append(file.subdata(in: offset..<(offset + size))); offset += size
        }
        guard !frames.isEmpty, offset == file.count else { return false }
        video.reset()
        task = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                _ = video.consume(frames[index], lost: 0)
                self?.framesSent += 1
                index = (index + 1) % frames.count
                try? await Task.sleep(for: .milliseconds(42))
            }
        }
        return true
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
#endif
