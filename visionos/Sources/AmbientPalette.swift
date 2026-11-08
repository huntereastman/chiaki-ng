// SPDX-License-Identifier: AGPL-3.0-only
import CoreImage
import Foundation

struct AmbientRGB: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    static let black = AmbientRGB(red: 0, green: 0, blue: 0)
    var luminance: Float { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    func blended(with other: Self, amount: Double) -> Self {
        let t = Float(min(1, max(0, amount)))
        return Self(red: red + (other.red - red) * t,
                    green: green + (other.green - green) * t,
                    blue: blue + (other.blue - blue) * t)
    }
}

struct AmbientPalette: Equatable, Sendable {
    var left: AmbientRGB
    var right: AmbientRGB
    var top: AmbientRGB
    var bottom: AmbientRGB
    static let black = AmbientPalette(left: .black, right: .black, top: .black, bottom: .black)
    var average: AmbientRGB { left.blended(with: right, amount: 0.5).blended(with: top.blended(with: bottom, amount: 0.5), amount: 0.5) }

    func approaching(_ target: Self, elapsed: Double, timeConstant: Double = 0.22) -> Self {
        let amount = 1 - exp(-min(0.3, max(0, elapsed)) / timeConstant)
        return Self(left: left.blended(with: target.left, amount: amount),
                    right: right.blended(with: target.right, amount: amount),
                    top: top.blended(with: target.top, amount: amount),
                    bottom: bottom.blended(with: target.bottom, amount: amount))
    }
}

// These references are read-only after acquisition; no attachment or pixel writes are allowed.
struct AmbientReadOnlyPixels: @unchecked Sendable { let buffer: CVPixelBuffer }

// One owner serializes sample() on the palette queue. The context is never mutated concurrently.
// Only four reduced pixels reach the CPU.
final class AmbientPaletteSampler: @unchecked Sendable {
    private let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])

    func sample(_ buffer: CVPixelBuffer) -> AmbientPalette? { sample(CIImage(cvPixelBuffer: buffer)) }

    func sample(_ source: CIImage) -> AmbientPalette? {
        let extent = source.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 4, extent.height >= 4 else { return nil }
        let image = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 64 / extent.width, y: 36 / extent.height))
        // A small inset avoids a dark border; the bands retain useful local color.
        let area = CGRect(x: 2, y: 1, width: 60, height: 34)
        func average(_ region: CGRect) -> AmbientRGB? {
            guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgRect: region), forKey: kCIInputExtentKey)
            guard let output = filter.outputImage else { return nil }
            var rgba = [Float](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                context.render(output, toBitmap: bytes.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
            }
            guard rgba.allSatisfy(\.isFinite) else { return nil }
            // Mild exposure lifts colored scenes; zero remains zero on a black frame.
            return AmbientRGB(red: min(1, max(0, rgba[0] * 1.25)),
                              green: min(1, max(0, rgba[1] * 1.25)),
                              blue: min(1, max(0, rgba[2] * 1.25)))
        }
        guard let left = average(CGRect(x: area.minX, y: area.minY, width: 12, height: area.height)),
              let right = average(CGRect(x: area.maxX - 12, y: area.minY, width: 12, height: area.height)),
              let top = average(CGRect(x: area.minX, y: area.maxY - 7, width: area.width, height: 7)),
              let bottom = average(CGRect(x: area.minX, y: area.minY, width: area.width, height: 7)) else { return nil }
        return AmbientPalette(left: left, right: right, top: top, bottom: bottom)
    }
}
