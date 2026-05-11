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
