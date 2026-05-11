// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// One LZ77 symbol — either a literal byte or a (length, distance) match.
enum Token {
    case literal(UInt8)
    case match(length: Int, distance: Int)
}

/// Emits a single DEFLATE block from a token stream.
enum BlockEncoder {
    /// Emit a dynamic-Huffman block. `isFinal` controls BFINAL.
    static func emitDynamic(tokens: [Token], isFinal: Bool, writer: inout BitWriter) {
        // 1. Histogram literal/length and distance symbols.
        var litFreq = [Int](repeating: 0, count: 286)
        var distFreq = [Int](repeating: 0, count: 30)
        for t in tokens {
            switch t {
            case .literal(let b):
                litFreq[Int(b)] += 1
            case .match(let length, let distance):
                let (lcode, _, _) = Tables.encodeLengthCode(length)
                litFreq[lcode] += 1
                let (dcode, _, _) = Tables.encodeDistanceCode(distance)
                distFreq[dcode] += 1
            }
        }
        litFreq[256] += 1  // EOB symbol

        // 2. Build code lengths (length-limited to 15 bits per RFC 1951).
        let litLens = HuffmanEncoder.buildLengths(frequencies: litFreq, maxBits: 15)
        var distLens = HuffmanEncoder.buildLengths(frequencies: distFreq, maxBits: 15)
        // RFC 1951 § 3.2.7: at least one distance code must be present.
        if distLens.allSatisfy({ $0 == 0 }) {
            distLens[0] = 1
        }

        // 3. Trim trailing zeros to compute HLIT / HDIST.
        var hlit = 286
        while hlit > 257 && litLens[hlit - 1] == 0 { hlit -= 1 }
        var hdist = 30
        while hdist > 1 && distLens[hdist - 1] == 0 { hdist -= 1 }

        // 4. Run-length encode the concatenated litLens + distLens code-
        //    length sequence.
        let combined = Array(litLens.prefix(hlit)) + Array(distLens.prefix(hdist))
        let (clSymbols, clExtras) = runLengthEncodeCodeLengths(combined)

        // 5. Build code lengths for the code-length alphabet (max 7 bits).
        var clFreq = [Int](repeating: 0, count: 19)
        for s in clSymbols { clFreq[s] += 1 }
        let clLens = HuffmanEncoder.buildLengths(frequencies: clFreq, maxBits: 7)

        // 6. Reorder clLens per Tables.codeLengthOrder and compute HCLEN.
        var clReordered = [Int](repeating: 0, count: 19)
        for i in 0..<19 { clReordered[i] = clLens[Tables.codeLengthOrder[i]] }
        var hclen = 19
        while hclen > 4 && clReordered[hclen - 1] == 0 { hclen -= 1 }

        // 7. Emit block header.
        writer.writeBits(isFinal ? 1 : 0, count: 1)
        writer.writeBits(2, count: 2)  // BTYPE = 10 (dynamic)
        writer.writeBits(UInt32(hlit - 257), count: 5)
        writer.writeBits(UInt32(hdist - 1),  count: 5)
        writer.writeBits(UInt32(hclen - 4),  count: 4)
        for i in 0..<hclen {
            writer.writeBits(UInt32(clReordered[i]), count: 3)
        }

        // 8. Emit run-length-encoded code-length sequence.
        let clCodes = HuffmanEncoder.canonicalCodes(lengths: clLens)
        for (sym, extra) in zip(clSymbols, clExtras) {
            let len = clLens[sym]
            writer.writeBits(Tables.reverseBits(clCodes[sym], bits: len), count: len)
            switch sym {
            case 16: writer.writeBits(UInt32(extra), count: 2)
            case 17: writer.writeBits(UInt32(extra), count: 3)
            case 18: writer.writeBits(UInt32(extra), count: 7)
            default: break
            }
        }

        // 9. Build canonical codes for literal/length and distance alphabets.
        let litCodes = HuffmanEncoder.canonicalCodes(lengths: litLens)
        let distCodes = HuffmanEncoder.canonicalCodes(lengths: distLens)

        // 10. Emit the token stream.
        for t in tokens {
            switch t {
            case .literal(let b):
                let sym = Int(b)
                let len = litLens[sym]
                writer.writeBits(Tables.reverseBits(litCodes[sym], bits: len), count: len)
            case .match(let length, let distance):
                let (lcode, lextra, lextraBits) = Tables.encodeLengthCode(length)
                let llen = litLens[lcode]
                writer.writeBits(Tables.reverseBits(litCodes[lcode], bits: llen), count: llen)
                if lextraBits > 0 {
                    writer.writeBits(lextra, count: lextraBits)
                }
                let (dcode, dextra, dextraBits) = Tables.encodeDistanceCode(distance)
                let dlen = distLens[dcode]
                writer.writeBits(Tables.reverseBits(distCodes[dcode], bits: dlen), count: dlen)
                if dextraBits > 0 {
                    writer.writeBits(dextra, count: dextraBits)
                }
            }
        }
        let eobLen = litLens[256]
        writer.writeBits(Tables.reverseBits(litCodes[256], bits: eobLen), count: eobLen)
    }

    /// Run-length encode a code-length array into the 0..18 alphabet per
    /// RFC 1951 § 3.2.7.
    private static func runLengthEncodeCodeLengths(_ lengths: [Int]) -> (symbols: [Int], extras: [Int]) {
        var symbols: [Int] = []
        var extras: [Int] = []
        var i = 0
        while i < lengths.count {
            let value = lengths[i]
            var run = 1
            while i + run < lengths.count && lengths[i + run] == value && run < 138 {
                run += 1
            }
            if value == 0 {
                if run >= 11 {
                    let chunk = min(run, 138)
                    symbols.append(18)
                    extras.append(chunk - 11)
                    i += chunk
                } else if run >= 3 {
                    symbols.append(17)
                    extras.append(run - 3)
                    i += run
                } else {
                    for _ in 0..<run {
                        symbols.append(0); extras.append(0)
                    }
                    i += run
                }
            } else {
                symbols.append(value); extras.append(0)
                var remaining = run - 1
                i += 1
                while remaining >= 3 {
                    let chunk = min(remaining, 6)
                    symbols.append(16)
                    extras.append(chunk - 3)
                    remaining -= chunk
                    i += chunk
                }
                while remaining > 0 {
                    symbols.append(value); extras.append(0)
                    remaining -= 1
                    i += 1
                }
            }
        }
        return (symbols, extras)
    }
}
