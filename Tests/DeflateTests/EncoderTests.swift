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

@Suite("Stored-block (.none level) round-trip")
struct StoredBlockRoundTripTests {
    @Test("empty input")
    func empty() throws {
        let out = Deflate.encode(Bytes(), level: .none)
        let back = try Deflate.inflate(out)
        #expect(back.storage == ContiguousArray<UInt8>())
    }

    @Test("single byte")
    func single() throws {
        let input = Bytes([0x42])
        let out = Deflate.encode(input, level: .none)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test("100 bytes of 0x41")
    func runs() throws {
        let input = Bytes(ContiguousArray(repeating: UInt8(0x41), count: 100))
        let out = Deflate.encode(input, level: .none)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test("input larger than one stored block (65 KiB forces split)")
    func largerThanBlock() throws {
        var bytes = ContiguousArray<UInt8>()
        bytes.reserveCapacity(65 * 1024)
        for i in 0..<(65 * 1024) {
            bytes.append(UInt8(truncatingIfNeeded: i))
        }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .none)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }
}

@Suite("BitWriter")
struct BitWriterTests {
    @Test("writes a single byte")
    func singleByte() {
        var w = BitWriter()
        w.writeByte(0xAB)
        let out = w.finish()
        #expect(out.storage == [0xAB])
    }

    @Test("LSB-first bit packing")
    func lsbFirst() {
        var w = BitWriter()
        w.writeBits(1, count: 1)
        w.writeBits(1, count: 2)
        w.alignToByte()
        let out = w.finish()
        #expect(out.storage == [0x03])
    }

    @Test("multi-byte bit packing")
    func multiByte() {
        var w = BitWriter()
        w.writeBits(0xAB, count: 8)
        w.writeBits(0xCD, count: 8)
        let out = w.finish()
        #expect(out.storage == [0xAB, 0xCD])
    }

    @Test("alignToByte pads with zeros")
    func alignPadsZero() {
        var w = BitWriter()
        w.writeBits(1, count: 3)
        w.alignToByte()
        w.writeByte(0xFF)
        let out = w.finish()
        #expect(out.storage == [0b00000001, 0xFF])
    }

    @Test("partial final byte is flushed on finish")
    func partialFinalFlushed() {
        var w = BitWriter()
        w.writeBits(0x5, count: 4)
        let out = w.finish()
        #expect(out.storage == [0x05])
    }
}

@Suite("Fixed-Huffman literal-only round-trip (.fast level)")
struct FixedHuffmanLiteralRoundTripTests {
    @Test("empty input via .fast")
    func empty() throws {
        let out = Deflate.encode(Bytes(), level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == ContiguousArray<UInt8>())
    }

