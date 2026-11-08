// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum AnnexB {
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return [] }
        var starts: [(offset: Int, length: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let lower = start.offset + start.length
            let upper = index + 1 < starts.count ? starts[index + 1].offset : bytes.count
            return lower < upper ? Data(bytes[lower..<upper]) : nil
        }
    }
    static func lengthPrefixed(_ units: [Data]) -> Data {
        var output = Data()
        for unit in units where !unit.isEmpty {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }
}
