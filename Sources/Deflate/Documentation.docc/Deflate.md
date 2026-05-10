# ``Deflate``

RFC 1951 INFLATE (DEFLATE decompression) — Sendable, Foundation-free.

## Overview

`Deflate` decompresses raw DEFLATE-compressed payloads per
[RFC 1951](https://www.rfc-editor.org/rfc/rfc1951.html). Input and
output are `Bytes`. All three block types defined by the spec are
supported:

- Stored (uncompressed) — block type `00`.
- Fixed Huffman — block type `01`.
- Dynamic Huffman — block type `10`.

Block type `11` is reserved and surfaces as ``DeflateError/reservedBlockType``.

```swift
import Deflate
import Bytes

let compressed = bytes  // raw DEFLATE bytes (no zlib / gzip framing)
let decompressed = try Deflate.inflate(compressed)
```

For HTTP `Content-Encoding: deflate` (which means zlib-framed DEFLATE
per RFC 7230 § 4.2.2), use **swift-zlib**. For `Content-Encoding: gzip`
or `.gz` files, use **swift-gzip**.

Per [RFC-0012](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0012-phase-7-anchor-http-body-codecs.md),
**v0.1 ships INFLATE only**. The DEFLATE encoder lands in v0.2.

## Topics

### Essentials

- ``DeflateError``
