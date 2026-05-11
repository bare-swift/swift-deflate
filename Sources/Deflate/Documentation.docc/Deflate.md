# ``Deflate``

RFC 1951 DEFLATE codec — decompression (v0.1+) and compression (v0.2+). Sendable, Foundation-free.

## Overview

`Deflate` provides both halves of RFC 1951:

- `Deflate.inflate(_:)` — v0.1+. Decompresses a DEFLATE bit stream.
- `Deflate.encode(_:level:)` — v0.2+. Compresses a `Bytes` payload at a configurable level.

Input and output are `Bytes`. All three block types defined by the spec are supported on both sides:

- Stored (uncompressed) — block type `00`.
- Fixed Huffman — block type `01`.
- Dynamic Huffman — block type `10`.

Block type `11` is reserved and surfaces as ``DeflateError/reservedBlockType`` on decode.

```swift
import Deflate
import Bytes

// Decode.
let compressed = bytes
let decompressed = try Deflate.inflate(compressed)

// Encode.
let encoded = Deflate.encode(decompressed, level: .default)
// Round-trip property: Deflate.inflate(encoded) == decompressed
```

For HTTP `Content-Encoding: deflate` (which means zlib-framed DEFLATE per RFC 7230 § 4.2.2), use **swift-zlib**. For `Content-Encoding: gzip` or `.gz` files, use **swift-gzip**.

Per [RFC-0014](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0014-phase-9-anchor-compression-encoder-sweep.md), v0.2 commits to **correctness** — zopfli-style size tuning lands as v0.2.x patch releases.

## Topics

### Decompression (v0.1+)

- ``Deflate/inflate(_:)``

### Compression (v0.2+)

- ``Deflate/encode(_:level:)``
- ``Deflate/Encoder``
- ``Deflate/Encoder/Level``

### Errors

- ``DeflateError``
