// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

import Testing
import Bytes
@testable import Deflate

@Suite("Streaming encoder")
struct StreamingTests {
    // MARK: - Helpers

    private static func bytesFromString(_ s: String) -> Bytes {
        var b = Bytes()
        b.append(contentsOf: Array(s.utf8))
        return b
    }

    private static func bytesFromArray(_ a: [UInt8]) -> Bytes {
        var b = Bytes()
        b.append(contentsOf: a)
        return b
    }

    // MARK: - Round-trip tests

    @Test("empty stream (no update + finish) round-trips to empty Bytes")
    func emptyStream() throws {
        var encoder = Deflate.Streaming.Encoder()
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(plain.storage.count == 0)
    }

    @Test("empty stream is byte-equal to Deflate.encode(empty, level: .none)")
    func emptyStreamByteEqualsNoneOneShot() throws {
        var encoder = Deflate.Streaming.Encoder()
        let streamed = try encoder.finish()
        let oneShot = Deflate.encode(Bytes(), level: .none)
        #expect(Array(streamed.storage) == Array(oneShot.storage))
    }

    @Test("single chunk update + finish round-trips")
    func singleChunkRoundTrip() throws {
        let payload = Self.bytesFromString("hello")
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("two chunks round-trip to concatenation")
    func twoChunkRoundTrip() throws {
        let chunk1 = Self.bytesFromString("hel")
        let chunk2 = Self.bytesFromString("lo")
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(chunk1)
        encoder.update(chunk2)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array("hello".utf8))
    }

