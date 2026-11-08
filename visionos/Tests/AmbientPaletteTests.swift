// SPDX-License-Identifier: AGPL-3.0-only
import CoreImage
import Foundation

@main enum AmbientPaletteTests {
    @MainActor static func main() {
        let sampler = AmbientPaletteSampler()
        let area = CGRect(x: 0, y: 0, width: 128, height: 72)
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CIImage {
            CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: area)
        }
        let red = solid(1, 0, 0), blue = solid(0, 0, 1)
        let split = red.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 72)).composited(over: blue)
        let palette = sampler.sample(split)!
        precondition(palette.left.red > 0.95 && palette.left.blue < 0.01, "Left band lost its red source")
        precondition(palette.right.blue > 0.95 && palette.right.red < 0.01, "Right band lost its blue source")
        precondition(palette.top.red > 0.3 && palette.top.blue > 0.3, "Top band should mix both sides")
        precondition(sampler.sample(solid(0, 0, 0))! == .black, "Black frames must not acquire artificial glow")
        let white = sampler.sample(solid(1, 1, 1))!
        precondition(white.left.red == 1 && white.left.green == 1 && white.left.blue == 1, "Output must remain bounded")
        precondition(sampler.sample(CIImage.empty()) == nil, "Empty images are unknown, not healthy samples")
        precondition(sampler.sample(CIImage(color: CIColor(red: 1, green: 0, blue: 0))) == nil, "Reject infinite image extents")

        let shifted = split.transformed(by: CGAffineTransform(translationX: 70, y: -30))
        let shiftedPalette = sampler.sample(shifted)!
        precondition(abs(shiftedPalette.left.red - palette.left.red) < 0.01, "Nonzero image origins must retain orientation")
        precondition(abs(shiftedPalette.right.blue - palette.right.blue) < 0.01)

        var slow = AmbientPalette.black, fast = AmbientPalette.black
        for _ in 0..<10 { slow = slow.approaching(palette, elapsed: 0.1) }
        for _ in 0..<20 { fast = fast.approaching(palette, elapsed: 0.05) }
        precondition(abs(slow.left.red - fast.left.red) < 0.0001, "Smoothing must be time-based")
        for _ in 0..<20 { slow = slow.approaching(.black, elapsed: 0.1) }
        precondition(slow.average.luminance < 0.001, "Stale input must fade to darkness within two seconds")
        let suite = "dev.hunter.visionremoteplay.ambient-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AmbientLighting(video: VideoPipeline(), defaults: defaults)
        precondition(first.enabled, "First-run lighting should be enabled")
        first.setSceneActive(true); first.setPlaying(true)
        precondition(first.diagnostics()["sampling"] as? Bool == true)
        first.enabled = false
        precondition(first.diagnostics()["sampling"] as? Bool == false, "Off must stop sampling")
        precondition(first.palette == .black, "Off must clear the glow")
        let relaunched = AmbientLighting(video: VideoPipeline(), defaults: defaults)
        precondition(!relaunched.enabled, "Saved off setting must survive model recreation")
        relaunched.enabled = true
        precondition(AmbientLighting(video: VideoPipeline(), defaults: defaults).enabled, "Saved on setting must survive model recreation")
        print("Ambient lighting: actual color reduction, orientation, black/white bounds, invalid extents, shifted origins, cadence independence, stale fade, saved on/off and stopping sampling passed.")
    }
}
