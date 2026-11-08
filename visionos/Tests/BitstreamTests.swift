// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@main enum BitstreamTests {
    static func main() {
        precondition(AnnexB.units(Data()).isEmpty)
        precondition(AnnexB.units(Data([0, 0, 1])).isEmpty)
        precondition(AnnexB.units(Data([1, 2, 3, 4])).isEmpty)
        precondition(AnnexB.units(Data([0, 0, 0, 1])).isEmpty)
        let sample = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68, 0x12, 0, 0, 0, 1, 0x65, 0xab])
        let units = AnnexB.units(sample)
        precondition(units == [Data([0x67, 0x42]), Data([0x68, 0x12]), Data([0x65, 0xab])])
        precondition(AnnexB.lengthPrefixed(units) == Data([0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 2, 0x68, 0x12, 0, 0, 0, 2, 0x65, 0xab]))
        precondition(AnnexB.units(Data([0, 0, 1, 0, 0, 1, 0x65])) == [Data([0x65])])
        print("H.264 Annex B boundary, empty/truncated input and length-prefix tests passed.")
    }
}
