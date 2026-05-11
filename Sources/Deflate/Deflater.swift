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
            return encodeFixedHuffman(input, maxChain: 8)
        case .default:
            return encodeDynamic(input, maxChain: 32)
        case .best:
            return encodeDynamic(input, maxChain: 4096)
        }
    }

    private func encodeDynamic(_ input: Bytes, maxChain: Int) -> Bytes {
        var writer = BitWriter()
        let tokens = collectTokens(input, maxChain: maxChain)
        BlockEncoder.emitDynamic(tokens: tokens, isFinal: true, writer: &writer)
        return writer.finish()
    }

    private func collectTokens(_ input: Bytes, maxChain: Int) -> [Token] {
        var tokens: [Token] = []
        var matcher = Matcher(input.storage, maxChain: maxChain)
        let total = input.storage.count
        var pos = 0
        while pos < total {
            let (matchLen, matchDist) = matcher.findMatch(at: pos)
            if matchLen >= Matcher.minMatch {
                tokens.append(.match(length: matchLen, distance: matchDist))
                for k in 1..<matchLen where pos + k + Matcher.minMatch <= total {
                    _ = matcher.findMatch(at: pos + k)
                }
                pos += matchLen
            } else {
                tokens.append(.literal(input.storage[pos]))
                pos += 1
            }
        }
        return tokens
    }

    private func encodeFixedHuffman(_ input: Bytes, maxChain: Int) -> Bytes {
        var writer = BitWriter()
        writer.writeBits(1, count: 1)
        writer.writeBits(1, count: 2)

        var matcher = Matcher(input.storage, maxChain: maxChain)
        let total = input.storage.count
        var pos = 0

        while pos < total {
            let (matchLen, matchDist) = matcher.findMatch(at: pos)
            if matchLen >= Matcher.minMatch {
                emitLengthDistance(length: matchLen, distance: matchDist, writer: &writer)
                for k in 1..<matchLen where pos + k + Matcher.minMatch <= total {
                    _ = matcher.findMatch(at: pos + k)
                }
                pos += matchLen
            } else {
                emitLiteral(input.storage[pos], writer: &writer)
                pos += 1
            }
        }
        let (eobCode, eobLen) = Tables.fixedLitLenCodes[256]
        writer.writeBits(Tables.reverseBits(eobCode, bits: eobLen), count: eobLen)
        return writer.finish()
    }

    private func emitLiteral(_ byte: UInt8, writer: inout BitWriter) {
        let (code, len) = Tables.fixedLitLenCodes[Int(byte)]
        writer.writeBits(Tables.reverseBits(code, bits: len), count: len)
    }

    private func emitLengthDistance(length: Int, distance: Int, writer: inout BitWriter) {
        let (lcode, lextra, lextraBits) = Tables.encodeLengthCode(length)
        let (lcCode, lcLen) = Tables.fixedLitLenCodes[lcode]
        writer.writeBits(Tables.reverseBits(lcCode, bits: lcLen), count: lcLen)
        if lextraBits > 0 {
            writer.writeBits(lextra, count: lextraBits)
        }
        let (dcode, dextra, dextraBits) = Tables.encodeDistanceCode(distance)
        let (dcCode, dcLen) = Tables.fixedDistanceCodes[dcode]
        writer.writeBits(Tables.reverseBits(dcCode, bits: dcLen), count: dcLen)
        if dextraBits > 0 {
            writer.writeBits(dextra, count: dextraBits)
        }
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
