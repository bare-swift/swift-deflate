// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

/// Sendable, Foundation-free [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951.html)
/// INFLATE — DEFLATE decompression.
///
/// `Deflate.inflate(_:)` takes a raw DEFLATE-compressed `Bytes` payload
/// (no zlib or gzip framing) and returns the decompressed `Bytes`. Use
/// **swift-zlib** for `Content-Encoding: deflate` (which actually means
/// zlib-framed DEFLATE in HTTP per RFC 7230 § 4.2.2) or **swift-gzip**
/// for `Content-Encoding: gzip` / `.gz` files.
///
/// Per [RFC-0012](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0012-phase-7-anchor-http-body-codecs.md),
/// **v0.1 ships INFLATE only**. The DEFLATE encoder lands in v0.2.
///
/// All three RFC 1951 block types are supported:
/// - Stored (uncompressed) — block type `00`.
/// - Fixed Huffman — block type `01`.
/// - Dynamic Huffman — block type `10`.
///
/// Block type `11` is reserved and surfaces as ``DeflateError/reservedBlockType``.
/// Sliding-window back-references go up to 32 KiB per the spec.
public enum Deflate: Sendable {
    /// Decompress a DEFLATE-compressed payload.
    public static func inflate(_ compressed: Bytes) throws(DeflateError) -> Bytes {
        try Inflater.inflate(compressed)
    }
}

extension Deflate {
    /// DEFLATE compression entry point. Returns an RFC 1951 bit stream
    /// (no zlib or gzip framing).
    ///
    /// Per [RFC-0014](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0014-phase-9-anchor-compression-encoder-sweep.md),
    /// v0.2 commits to *correctness* — zopfli-style size tuning is out of
    /// scope and will land as v0.2.x patch releases.
    public static func encode(_ input: Bytes, level: Encoder.Level = .default) -> Bytes {
        var encoder = Encoder(level: level)
        encoder.write(input)
        return encoder.finish()
    }

    /// DEFLATE encoder state. Single-shot in v0.2: call ``write(_:)`` once,
    /// then ``finish()``. Streaming encoder ships as part of v0.3.
    public struct Encoder: Sendable {
        public enum Level: Sendable, Equatable {
            /// Stored blocks only — no compression, useful for already-
            /// compressed payloads where DEFLATE would only add overhead.
            case none
            /// Fixed Huffman codes (no dynamic header overhead). LZ77
            /// matching uses a short hash-chain.
            case fast
            /// Dynamic Huffman codes, moderate hash-chain depth. Best
            /// general-purpose choice.
            case `default`
            /// Dynamic Huffman codes, deeper hash-chain + lazy matching.
            /// Smallest output at the cost of CPU.
            case best
        }

        public let level: Level
        private var buffer = Bytes()

        public init(level: Level = .default) {
            self.level = level
        }

        public mutating func write(_ input: Bytes) {
            buffer.append(contentsOf: input.storage)
        }

        public mutating func finish() -> Bytes {
            Deflater(level: level).encode(buffer)
        }
    }
}
