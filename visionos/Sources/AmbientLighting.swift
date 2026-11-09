// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import SwiftUI

enum AmbientLightingMode: String, CaseIterable, Identifiable {
    case simple, extreme
    var id: String { rawValue }
    var title: String { self == .simple ? "Simple" : "Extreme" }
}

@MainActor final class AmbientLighting: ObservableObject {
    @Published var mode: AmbientLightingMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modePreferenceKey) }
    }
    @Published var extremeError: String?
    var extremeDiagnostics: [String: Any] = [:]
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.preferenceKey)
            if !enabled { clear() }
            updateTimer()
        }
    }
    @Published private(set) var palette = AmbientPalette.black
    @Published private(set) var roomLightAllowed = true
    static let preferenceKey = "ambientLightingEnabled"
    static let modePreferenceKey = "ambientLightingMode"
    private let defaults: UserDefaults
    private let video: VideoPipeline
    private let queue = DispatchQueue(label: "visionremote.ambient", qos: .utility)
    private let sampler = AmbientPaletteSampler()
    private var timer: Timer?
    private var playing = false
    private var sceneActive = false
    private var busy = false
    private var epoch = 0
    private var lastTick = CACurrentMediaTime()
    private var lastRead = 0.0
    private var lastSample = 0.0
    private var lastVideoObserved = 0.0
    private var target = AmbientPalette.black
    private var generation: UInt64 = 0
    private(set) var samples = 0
    private(set) var misses = 0
    private(set) var readAttempts = 0
    private(set) var lastReadbackRate: Double?
    private(set) var lastSampleMS = 0.0
    private var consecutiveMisses = 0
    private var colorSource = "renderer"
    private var decoderStatus: Int32 = 0

    init(video: VideoPipeline, defaults: UserDefaults = .standard) {
        self.video = video; self.defaults = defaults
        mode = defaults.string(forKey: Self.modePreferenceKey).flatMap(AmbientLightingMode.init(rawValue:)) ?? .extreme
        enabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func setPlaying(_ value: Bool) {
        playing = value
        if !value { clear() }
        updateTimer()
    }
    func setSceneActive(_ value: Bool) {
        sceneActive = value
        if !value { clear() }
        updateTimer()
    }
    private func clear() {
        epoch += 1; target = .black; lastSample = 0; lastRead = 0
        lastVideoObserved = 0
        consecutiveMisses = 0
        palette = .black
    }
    private func updateTimer() {
        let shouldRun = enabled && playing && sceneActive
        if !shouldRun { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        let now = CACurrentMediaTime(), elapsed = now - lastTick
        lastTick = now
        let thermal = ProcessInfo.processInfo.thermalState
        roomLightAllowed = thermal != .serious && thermal != .critical
        guard thermal != .critical else { clear(); return }
        let wantsPixels = !busy && now - lastRead >= (thermal == .serious ? 0.5 : 0.2)
        if let frame = video.ambientFrame(includePixels: wantsPixels) {
            if generation != frame.generation {
                generation = frame.generation; clear()
            }
            lastVideoObserved = frame.lastVideoTime
            decoderStatus = frame.decoderStatus
            if now - frame.lastVideoTime <= 0.5, wantsPixels {
                colorSource = frame.source
                lastRead = now; readAttempts += 1; lastReadbackRate = frame.rendererRate
                if let pixels = frame.pixels {
                    consecutiveMisses = 0
                    busy = true
                    let token = epoch, streamGeneration = generation
                    let readOnly = AmbientReadOnlyPixels(buffer: pixels)
                    queue.async { [weak self, sampler, readOnly] in
                        let start = CACurrentMediaTime()
                        let value = autoreleasepool { sampler.sample(readOnly.buffer) }
                        let cost = (CACurrentMediaTime() - start) * 1000
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.busy = false
                            guard token == self.epoch, streamGeneration == self.generation,
                                  self.enabled, self.playing, self.sceneActive else { return }
                            if let value {
                                self.target = value; self.lastSample = CACurrentMediaTime()
                                self.samples += 1; self.lastSampleMS = cost
                            } else { self.misses += 1 }
                        }
                    }
                } else {
                    misses += 1; consecutiveMisses += 1
                    if consecutiveMisses >= 3 { video.requestDecodedAmbientFrames() }
                }
            }
            if now - frame.lastVideoTime > 0.5 { target = .black }
        }
        if now - lastSample > 0.5 { target = .black }
        palette = now - lastVideoObserved >= 2 ? .black : palette.approaching(target, elapsed: elapsed)
    }
    func diagnostics() -> [String: Any] {
        var result: [String: Any] = ["enabled": enabled, "mode": mode.rawValue, "sampling": timer != nil,
            "samples": samples, "readAttempts": readAttempts, "misses": misses,
            "lastSampleMS": lastSampleMS, "roomLightAllowed": roomLightAllowed,
            "colorSource": colorSource,
            "decoderStatus": decoderStatus,
            "paletteLuminance": palette.average.luminance]
        if let lastReadbackRate { result["rendererRate"] = lastReadbackRate }
        result["extreme"] = extremeDiagnostics
        if let extremeError { result["extremeError"] = extremeError }
#if DEBUG
        if ProcessInfo.processInfo.environment["VRP_AMBIENT_PROOF"] == "1" {
            result["proofLeftRGB"] = [palette.left.red, palette.left.green, palette.left.blue]
            result["proofRightRGB"] = [palette.right.red, palette.right.green, palette.right.blue]
        }
#endif
        return result
    }
}

extension AmbientRGB {
    var color: Color { Color(.sRGBLinear, red: Double(red), green: Double(green), blue: Double(blue), opacity: 1) }
#if canImport(UIKit)
    var uiColor: UIColor {
        UIColor(cgColor: CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1])!)
    }
#endif
}

struct AmbientHalo: View {
    let palette: AmbientPalette
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                Ellipse().fill(palette.left.color).frame(width: w * 0.72, height: h * 0.90)
                    .position(x: w * 0.12, y: h * 0.48)
                Ellipse().fill(palette.right.color).frame(width: w * 0.72, height: h * 0.90)
                    .position(x: w * 0.88, y: h * 0.48)
                Ellipse().fill(palette.top.color).frame(width: w * 0.92, height: h * 0.64)
                    .position(x: w * 0.50, y: h * 0.12)
                Ellipse().fill(palette.bottom.color).frame(width: w * 0.92, height: h * 0.64)
                    .position(x: w * 0.50, y: h * 0.88)
            }
            .blur(radius: min(w, h) * 0.16)
            .blendMode(.plusLighter)
            .compositingGroup()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                    .init(color: .white, location: 0.2), .init(color: .white, location: 0.8),
                    .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                    .init(color: .white, location: 0.22), .init(color: .white, location: 0.78),
                    .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
            .opacity(0.72)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
