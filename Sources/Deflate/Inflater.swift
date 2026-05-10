// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// Top-level INFLATE driver. Reads block headers, dispatches to the
/// appropriate per-block-type decoder, and concatenates outputs until
/// `BFINAL` is set on the last block.
enum Inflater {
    /// Implementation cap on the output buffer. v0.1 picks 32 MiB; v0.2
    /// will expose a configurable limit. The limit guards against
    /// adversarial inputs that demand unbounded memory.
    static let outputLimit = 32 * 1024 * 1024

    static func inflate(_ compressed: Bytes) throws(DeflateError) -> Bytes {
        var reader = BitReader(compressed)
        var output = ContiguousArray<UInt8>()
        output.reserveCapacity(compressed.count * 4)  // rough heuristic

        var lastBlock = false
        while !lastBlock {
            lastBlock = try reader.readBit()
            let blockType = try reader.readBits(2)

            switch blockType {
            case 0b00:
                try inflateStored(reader: &reader, output: &output)
            case 0b01:
                try inflateFixed(reader: &reader, output: &output)
            case 0b10:
                try inflateDynamic(reader: &reader, output: &output)
            default:
                throw .reservedBlockType
            }
        }

        return Bytes(output)
    }

    // MARK: - Stored block

    private static func inflateStored(
        reader: inout BitReader,
        output: inout ContiguousArray<UInt8>
    ) throws(DeflateError) {
        reader.alignToByte()
        let lenBytes = try reader.readBytes(4)
        let len = Int(lenBytes[0]) | (Int(lenBytes[1]) << 8)
        let nlen = Int(lenBytes[2]) | (Int(lenBytes[3]) << 8)
        if len ^ 0xFFFF != nlen {
            throw .invalidStoredBlockLength
        }
        if output.count + len > outputLimit {
            throw .outputTooLarge
        }
        let payload = try reader.readBytes(len)
        output.append(contentsOf: payload)
    }

    // MARK: - Fixed Huffman block

    private static func inflateFixed(
        reader: inout BitReader,
        output: inout ContiguousArray<UInt8>
    ) throws(DeflateError) {
        var litLen = try HuffmanDecoder(codeLengths: Tables.fixedLitLenLengths)
        var distance = try HuffmanDecoder(codeLengths: Tables.fixedDistanceLengths)
        try inflateBlockBody(reader: &reader, output: &output,
                             litLen: &litLen, distance: &distance)
    }

    // MARK: - Dynamic Huffman block

    private static func inflateDynamic(
        reader: inout BitReader,
        output: inout ContiguousArray<UInt8>
    ) throws(DeflateError) {
        let hlit = Int(try reader.readBits(5)) + 257
        let hdist = Int(try reader.readBits(5)) + 1
        let hclen = Int(try reader.readBits(4)) + 4

        // Read the code-length-code lengths in the spec's permutation order.
        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            clLengths[Tables.codeLengthOrder[i]] = Int(try reader.readBits(3))
        }
        var codeLengthDecoder = try HuffmanDecoder(codeLengths: clLengths)

        // Decode hlit + hdist code lengths using the code-length code.
        var combined = [Int]()
        combined.reserveCapacity(hlit + hdist)
        while combined.count < hlit + hdist {
            let symbol = try codeLengthDecoder.decode(&reader)
            switch symbol {
            case 0...15:
                combined.append(Int(symbol))
            case 16:
                guard let last = combined.last else {
                    throw .invalidHuffmanTable
                }
                let repeatCount = 3 + Int(try reader.readBits(2))
                for _ in 0..<repeatCount { combined.append(last) }
            case 17:
                let repeatCount = 3 + Int(try reader.readBits(3))
                for _ in 0..<repeatCount { combined.append(0) }
            case 18:
                let repeatCount = 11 + Int(try reader.readBits(7))
                for _ in 0..<repeatCount { combined.append(0) }
            default:
                throw .invalidHuffmanTable
            }
        }
        if combined.count != hlit + hdist {
            throw .invalidHuffmanTable
        }

        let litLenLengths = Array(combined.prefix(hlit))
        let distLengths = Array(combined.suffix(from: hlit))

        var litLen = try HuffmanDecoder(codeLengths: litLenLengths)
        // Distance table can be a single-symbol code (one length-1 entry);
        // RFC 1951 § 3.2.7 explicitly allows hdist = 1 with one zero length.
        // Our HuffmanDecoder rejects all-zero arrays, so handle that edge.
        if distLengths.allSatisfy({ $0 == 0 }) {
            // No distance codes — block must contain only literals.
            try inflateBlockBodyLiteralsOnly(reader: &reader, output: &output, litLen: &litLen)
            return
        }
        var distance = try HuffmanDecoder(codeLengths: distLengths)
        try inflateBlockBody(reader: &reader, output: &output,
                             litLen: &litLen, distance: &distance)
    }

    // MARK: - Block body

    /// Decode the body of a Huffman-compressed block (fixed or dynamic).
    /// Reads literal/length symbols; `< 256` is a literal byte, `256` is
    /// end-of-block, and `>= 257` is a length code followed by a
    /// distance code.
    private static func inflateBlockBody(
        reader: inout BitReader,
        output: inout ContiguousArray<UInt8>,
        litLen: inout HuffmanDecoder,
        distance: inout HuffmanDecoder
    ) throws(DeflateError) {
        while true {
            let symbol = try litLen.decode(&reader)
            if symbol < 256 {
                if output.count >= outputLimit { throw .outputTooLarge }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 {
                return  // end of block
            }
            // Length code: 257..285
            let lengthIndex = Int(symbol) - 257
            if lengthIndex < 0 || lengthIndex >= Tables.lengthBase.count {
                throw .invalidLengthCode
            }
            var length = Tables.lengthBase[lengthIndex]
            let lengthExtra = Tables.lengthExtra[lengthIndex]
            if lengthExtra > 0 {
                length += Int(try reader.readBits(lengthExtra))
            }

            // Distance code: 0..29
            let distSymbol = try distance.decode(&reader)
            let distIndex = Int(distSymbol)
            if distIndex < 0 || distIndex >= Tables.distanceBase.count {
                throw .invalidDistance
            }
            var dist = Tables.distanceBase[distIndex]
            let distExtra = Tables.distanceExtra[distIndex]
            if distExtra > 0 {
                dist += Int(try reader.readBits(distExtra))
            }

            // Copy `length` bytes from `dist` back in `output`.
            // Distance > output.count is invalid (RFC 1951 forbids it).
            if dist > output.count {
                throw .invalidDistance
            }
            if output.count + length > outputLimit {
                throw .outputTooLarge
            }
            // Note: length may exceed dist (e.g. RLE) — copy byte-by-byte
            // so each new byte sees the freshly-appended bytes.
            for _ in 0..<length {
                let byte = output[output.count - dist]
                output.append(byte)
            }
        }
    }

    /// Variant for dynamic blocks that declared no distance codes.
    private static func inflateBlockBodyLiteralsOnly(
        reader: inout BitReader,
        output: inout ContiguousArray<UInt8>,
        litLen: inout HuffmanDecoder
    ) throws(DeflateError) {
        while true {
            let symbol = try litLen.decode(&reader)
            if symbol < 256 {
                if output.count >= outputLimit { throw .outputTooLarge }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 {
                return
            }
            // Length code in a literals-only block is illegal.
            throw .invalidDistance
        }
    }
}