    @Test("ASCII 'hello'")
    func helloLiteral() throws {
        let input = Bytes([0x68, 0x65, 0x6C, 0x6C, 0x6F])
        let out = Deflate.encode(input, level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test("all 256 byte values once")
    func all256() throws {
        var bytes = ContiguousArray<UInt8>()
        for i in 0..<256 { bytes.append(UInt8(i)) }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test("fixed-Huffman output is shorter than stored-block on a compressible input")
    func fixedShorterThanStored() {
        let input = Bytes(ContiguousArray(repeating: UInt8(0x41), count: 100))
        let storedOut = Deflate.encode(input, level: .none)
        let fixedOut  = Deflate.encode(input, level: .fast)
        #expect(fixedOut.storage.count < storedOut.storage.count,
                "fast=\(fixedOut.storage.count) stored=\(storedOut.storage.count)")
    }
}

@Suite("Matcher (LZ77 hash-chain)")
struct MatcherTests {
    @Test("finds a 5-byte match at distance 5")
    func findsMatch() {
        let input = Bytes([0x41, 0x42, 0x43, 0x44, 0x45, 0x41, 0x42, 0x43, 0x44, 0x45])
        var m = Matcher(input.storage, maxChain: 16)
        for i in 0..<5 { _ = m.findMatch(at: i) }
        let (length, distance) = m.findMatch(at: 5)
        #expect(length >= 5)
        #expect(distance == 5)
    }

    @Test("returns (0, 0) when no match")
    func noMatch() {
        let input = Bytes([0x41, 0x42, 0x43])
        var m = Matcher(input.storage, maxChain: 16)
        let (length, distance) = m.findMatch(at: 0)
        #expect(length == 0)
        #expect(distance == 0)
    }

    @Test("respects max-chain (deeper chain finds longer match)")
    func chainDepthMatters() {
        var bytes = ContiguousArray<UInt8>()
        for _ in 0..<32 { bytes.append(contentsOf: [0x01, 0x02, 0x03]) }
        for _ in 0..<10 { bytes.append(contentsOf: [0x01, 0x02, 0x03]) }
        let input = Bytes(bytes)
        var shallow = Matcher(input.storage, maxChain: 1)
        var deep    = Matcher(input.storage, maxChain: 4096)
        for i in 0..<96 {
            _ = shallow.findMatch(at: i)
            _ = deep.findMatch(at: i)
        }
        let (lenShallow, _) = shallow.findMatch(at: 96)
        let (lenDeep, _)    = deep.findMatch(at: 96)
        #expect(lenShallow >= 3)
        #expect(lenDeep >= lenShallow)
    }
}

@Suite("Encode-side length/distance code lookups")
struct EncodeLookupTests {
    @Test("length 3 → code 257 with 0 extra bits")
    func length3() {
        let (code, extra, extraBits) = Tables.encodeLengthCode(3)
        #expect(code == 257)
        #expect(extra == 0)
        #expect(extraBits == 0)
    }

    @Test("length 11 → code 265 with 1 extra bit (extra=0)")
    func length11() {
        let (code, extra, extraBits) = Tables.encodeLengthCode(11)
        #expect(code == 265)
        #expect(extra == 0)
        #expect(extraBits == 1)
    }

    @Test("length 12 → code 265 with 1 extra bit (extra=1)")
    func length12() {
        let (code, extra, extraBits) = Tables.encodeLengthCode(12)
        #expect(code == 265)
        #expect(extra == 1)
        #expect(extraBits == 1)
    }

    @Test("length 258 → code 285 with 0 extra bits")
    func length258() {
        let (code, extra, extraBits) = Tables.encodeLengthCode(258)
        #expect(code == 285)
        #expect(extra == 0)
        #expect(extraBits == 0)
    }

    @Test("distance 1 → code 0 with 0 extra bits")
    func distance1() {
        let (code, extra, extraBits) = Tables.encodeDistanceCode(1)
        #expect(code == 0)
        #expect(extra == 0)
        #expect(extraBits == 0)
    }

    @Test("distance 5 → code 4 with 1 extra bit (extra=0)")
    func distance5() {
        let (code, extra, extraBits) = Tables.encodeDistanceCode(5)
        #expect(code == 4)
        #expect(extra == 0)
        #expect(extraBits == 1)
    }

    @Test("distance 32768 → code 29 with 13 extra bits")
    func distance32768() {
        let (code, extra, extraBits) = Tables.encodeDistanceCode(32_768)
        #expect(code == 29)
        #expect(extra == (32_768 - 24_577))
        #expect(extraBits == 13)
    }
}

@Suite("Fixed-Huffman with LZ77 (.fast level)")
struct FixedHuffmanLZ77Tests {
    @Test(".fast on 100 0x41 bytes shrinks via match")
    func runsCompressViaMatch() throws {
        let input = Bytes(ContiguousArray(repeating: UInt8(0x41), count: 100))
        let out = Deflate.encode(input, level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
        #expect(out.storage.count < 50, "got \(out.storage.count) bytes")
    }

    @Test(".fast on the 'abcabcabc' pattern compresses")
    func patternMatches() throws {
        var bytes = ContiguousArray<UInt8>()
        for _ in 0..<200 { bytes.append(contentsOf: [0x61, 0x62, 0x63]) }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
        #expect(out.storage.count < input.storage.count / 4,
                "got \(out.storage.count) bytes, input \(input.storage.count)")
    }

    @Test(".fast on 200 KiB of repeating pattern decompresses correctly")
    func large() throws {
        var bytes = ContiguousArray<UInt8>()
        let pattern: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
            0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
            0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E,
        ]
        while bytes.count < 200 * 1024 {
            bytes.append(contentsOf: pattern)
        }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .fast)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }
}

@Suite("HuffmanEncoder canonical code construction")
struct HuffmanEncoderTests {
    @Test("single-symbol alphabet still emits a usable code")
    func singleSymbol() {
        var freqs = [Int](repeating: 0, count: 4)
        freqs[0] = 100
        let lengths = HuffmanEncoder.buildLengths(frequencies: freqs, maxBits: 15)
        #expect(lengths[0] >= 1)
        #expect(lengths[1] == 0)
        #expect(lengths[2] == 0)
        #expect(lengths[3] == 0)
    }

