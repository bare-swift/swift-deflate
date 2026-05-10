# swift-deflate

RFC 1951 INFLATE (DEFLATE decompression) — Sendable, Foundation-free.

Part of the [bare-swift](https://github.com/bare-swift) ecosystem.

## Install

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/bare-swift/swift-deflate.git", from: "0.1.0")
```

Then depend on the `Deflate` product:

```swift
.product(name: "Deflate", package: "swift-deflate")
```

## Usage

```swift
import Deflate
import Bytes

let compressed = bytes  // raw DEFLATE bytes (no zlib / gzip framing)
let decompressed = try Deflate.inflate(compressed)
```

For HTTP `Content-Encoding: deflate` (which actually means zlib-framed DEFLATE per RFC 7230 § 4.2.2), use **swift-zlib**. For `Content-Encoding: gzip` or `.gz` files, use **swift-gzip**.

## Scope

`swift-deflate` v0.1 ships **INFLATE only** — DEFLATE decompression. All three RFC 1951 block types are supported:

- Stored (uncompressed) — block type `00`.
- Fixed Huffman — block type `01`.
- Dynamic Huffman — block type `10`.

Block type `11` is reserved and surfaces as `DeflateError.reservedBlockType`.

Public API:

- `Deflate.inflate(_ compressed: Bytes) throws(DeflateError) -> Bytes` — single-shot decompression.
- `DeflateError` typed-throws enum (8 cases including `truncated`, `invalidHuffmanTable`, `invalidDistance`, `outputTooLarge`).

Implementation:

- LSB-first `BitReader` with peek-and-consume Huffman lookup.
- Canonical Huffman tables built from RFC 1951 § 3.2.2 with full table replication for shorter codes (one peek + one table read per symbol).
- Sliding-window back-references up to 32 KiB per the spec.
- Output capped at 32 MiB in v0.1 (configurable limit lands in v0.2).

Per [RFC-0012](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0012-phase-7-anchor-http-body-codecs.md), the **DEFLATE encoder** ships in v0.2. v0.1 prioritizes the dominant use case (HTTP servers / clients receiving compressed payloads); compression is added once the decoder is stable.

Out of scope for v0.1:

- DEFLATE encoder. Defer to v0.2.
- Streaming / partial decompression (`AsyncSequence<Bytes>` or callback-based incremental). Defer to v0.2 alongside the encoder.
- Block-by-block introspection / debugging APIs.

## Documentation

Full DocC documentation: <https://bare-swift.github.io/swift-deflate/>

## Source

No upstream Rust crate; this is a native bare-swift package implementing RFC 1951 directly.

## License

Apache 2.0 with LLVM exception. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
