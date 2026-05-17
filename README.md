# swift-deflate

RFC 1951 DEFLATE codec — inflate (v0.1) + one-shot encode (v0.2) + streaming encode (v0.3) + drain() for multi-coding composition (v0.4) + streaming-symmetric decode API (v0.5). Sendable, Foundation-free.

Part of the [bare-swift](https://github.com/bare-swift) ecosystem.

## Install

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/bare-swift/swift-deflate.git", from: "0.5.0")
```

Then depend on the `Deflate` product:

```swift
.product(name: "Deflate", package: "swift-deflate")
```

## Usage

### Decompression (v0.1+)

```swift
import Deflate
import Bytes

let compressed = bytes  // raw DEFLATE bytes (no zlib / gzip framing)
let decompressed = try Deflate.inflate(compressed)
```

### Compression (v0.2+)

```swift
import Deflate
import Bytes

let compressed = Deflate.encode(payload, level: .default)
// Round-trip property: Deflate.inflate(compressed) == payload
```

### Streaming compression (v0.3+)

```swift
import Deflate
import Bytes

var encoder = Deflate.Streaming.Encoder(level: .default)
encoder.update(chunk1)
encoder.update(chunk2)
let compressed = try encoder.finish()
let plain = try Deflate.inflate(compressed)
// plain == chunk1 + chunk2
```

Each `update(_:)` emits one DEFLATE block per chunk (dynamic-Huffman for
non-`.none` levels; stored blocks for `.none`). Empty chunks are no-ops.
`finish()` emits a 5-byte empty-stored-block terminator and returns the
full stream. After `finish()` the encoder is consumed — further
`update(_:)` calls are silent no-ops; another `finish()` throws
`encoderFinished`.

`Deflate.Streaming.Encoder` does not carry LZ77 match search across
chunk boundaries in v0.3. Matches that span chunks are not found,
slightly hurting compression ratio compared to `Deflate.encode(_:)`
one-shot. This is a v0.4 deferral.

Levels:

- `.none` — stored blocks only; no compression. Useful for streams that are already compressed (DEFLATE would only add overhead).
- `.fast` — fixed Huffman codes plus a short hash-chain. Lowest CPU.
- `.default` — dynamic Huffman with a depth-32 hash-chain. Balanced.
- `.best` — dynamic Huffman with a depth-4096 hash-chain + lazy matching. Smallest output; highest CPU.

For HTTP `Content-Encoding: deflate` (which actually means zlib-framed DEFLATE per RFC 7230 § 4.2.2), use **swift-zlib**. For `Content-Encoding: gzip` or `.gz` files, use **swift-gzip**.

## Scope

`swift-deflate` v0.2 ships **both halves** of RFC 1951 — INFLATE (decompression) and DEFLATE (compression). All three RFC 1951 block types are supported on both sides:

- Stored (uncompressed) — block type `00`.
- Fixed Huffman — block type `01`.
- Dynamic Huffman — block type `10`.

Block type `11` is reserved and surfaces as `DeflateError.reservedBlockType`.

Public API:

- `Deflate.inflate(_ compressed: Bytes) throws(DeflateError) -> Bytes` — single-shot decompression.
- `Deflate.encode(_ input: Bytes, level: Encoder.Level = .default) -> Bytes` — single-shot compression.
- `Deflate.Encoder` value type with `.write` + `.finish` for explicit lifecycle.
- `Deflate.Streaming.Encoder` value type — streaming compression (v0.3+) with `.init(level:)` + `.update(_:)` + `.finish() throws -> Bytes`.
- `Deflate.Encoder.Level` enum: `.none`, `.fast`, `.default`, `.best`.
- `DeflateError` typed-throws enum (9 cases including `truncated`, `invalidHuffmanTable`, `invalidDistance`, `outputTooLarge`, `encoderFinished`).

Implementation:

- LSB-first `BitReader` / `BitWriter` pair with peek-and-consume Huffman lookup on the read side.
- Canonical Huffman tables built from RFC 1951 § 3.2.2 with full table replication on decode; length-limited package-merge construction on encode.
- LZ77 hash-chain matcher with configurable max-chain depth and optional lazy matching.
- Sliding-window back-references up to 32 KiB per the spec.
- Encoder block-type selection: stored / fixed / dynamic candidates produced; smallest emitted.
- Output capped at 32 MiB on decode (configurable limit lands in v0.3).

Per [RFC-0014](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0014-phase-9-anchor-compression-encoder-sweep.md), v0.2 commits to **correctness** — zopfli-style size tuning lands as v0.2.x patch releases.

Out of scope for v0.2:

- Streaming / partial encode and decode. v0.2 takes a single full `Bytes` input on each side; streaming API ships in v0.3.
- Multi-pass size optimization (zopfli-style). Future v0.2.x patch.
- Preset dictionary encoding. Future v0.3 if requested.
- Block-by-block introspection / debugging APIs.

## Documentation

Full DocC documentation: <https://bare-swift.github.io/swift-deflate/>

## Source

No upstream Rust crate; this is a native bare-swift package implementing RFC 1951 directly.

## License

Apache 2.0 with LLVM exception. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