    @Test("two-symbol alphabet gets length 1 each")
    func twoSymbols() {
        let lengths = HuffmanEncoder.buildLengths(frequencies: [50, 50, 0, 0], maxBits: 15)
        #expect(lengths[0] == 1)
        #expect(lengths[1] == 1)
        #expect(lengths[2] == 0)
        #expect(lengths[3] == 0)
    }

    @Test("length-limited: maxBits=4 still produces a valid prefix code")
    func lengthLimited() {
        var freqs = [Int](repeating: 0, count: 16)
        for i in 0..<16 { freqs[i] = 1 << i }
        let lengths = HuffmanEncoder.buildLengths(frequencies: freqs, maxBits: 4)
        for l in lengths {
            #expect(l <= 4)
        }
        var kraft = 0
        for l in lengths where l > 0 {
            kraft += 1 << (15 - l)
        }
        #expect(kraft <= 1 << 15)
    }

    @Test("canonical code generation matches RFC 1951 § 3.2.2")
    func canonicalGeneration() {
        let lengths = [3, 3, 3, 3, 2]
        let codes = HuffmanEncoder.canonicalCodes(lengths: lengths)
        #expect(codes[0] == 0b010)
        #expect(codes[1] == 0b011)
        #expect(codes[2] == 0b100)
        #expect(codes[3] == 0b101)
        #expect(codes[4] == 0b00)
    }
}

@Suite("Dynamic-Huffman block round-trip (.default level)")
struct DynamicHuffmanEncodeTests {
    @Test(".default round-trips 100 0x41 bytes")
    func runs() throws {
        let input = Bytes(ContiguousArray(repeating: UInt8(0x41), count: 100))
        let out = Deflate.encode(input, level: .default)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test(".default round-trips ASCII text")
    func ascii() throws {
        let s = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)
        let input = Bytes(Array(s.utf8))
        let out = Deflate.encode(input, level: .default)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }

    @Test(".default beats .fast on biased inputs")
    func beatsFast() {
        let s = String(repeating: "aaaabbbbcccdddeeefffgggghhhhiii", count: 200)
        let input = Bytes(Array(s.utf8))
        let fast    = Deflate.encode(input, level: .fast)
        let dynamic = Deflate.encode(input, level: .default)
        #expect(dynamic.storage.count <= fast.storage.count,
                "dynamic=\(dynamic.storage.count) fast=\(fast.storage.count)")
        #expect(dynamic.storage.prefix(3) != fast.storage.prefix(3),
                "dynamic and fast produced identical headers — dynamic path not engaged")
    }

    @Test(".default round-trips 64 KiB high-entropy input")
    func highEntropy() throws {
        var bytes = ContiguousArray<UInt8>()
        var seed: UInt32 = 0xDEADBEEF
        for _ in 0..<65_536 {
            seed = seed &* 1_103_515_245 &+ 12_345
            bytes.append(UInt8(truncatingIfNeeded: seed >> 24))
        }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .default)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
    }
}

@Suite("Block-type selection picks smallest")
struct BlockTypeSelectionTests {
    @Test("high-entropy input chooses stored or fixed over dynamic")
    func highEntropyChoosesShorter() throws {
        var bytes = ContiguousArray<UInt8>()
        var seed: UInt32 = 0xABCD0123
        for _ in 0..<512 {
            seed = seed &* 1_103_515_245 &+ 12_345
            bytes.append(UInt8(truncatingIfNeeded: seed >> 24))
        }
        let input = Bytes(bytes)
        let out = Deflate.encode(input, level: .best)
        let back = try Deflate.inflate(out)
        #expect(back.storage == input.storage)
        // Stored is len+5 = 517 bytes; we should never exceed that.
        #expect(out.storage.count <= 520, "got \(out.storage.count) bytes")
    }

    @Test("low-entropy input chooses dynamic")
    func lowEntropyChoosesDynamic() throws {
        let s = String(repeating: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", count: 100)
        let input = Bytes(Array(s.utf8))
        let dynamic = Deflate.encode(input, level: .best)
        let back = try Deflate.inflate(dynamic)
        #expect(back.storage == input.storage)
        #expect(dynamic.storage.count < input.storage.count / 4)
    }
}