    @Test("many tiny 1-byte chunks round-trip")
    func manyTinyChunks() throws {
        let payload: [UInt8] = (0..<100).map { UInt8($0 & 0xFF) }
        var encoder = Deflate.Streaming.Encoder()
        for byte in payload {
            encoder.update(Self.bytesFromArray([byte]))
        }
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == payload)
    }

    @Test("chunk > 64 KiB round-trips (single dynamic block)")
    func largeChunk() throws {
        let size = 70 * 1024
        let payload = [UInt8](repeating: 0x41, count: size)
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromArray(payload))
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(plain.storage.count == size)
        #expect(Array(plain.storage) == payload)
    }

    @Test("mixed-size chunks (pangram + small + medium) round-trip")
    func mixedSizeChunks() throws {
        let pangram = Self.bytesFromString("The quick brown fox jumps over the lazy dog. ")
        let small = Self.bytesFromString("XY")
        let medium = Self.bytesFromArray([UInt8](repeating: 0x42, count: 256))
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(pangram)
        encoder.update(small)
        encoder.update(medium)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        let expected = Array(pangram.storage) + Array(small.storage) + Array(medium.storage)
        #expect(Array(plain.storage) == expected)
    }

    @Test("empty chunk in middle is a no-op")
    func emptyChunkInMiddle() throws {
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromString("a"))
        encoder.update(Bytes())
        encoder.update(Self.bytesFromString("b"))
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array("ab".utf8))
    }

    // MARK: - Level coverage

    @Test(".none level round-trip (stored-only path)")
    func levelNone() throws {
        let payload = Self.bytesFromString("hello world")
        var encoder = Deflate.Streaming.Encoder(level: .none)
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test(".fast level round-trip")
    func levelFast() throws {
        let payload = Self.bytesFromString("The quick brown fox jumps over the lazy dog.")
        var encoder = Deflate.Streaming.Encoder(level: .fast)
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test(".default level round-trip")
    func levelDefault() throws {
        let payload = Self.bytesFromString("The quick brown fox jumps over the lazy dog.")
        var encoder = Deflate.Streaming.Encoder(level: .default)
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test(".best level round-trip")
    func levelBest() throws {
        let payload = Self.bytesFromArray([UInt8](repeating: 0x5A, count: 1024))
        var encoder = Deflate.Streaming.Encoder(level: .best)
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    // MARK: - Error cases

    @Test("double-finish throws encoderFinished")
    func doubleFinishThrows() throws {
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromString("data"))
        _ = try encoder.finish()
        do {
            _ = try encoder.finish()
            Issue.record("expected throw")
        } catch DeflateError.encoderFinished {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Edge cases

    @Test("single-byte stream round-trips")
    func singleByteStream() throws {
        let payload = Self.bytesFromArray([0x7F])
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(payload)
        let compressed = try encoder.finish()
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == [0x7F])
    }

    // MARK: - Drain (v0.4)

    @Test("drain() on fresh encoder returns empty Bytes")
    func drainFresh() throws {
        var encoder = Deflate.Streaming.Encoder()
        let drained = encoder.drain()
        #expect(drained.storage.count == 0)
    }

    @Test("drain() + finish() concatenated round-trips through inflate")
    func drainConcatRoundTrip() throws {
        let payload = Self.bytesFromString("hello world hello world")
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(payload)
        let drained = encoder.drain()
        let final = try encoder.finish()

        var combined = Bytes()
        combined.append(contentsOf: drained.storage)
        combined.append(contentsOf: final.storage)
        let plain = try Deflate.inflate(combined)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("multiple drains + finish round-trips")
    func multipleDrains() throws {
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromString("first"))
        var collected = Bytes()
        collected.append(contentsOf: encoder.drain().storage)
        encoder.update(Self.bytesFromString("second"))
        collected.append(contentsOf: encoder.drain().storage)
        encoder.update(Self.bytesFromString("third"))
        collected.append(contentsOf: encoder.drain().storage)
        collected.append(contentsOf: (try encoder.finish()).storage)

        let plain = try Deflate.inflate(collected)
        #expect(Array(plain.storage) == Array("firstsecondthird".utf8))
    }

    @Test("drain after finish is silent no-op")
    func drainAfterFinish() throws {
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromString("data"))
        _ = try encoder.finish()
        let drained = encoder.drain()
        #expect(drained.storage.count == 0)
    }

    @Test("non-draining stream byte-equals concatenated-drains stream")
    func drainConcatByteEquality() throws {
        let chunk1 = Self.bytesFromString("aaaaaaaaaa")
        let chunk2 = Self.bytesFromString("bbbbbbbbbb")

        var reference = Deflate.Streaming.Encoder()
        reference.update(chunk1)
        reference.update(chunk2)
        let referenceOutput = try reference.finish()

        var draining = Deflate.Streaming.Encoder()
        draining.update(chunk1)
        let d1 = draining.drain()
        draining.update(chunk2)
        let d2 = draining.drain()
        let d3 = try draining.finish()

        var combined = Bytes()
        combined.append(contentsOf: d1.storage)
        combined.append(contentsOf: d2.storage)
        combined.append(contentsOf: d3.storage)

        #expect(Array(combined.storage) == Array(referenceOutput.storage))
    }

    // MARK: - v0.3 edge cases

    // MARK: - Streaming Decoder (v0.5)

    @Test("Decoder: empty stream finish returns empty")
    func decoderEmptyStream() throws(DeflateError) {
        var decoder = Deflate.Streaming.Decoder()
        let compressed = Deflate.encode(Bytes())
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(plain.storage.count == 0)
    }

    @Test("Decoder: single chunk round-trip via v0.2 encoder")
    func decoderSingleChunkRoundTrip() throws(DeflateError) {
        let payload = Self.bytesFromString("hello world hello world")
        let compressed = Deflate.encode(payload)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: multi-chunk input round-trip")
    func decoderMultiChunkRoundTrip() throws(DeflateError) {
        let payload = Self.bytesFromString("The quick brown fox jumps over the lazy dog.")
        let compressed = Deflate.encode(payload)
        // Split compressed bytes into 3 chunks.
        let third = compressed.storage.count / 3
        let c1 = ContiguousArray(compressed.storage[0..<third])
        let c2 = ContiguousArray(compressed.storage[third..<(2 * third)])
        let c3 = ContiguousArray(compressed.storage[(2 * third)..<compressed.storage.count])

        var decoder = Deflate.Streaming.Decoder()
        decoder.update(Bytes(Array(c1)))
        decoder.update(Bytes(Array(c2)))
        decoder.update(Bytes(Array(c3)))
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: many tiny 1-byte chunks round-trip")
    func decoderTinyChunks() throws(DeflateError) {
        let payload = Self.bytesFromString("hello")
        let compressed = Deflate.encode(payload)
        var decoder = Deflate.Streaming.Decoder()
        for byte in compressed.storage {
            decoder.update(Self.bytesFromArray([byte]))
        }
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: stored block (.none level) round-trip")
    func decoderStoredBlock() throws(DeflateError) {
        let payload = Self.bytesFromString("uncompressible random-ish data here")
        let compressed = Deflate.encode(payload, level: .none)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: fixed-Huffman block (.fast level) round-trip")
    func decoderFixedHuffman() throws(DeflateError) {
        let payload = Self.bytesFromString("aaaaaaaaaabbbbbbbbbb")
        let compressed = Deflate.encode(payload, level: .fast)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: dynamic-Huffman block (.default level) round-trip")
    func decoderDynamicHuffman() throws(DeflateError) {
        let payload = Self.bytesFromArray([UInt8](repeating: 0x41, count: 1024))
        let compressed = Deflate.encode(payload, level: .default)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: 70 KiB payload round-trip")
    func decoderLargePayload() throws(DeflateError) {
        let payload = Self.bytesFromArray([UInt8](repeating: 0x42, count: 70 * 1024))
        let compressed = Deflate.encode(payload, level: .default)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(plain.storage.count == 70 * 1024)
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: truncated input throws .truncated")
    func decoderTruncatedThrows() {
        let payload = Self.bytesFromString("hello")
        let compressed = Deflate.encode(payload)
        // Truncate by 1 byte.
        let truncated = ContiguousArray(compressed.storage.dropLast())
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(Bytes(Array(truncated)))
        do {
            _ = try decoder.finish()
            Issue.record("expected throw")
        } catch DeflateError.truncated {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Decoder: double-finish throws decoderFinished")
    func decoderDoubleFinishThrows() throws(DeflateError) {
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(Deflate.encode(Self.bytesFromString("data")))
        _ = try decoder.finish()
        do {
            _ = try decoder.finish()
            Issue.record("expected throw")
        } catch DeflateError.decoderFinished {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Decoder: update after finish is silent no-op (then double-finish throws)")
    func decoderUpdateAfterFinishNoOp() throws(DeflateError) {
        let payload = Self.bytesFromString("first")
        let compressed = Deflate.encode(payload)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain1 = try decoder.finish()
        decoder.update(Deflate.encode(Self.bytesFromString("second")))
        do {
            _ = try decoder.finish()
            Issue.record("expected throw")
        } catch DeflateError.decoderFinished {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(Array(plain1.storage) == Array(payload.storage))
    }

    @Test("Decoder: empty update is no-op (whole flow still works)")
    func decoderEmptyUpdateNoOp() throws(DeflateError) {
        let payload = Self.bytesFromString("hello")
        let compressed = Deflate.encode(payload)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(Bytes())  // no-op
        decoder.update(compressed)
        decoder.update(Bytes())  // no-op
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == Array(payload.storage))
    }

    @Test("Decoder: single-byte payload round-trip")
    func decoderSingleBytePayload() throws(DeflateError) {
        let payload = Self.bytesFromArray([0x7F])
        let compressed = Deflate.encode(payload)
        var decoder = Deflate.Streaming.Decoder()
        decoder.update(compressed)
        let plain = try decoder.finish()
        #expect(Array(plain.storage) == [0x7F])
    }

    // MARK: - Streaming Encoder (existing v0.3-v0.4 edge cases)

    @Test("update after finish is silent no-op (then double-finish throws)")
    func updateAfterFinishNoOp() throws {
        var encoder = Deflate.Streaming.Encoder()
        encoder.update(Self.bytesFromString("first"))
        let compressed = try encoder.finish()
        encoder.update(Self.bytesFromString("second"))
        do {
            _ = try encoder.finish()
            Issue.record("expected throw on second finish")
        } catch DeflateError.encoderFinished {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let plain = try Deflate.inflate(compressed)
        #expect(Array(plain.storage) == Array("first".utf8))
    }
}
