// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// State-machine INFLATE driver for streaming decode (v0.6+).
///
/// Holds a growing `BitReader`, an output buffer, and a `Phase` capturing
/// inter-block + intra-block position. ``feed(_:)`` appends compressed
/// input; ``run()`` consumes as much as possible, pausing cleanly when
/// input is exhausted. Adopters interact through
/// ``Deflate/Streaming/Decoder``; this type is package-internal.
///
/// Snapshots are taken at well-defined checkpoint boundaries (between
/// symbols, before each stored-block byte read). A `.truncated` throw
/// inside a checkpointed scope rewinds the reader to the snapshot so the
/// next `run()` resumes from a clean position.
struct StreamingInflater: Sendable {
    /// Inter- and intra-block position.
    enum Phase: Sendable {
        /// Ready to read next block header (BFINAL + BTYPE).
        case awaitingBlockHeader

        /// In a stored block (BTYPE=00). `remaining` bytes still to copy.
        case inStored(lastBlock: Bool, remaining: Int)

        /// In a Huffman block (fixed BTYPE=01 or dynamic BTYPE=10).
        /// `distance` is `nil` only for dynamic blocks that declared no
        /// distance codes (RFC 1951 § 3.2.7 literals-only edge case).
        case inHuffmanBody(
            lastBlock: Bool,
            litLen: HuffmanDecoder,
            distance: HuffmanDecoder?)

        /// All blocks consumed (the last block carried BFINAL=1 and we
        /// decoded its end-of-block symbol or copied its full stored
        /// payload).
        case done
    }

    var reader: BitReader
    var output: ContiguousArray<UInt8>
    var phase: Phase

    /// Implementation cap on the output buffer (matches Inflater.outputLimit).
    static let outputLimit = Inflater.outputLimit

    init() {
        self.reader = BitReader()
        self.output = ContiguousArray<UInt8>()
        self.phase = .awaitingBlockHeader
    }

    /// Append new compressed bytes to the reader buffer.
    mutating func feed(_ chunk: ContiguousArray<UInt8>) {
        reader.append(chunk)
    }

    /// Run the state machine forward as far as the buffered input allows.
    /// Returns when either:
    /// - `phase == .done`: stream complete.
    /// - A `.truncated` was caught and the reader rewound: more input needed.
    ///
    /// Throws any DeflateError other than `.truncated` directly. The
    /// caller (Decoder) is responsible for surfacing errors at the right
    /// API boundary.
    mutating func run() throws(DeflateError) {
        loop: while true {
            switch phase {
            case .done:
                return

            case .awaitingBlockHeader:
                let snap = reader.snapshot()
                do {
                    try startBlock()
                } catch DeflateError.truncated {
                    reader.restore(snap)
                    return  // need more input
                }

            case .inStored(let lastBlock, var remaining):
                // Handle zero-length stored block first (notably the
                // BFINAL=1 terminator block LEN=0). Without this, we'd
                // wait forever for non-existent payload bytes.
                if remaining == 0 {
                    phase = lastBlock ? .done : .awaitingBlockHeader
                    continue loop
                }
                // Greedy: consume what's available without throwing on
                // partial input. If we exhaust the buffer mid-block,
                // pause cleanly with phase updated.
                let avail = reader.availableBytesAligned()
                if avail == 0 {
                    phase = .inStored(lastBlock: lastBlock, remaining: remaining)
                    return  // need more input
                }
                let toCopy = Swift.min(remaining, avail)
                if output.count + toCopy > Self.outputLimit {
                    throw DeflateError.outputTooLarge
                }
                // readBytes(_:) won't throw because avail ≥ toCopy.
                let payload = try reader.readBytes(toCopy)
                output.append(contentsOf: payload)
                remaining -= toCopy
                if remaining == 0 {
                    phase = lastBlock ? .done : .awaitingBlockHeader
                } else {
                    phase = .inStored(lastBlock: lastBlock, remaining: remaining)
                    return  // need more input for the rest
                }

            case .inHuffmanBody(let lastBlock, var litLen, var distance):
                let snap = reader.snapshot()
                let endOfBlock: Bool
                do {
                    endOfBlock = try decodeHuffmanSymbol(
                        litLen: &litLen, distance: &distance)
                } catch DeflateError.truncated {
                    // Rewind to clean pre-symbol checkpoint and pause.
                    reader.restore(snap)
                    return
                } catch let e as DeflateError {
                    throw e
                }
                if endOfBlock {
                    phase = lastBlock ? .done : .awaitingBlockHeader
                } else {
                    phase = .inHuffmanBody(
                        lastBlock: lastBlock,
                        litLen: litLen,
                        distance: distance)
                }
            }
        }
    }

