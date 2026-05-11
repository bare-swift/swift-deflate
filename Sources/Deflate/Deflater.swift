// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// Internal driver for DEFLATE encoding. Public entry is
/// ``Deflate/encode(_:level:)``.
struct Deflater {
    let level: Deflate.Encoder.Level

    /// RFC 1951 stored blocks carry a 16-bit length field, so the max
    /// payload per stored block is 65 535 bytes.
    static let storedBlockMax = 65_535

    func encode(_ input: Bytes) -> Bytes {
        switch level {
        case .none:
            return encodeStoredOnly(input)
        case .fast:
            return encodeFixedLiteralsOnly(input)
        case .default, .best:
            // Implemented in later tasks.
            return encodeFixedLiteralsOnly(input)
        }
    }

    private func encodeFixedLiteralsOnly(_ input: Bytes) -> Bytes {
        var writer = BitWriter()
        writer.writeBits(1, count: 1)
        writer.writeBits(1, count: 2)
        for byte in input.storage {
            let (code, len) = Tables.fixedLitLenCodes[Int(byte)]
            let rev = Tables.reverseBits(code, bits: len)
            writer.writeBits(rev, count: len)
        }
        let (eobCode, eobLen) = Tables.fixedLitLenCodes[256]
        let eobRev = Tables.reverseBits(eobCode, bits: eobLen)
        writer.writeBits(eobRev, count: eobLen)
        return writer.finish()
    }

    private func encodeStoredOnly(_ input: Bytes) -> Bytes {
        var writer = BitWriter()
        let total = input.storage.count
        if total == 0 {
            // RFC 1951 § 3.2.4: an empty stored block has BFINAL=1, BTYPE=00,
            // align to byte, LEN=0, NLEN=0xFFFF.
            writer.writeBits(1, count: 1)
            writer.writeBits(0, count: 2)
            writer.alignToByte()
            writer.writeByte(0x00); writer.writeByte(0x00)
            writer.writeByte(0xFF); writer.writeByte(0xFF)
            return writer.finish()
        }

        var pos = 0
        while pos < total {
            let chunk = min(Self.storedBlockMax, total - pos)
            let isFinal = (pos + chunk) == total
            writer.writeBits(isFinal ? 1 : 0, count: 1)
            writer.writeBits(0, count: 2)
            writer.alignToByte()
            let len = UInt16(chunk)
            let nlen = ~len
            writer.writeByte(UInt8(truncatingIfNeeded: len & 0xFF))
            writer.writeByte(UInt8(truncatingIfNeeded: (len >> 8) & 0xFF))
            writer.writeByte(UInt8(truncatingIfNeeded: nlen & 0xFF))
            writer.writeByte(UInt8(truncatingIfNeeded: (nlen >> 8) & 0xFF))
            for i in 0..<chunk {
                writer.writeByte(input.storage[pos + i])
            }
            pos += chunk
        }
        return writer.finish()
    }
}
