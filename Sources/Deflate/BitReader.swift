// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// LSB-first bit reader over a `Bytes` buffer. RFC 1951 § 3.1.1
/// specifies that bits within a byte are consumed least-significant
/// first; multi-bit values pack lower-order bits before higher-order.
///
/// v0.6: bytes is mutable to support streaming inflate via
/// ``append(_:)`` and snapshot/restore. v0.1-v0.5 one-shot callers
/// construct once and never append; semantics preserved byte-for-byte.
struct BitReader {
    var bytes: ContiguousArray<UInt8>
    var bytePos: Int = 0
    var bitsInBuffer: Int = 0
    var buffer: UInt32 = 0

    init(_ source: Bytes) {
        self.bytes = source.storage
    }

    init() {
        self.bytes = ContiguousArray<UInt8>()
    }

    /// Append more bytes to the underlying buffer. Used by streaming
    /// inflate to continue decoding when more input arrives. Position
    /// and bit-buffer state are preserved.
    mutating func append(_ chunk: ContiguousArray<UInt8>) {
        bytes.append(contentsOf: chunk)
    }

    /// Snapshot of read position state. Used by streaming inflate to
    /// rewind to a clean checkpoint when a read truncates mid-symbol.
    struct Snapshot {
        let bytePos: Int
        let bitsInBuffer: Int
        let buffer: UInt32
    }

    func snapshot() -> Snapshot {
        Snapshot(bytePos: bytePos, bitsInBuffer: bitsInBuffer, buffer: buffer)
    }

    mutating func restore(_ s: Snapshot) {
        self.bytePos = s.bytePos
        self.bitsInBuffer = s.bitsInBuffer
        self.buffer = s.buffer
    }

    /// True if `count` whole bytes are available after byte-alignment
    /// (combined buffered partial bytes + unread bytes in `bytes`).
    /// Used by streaming stored-block decode to read what's available
    /// without throwing on partial input.
    func availableBytesAligned() -> Int {
        // Whole bytes already in the bit buffer (after alignToByte).
        let bufferedWholeBytes = bitsInBuffer / 8
        return bufferedWholeBytes + (bytes.count - bytePos)
    }

    /// Read `count` bits (`count <= 24`) as an unsigned integer.
    mutating func readBits(_ count: Int) throws(DeflateError) -> UInt32 {
        try ensure(bits: count)
        let mask = (UInt32(1) << count) - 1
        let value = buffer & mask
        buffer >>= count
        bitsInBuffer -= count
        return value
    }

    /// Read a single bit.
    mutating func readBit() throws(DeflateError) -> Bool {
        try readBits(1) == 1
    }

    /// Peek `count` bits without consuming. Refills the buffer as needed.
    /// At end-of-stream the high bits beyond what's available are
    /// zero-padded (Huffman table lookup tolerates this because shorter
    /// codes are replicated across all high-bit suffixes); a subsequent
    /// `consume()` is what surfaces the truncated error if the actual
    /// code length exceeds the bits truly remaining.
    mutating func peekBits(_ count: Int) -> UInt32 {
        ensureSoft(bits: count)
        let mask = (UInt32(1) << count) - 1
        return buffer & mask
    }

    /// Consume `count` bits previously peeked. Throws `.truncated` if
    /// we'd consume past end-of-stream.
    mutating func consume(_ count: Int) throws(DeflateError) {
        if count > bitsInBuffer {
            throw .truncated
        }
        buffer >>= count
        bitsInBuffer -= count
    }

    /// Like `ensure(bits:)` but zero-pads on EOF instead of throwing.
    private mutating func ensureSoft(bits: Int) {
        while bitsInBuffer < bits {
            guard bytePos < bytes.count else {
                return  // leave buffer as-is; caller's mask zero-pads.
            }
            buffer |= UInt32(bytes[bytePos]) << bitsInBuffer
            bytePos += 1
            bitsInBuffer += 8
        }
    }

    /// Discard whatever bits remain in the current byte. Used before
    /// reading stored-block byte-aligned LEN/NLEN.
    mutating func alignToByte() {
        let drop = bitsInBuffer & 7
        if drop != 0 {
            buffer >>= drop
            bitsInBuffer -= drop
        }
    }

    /// Consume `count` whole bytes from the underlying buffer (only
    /// legal after ``alignToByte()`` and with `bitsInBuffer == 0`).
    mutating func readBytes(_ count: Int) throws(DeflateError) -> ContiguousArray<UInt8> {
        // The bit-buffer may still hold full bytes after alignToByte if
        // we'd refilled past a byte boundary; flush them first.
        var out = ContiguousArray<UInt8>()
        out.reserveCapacity(count)
        var remaining = count
        while bitsInBuffer >= 8 && remaining > 0 {
            out.append(UInt8(truncatingIfNeeded: buffer & 0xFF))
            buffer >>= 8
            bitsInBuffer -= 8
            remaining -= 1
        }
        guard bytePos + remaining <= bytes.count else {
            throw .truncated
        }
        for _ in 0..<remaining {
            out.append(bytes[bytePos])
            bytePos += 1
        }
        return out
    }

    /// Refill the bit buffer until it holds at least `bits` bits.
    private mutating func ensure(bits: Int) throws(DeflateError) {
        while bitsInBuffer < bits {
            guard bytePos < bytes.count else {
                throw .truncated
            }
            buffer |= UInt32(bytes[bytePos]) << bitsInBuffer
            bytePos += 1
            bitsInBuffer += 8
        }
    }
}
