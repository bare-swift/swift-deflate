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