    // MARK: - Block header

    /// Start a new block: read BFINAL + BTYPE, then either prepare
    /// stored-block state or read the Huffman tables (fixed or dynamic).
    /// Throws `.truncated` cleanly if the entire header parse can't
    /// complete from buffered input.
    private mutating func startBlock() throws(DeflateError) {
        let lastBlock = try reader.readBit()
        let blockType = try reader.readBits(2)
        switch blockType {
        case 0b00:
            // Stored: align, read LEN/NLEN.
            reader.alignToByte()
            let lenBytes = try reader.readBytes(4)
            let len = Int(lenBytes[0]) | (Int(lenBytes[1]) << 8)
            let nlen = Int(lenBytes[2]) | (Int(lenBytes[3]) << 8)
            if len ^ 0xFFFF != nlen {
                throw .invalidStoredBlockLength
            }
            phase = .inStored(lastBlock: lastBlock, remaining: len)

        case 0b01:
            let litLen = try HuffmanDecoder(codeLengths: Tables.fixedLitLenLengths)
            let distance = try HuffmanDecoder(codeLengths: Tables.fixedDistanceLengths)
            phase = .inHuffmanBody(
                lastBlock: lastBlock,
                litLen: litLen,
                distance: distance)

        case 0b10:
            let (litLen, distance) = try readDynamicTables()
            phase = .inHuffmanBody(
                lastBlock: lastBlock,
                litLen: litLen,
                distance: distance)

        default:
            throw .reservedBlockType
        }
    }

    /// Read a dynamic-Huffman block's table declarations. Returns
    /// `(litLenDecoder, distanceDecoder?)`; the distance decoder is `nil`
    /// when the block declared no distance codes (RFC 1951 § 3.2.7).
    private mutating func readDynamicTables()
        throws(DeflateError) -> (HuffmanDecoder, HuffmanDecoder?)
    {
        let hlit = Int(try reader.readBits(5)) + 257
        let hdist = Int(try reader.readBits(5)) + 1
        let hclen = Int(try reader.readBits(4)) + 4

        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            clLengths[Tables.codeLengthOrder[i]] = Int(try reader.readBits(3))
        }
        var codeLengthDecoder = try HuffmanDecoder(codeLengths: clLengths)

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
        let litLen = try HuffmanDecoder(codeLengths: litLenLengths)
        if distLengths.allSatisfy({ $0 == 0 }) {
            return (litLen, nil)
        }
        let distance = try HuffmanDecoder(codeLengths: distLengths)
        return (litLen, distance)
    }

    // MARK: - Huffman body

    /// Decode one Huffman symbol (literal, end-of-block, or length/distance
    /// pair followed by match copy). Returns `true` iff end-of-block was
    /// hit. Throws `.truncated` if the symbol can't be completed from
    /// buffered input. The caller is responsible for snapshotting and
    /// restoring the reader if pause-and-resume semantics are needed.
    private mutating func decodeHuffmanSymbol(
        litLen: inout HuffmanDecoder,
        distance: inout HuffmanDecoder?
    ) throws(DeflateError) -> Bool {
        let symbol = try litLen.decode(&reader)
        if symbol < 256 {
            if output.count >= Self.outputLimit {
                throw DeflateError.outputTooLarge
            }
            output.append(UInt8(symbol))
            return false
        }
        if symbol == 256 {
            return true
        }
        // Length/distance pair.
        let lengthIndex = Int(symbol) - 257
        if lengthIndex < 0 || lengthIndex >= Tables.lengthBase.count {
            throw DeflateError.invalidLengthCode
        }
        var length = Tables.lengthBase[lengthIndex]
        let lengthExtra = Tables.lengthExtra[lengthIndex]
        if lengthExtra > 0 {
            length += Int(try reader.readBits(lengthExtra))
        }
        guard distance != nil else {
            throw DeflateError.invalidDistance
        }
        let distSymbol = try distance!.decode(&reader)
        let distIndex = Int(distSymbol)
        if distIndex < 0 || distIndex >= Tables.distanceBase.count {
            throw DeflateError.invalidDistance
        }
        var dist = Tables.distanceBase[distIndex]
        let distExtra = Tables.distanceExtra[distIndex]
        if distExtra > 0 {
            dist += Int(try reader.readBits(distExtra))
        }
        if dist > output.count {
            throw DeflateError.invalidDistance
        }
        if output.count + length > Self.outputLimit {
            throw DeflateError.outputTooLarge
        }
        // Match copy is atomic — no reader access from here.
        for _ in 0..<length {
            let byte = output[output.count - dist]
            output.append(byte)
        }
        return false
    }
}
