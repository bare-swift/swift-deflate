// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

/// Errors thrown by ``Deflate/inflate(_:)``.
public enum DeflateError: Error, Equatable, Sendable {
    /// Decoder ran out of compressed bits mid-block.
    case truncated

    /// Block type bits read as `11` (reserved per RFC 1951 § 3.2.3).
    case reservedBlockType

    /// Stored-block length and its 1's-complement check disagreed.
    case invalidStoredBlockLength

    /// Huffman code-length array couldn't form a canonical prefix code
    /// (over- or under-subscribed).
    case invalidHuffmanTable

    /// Decoded a Huffman symbol outside the legal alphabet.
    case invalidSymbol

    /// Length code carried extra bits whose decode produced an
    /// out-of-range length.
    case invalidLengthCode

    /// Distance code yielded a back-reference that pointed before the
    /// start of the output buffer.
    case invalidDistance

    /// Output buffer hit an implementation-imposed cap (32 MiB by
    /// default; expose a configurable limit in v0.2).
    case outputTooLarge
}
