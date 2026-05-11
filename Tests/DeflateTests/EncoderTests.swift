// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

import Testing
import Bytes
@testable import Deflate

@Suite("Deflate.Encoder API surface")
struct EncoderAPITests {
    @Test("Level enum has the four committed cases")
    func levelCases() {
        let levels: [Deflate.Encoder.Level] = [.none, .fast, .default, .best]
        #expect(levels.count == 4)
    }

    @Test("encode(_:level:) returns non-empty Bytes for non-empty input")
    func encodeBasic() {
        let out = Deflate.encode(Bytes([0x41]), level: .default)
        #expect(!out.storage.isEmpty)
    }

    @Test("encode(empty) returns a valid (possibly empty-coding) stream")
    func encodeEmpty() {
        let out = Deflate.encode(Bytes(), level: .default)
        #expect(!out.storage.isEmpty)
    }
}
