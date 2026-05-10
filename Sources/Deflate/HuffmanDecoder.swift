// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

/// Canonical-Huffman decoder built from a code-length array per
/// RFC 1951 § 3.2.2. Symbol order in the input array is the alphabet
/// position; entry value is the symbol's code length in bits (0 means
/// the symbol is absent from the alphabet).
///
/// Decoding uses a flat lookup table indexed by the next `maxLength`
/// bits read LSB-first. Symbols with code length `L < maxLength` occupy
/// `2^(maxLength - L)` slots whose low `L` bits match the symbol's
/// LSB-first canonical code; one peek + one table read decodes a symbol.
struct HuffmanDecoder {
    /// Each entry packs `(symbol << 4) | codeLength`. `codeLength == 0`
    /// signals an unfilled slot (decoding it throws `.invalidSymbol`).
    let entries: [UInt32]
    let maxLength: Int

    init(codeLengths: [Int]) throws(DeflateError) {
        // Step 1 — find max code length present.
        var maxLen = 0
        for length in codeLengths where length > maxLen { maxLen = length }
        if maxLen == 0 {
            throw .invalidHuffmanTable
        }
        if maxLen > 15 {
            throw .invalidHuffmanTable
        }

        // Step 2 — count codes by length.
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for length in codeLengths where length > 0 {
            blCount[length] += 1
        }

        // RFC 1951 § 3.2.2: a single-symbol code of length 1 is allowed
        // (the spec mentions in § 3.2.7 that the unused symbol 0
        // case for code-length codes uses length 1). We accept it.

        // Step 3 — derive starting code for each length (canonical order).
        var nextCode = [UInt32](repeating: 0, count: maxLen + 1)
        var code: UInt32 = 0
        for bits in 1...maxLen {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }

        // Step 4 — assign canonical codes per symbol; reverse to LSB
        // form because BitReader yields LSB-first; replicate across
        // all matching slots in the maxLength-indexed table.
        var entries = [UInt32](repeating: 0, count: 1 << maxLen)
        for symbol in 0..<codeLengths.count {
            let length = codeLengths[symbol]
            guard length > 0 else { continue }
            let canonical = nextCode[length]
            nextCode[length] += 1

            // Reverse `length` low bits of `canonical`.
            var lsb: UInt32 = 0
            var src = canonical
            for _ in 0..<length {
                lsb = (lsb << 1) | (src & 1)
                src >>= 1
            }

            // Fill every table slot whose low `length` bits == lsb.
            let stride = UInt32(1) << length
            let entry = (UInt32(symbol) << 4) | UInt32(length)
            var i = lsb
            let total = UInt32(1) << maxLen
            while i < total {
                entries[Int(i)] = entry
                i &+= stride
            }
        }

        self.entries = entries
        self.maxLength = maxLen
    }

    /// Decode the next symbol. Peeks `maxLength` bits (zero-padded at
    /// EOF), looks up in `entries`, then consumes the symbol's code
    /// length — `consume` throws `.truncated` if the actual code length
    /// exceeds the bits truly remaining.
    mutating func decode(_ reader: inout BitReader) throws(DeflateError) -> UInt32 {
        let bits = reader.peekBits(maxLength)
        let entry = entries[Int(bits)]
        let length = Int(entry & 0xF)
        if length == 0 {
            throw .invalidSymbol
        }
        try reader.consume(length)
        return entry >> 4
    }
}
