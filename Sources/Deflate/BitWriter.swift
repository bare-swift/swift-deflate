// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// LSB-first bit writer. Symmetric counterpart to ``BitReader``.
/// RFC 1951 § 3.1.1 says bits within a byte are emitted least-significant
/// first; multi-bit values pack the lower-order bits before higher-order.
struct BitWriter {
    private var out = ContiguousArray<UInt8>()
    private var buffer: UInt32 = 0
    private(set) var bitsInBuffer: Int = 0

    /// Append `count` low-order bits of `value` to the stream.
    /// `count` must be ≤ 25 (we drain when the buffer crosses 24 bits, so
    /// the addition of up to 25 fits inside the 32-bit accumulator).
    mutating func writeBits(_ value: UInt32, count: Int) {
        buffer |= (value & ((UInt32(1) << count) - 1)) << bitsInBuffer
        bitsInBuffer += count
        while bitsInBuffer >= 8 {
            out.append(UInt8(truncatingIfNeeded: buffer & 0xFF))
            buffer >>= 8
            bitsInBuffer -= 8
        }
    }

    mutating func writeByte(_ byte: UInt8) {
        if bitsInBuffer == 0 {
            out.append(byte)
        } else {
            writeBits(UInt32(byte), count: 8)
        }
    }

    /// Pad the current byte with zero bits up to a byte boundary.
    mutating func alignToByte() {
        let pad = (8 - bitsInBuffer) & 7
        if pad != 0 {
            writeBits(0, count: pad)
        }
    }

    /// Flush any partial final byte and return the encoded bytes.
    mutating func finish() -> Bytes {
        if bitsInBuffer > 0 {
            out.append(UInt8(truncatingIfNeeded: buffer & 0xFF))
            buffer = 0
            bitsInBuffer = 0
        }
        return Bytes(out)
    }
}
