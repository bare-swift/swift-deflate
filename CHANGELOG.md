# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] — 2026-05-17

### Added
- **`Deflate.Streaming.Encoder.drain() -> Bytes`** — returns the byte-aligned portion of the accumulated stream so far, resetting the internal byte buffer. The encoder remains in the open state; subsequent `update(_:)` and `finish()` calls produce the remainder. Concatenating all `drain()` returns with the final `finish()` return produces the **same bytes** as a single `finish()` call would have produced (byte-for-byte equality, per RFC 1951). Does NOT byte-align (partial-byte buffer survives) and does NOT emit a terminator block. Silent no-op (returns empty `Bytes`) after `finish()`.
- 5 new tests covering drain semantics, drain+finish round-trip, multiple-drain round-trip, drain-after-finish no-op, and byte-equality with non-draining stream.

### Use case
Multi-coding HTTP `Content-Encoding` streaming via swift-content-encoding v0.6 (Phase 28+).

### Migration (v0.3 → v0.4)
- **Additive only — non-breaking.** All v0.3 APIs unchanged.
- Existing v0.3 streams (no `drain()` calls) produce byte-identical output to v0.3.
- `DeflateError` cases unchanged.

### Phase 27
- Tranche 27B of [RFC-0032](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0032-phase-27-anchor-codec-tier-v0.4-drain-sweep.md). Codec-tier v0.4 drain() API sweep.

## [0.3.0] — 2026-05-16

### Added
- **Streaming encoder** — `Deflate.Streaming.Encoder` struct with `init(level:)` / `update(_:)` / `finish()`. Each `update(_:)` emits one DEFLATE block per chunk (dynamic-Huffman for non-`.none` levels; stored blocks for `.none`). `finish()` emits an empty-stored-block terminator (`BFINAL=1, BTYPE=00, LEN=0, NLEN=0xFFFF`).
- `Deflate.Streaming` public namespace enum.
- `DeflateError.encoderFinished` — thrown when `finish()` is called on an already-finished encoder.
- 15 new tests covering round-trip (empty, single chunk, two chunks, 100 tiny chunks, 70 KiB chunk), all four levels, and error/edge cases (double-finish, update-after-finish no-op).

### Dependencies
- No new dependencies. swift-bytes already in v0.1.

### Stream-format notes
- Streaming output is **valid DEFLATE** that decodes via the same `Deflate.inflate(_:)` v0.1 API.
- Empty stream output (`Deflate.Streaming.Encoder()` with no `update` calls + `finish()`) is **byte-equal** to `Deflate.encode(Bytes(), level: .none)`. Regression-tested.
- Single-update streaming output is **not** byte-equal to `Deflate.encode(_:)` one-shot output because (a) streaming always emits dynamic-Huffman per chunk (no 3-candidate pick-smallest), and (b) streaming adds a 5-byte stored-block terminator.
- No window carry across chunks in v0.3. LZ77 match search is per-chunk; matches across chunk boundaries are not found. Deferred to v0.4 for compression-ratio improvement.
- Streaming `.fast` / `.default` / `.best` all emit dynamic-Huffman blocks. The 3-candidate pick-smallest from v0.2 one-shot does not apply in streaming (requires future visibility).

### Migration (v0.2 → v0.3)
- **Additive only — non-breaking.** All v0.2 APIs unchanged.
- `Deflate.encode(_:level:)` continues to emit byte-equal output to v0.2 (regression-tested via existing v0.2 round-trip tests).
- `Deflate.Encoder` struct unchanged.
- `Deflate.inflate(_:)` unchanged from v0.1.
- `Deflate.Encoder.Level` unchanged.
- `DeflateError` adds 1 new case (additive; existing cases unchanged).

### Out of scope (deferred to v0.4+)
- Window carry across chunks (LZ77 across chunk boundaries — ratio improvement).
- Streaming inflate.
- Per-chunk explicit flush API.
- `reset()` for encoder reuse.
- Multi-threaded streaming.
- Block-type optimization (3-candidate pick-smallest in streaming).
- Fixed-Huffman streaming for `.fast` level.

### Phase 23
- Tranche 23A of [RFC-0028](https://github.com/bare-swift/bare-swift/blob/main/rfcs/0028-phase-23-anchor-swift-deflate-v0.3-streaming-encoder.md). Continues codec-tier streaming sweep (Phase 22 brotli → Phase 23 deflate → Phase 24+ gzip + zlib → Phase 25+ content-encoding wiring).

## [0.2.0] - 2026-05-11

### Added
- `Deflate.encode(_:level:) -> Bytes` — RFC 1951 DEFLATE encoder.
  Produces raw bit streams (no zlib / gzip framing).
- `Deflate.Encoder` value type — single-shot encoder (streaming ships in v0.3 per RFC-0014).
- `Deflate.Encoder.Level` enum:
  - `.none` — stored blocks only (no compression).
  - `.fast` — fixed Huffman codes + short hash-chain.
  - `.default` — dynamic Huffman codes + depth-32 hash-chain.
  - `.best` — dynamic Huffman codes + depth-4096 hash-chain + lazy matching.
- Internal: `BitWriter` (LSB-first), `Matcher` (LZ77 hash-chain), `HuffmanEncoder` (canonical, length-limited via package-merge), `BlockEncoder` (dynamic block emission with run-length-encoded code-lengths).
- Block-type selection: for the dynamic-Huffman path, the encoder produces stored / fixed / dynamic candidates and emits the smallest. High-entropy inputs fall back to stored / fixed automatically; never exceeds stored-block size + epsilon.
- 51 tests in 16 suites covering API surface, stored / fixed / dynamic round-trips, matcher correctness, encode-side lookups, Huffman builder, block-type selection, and lazy matching.

### Unchanged from v0.1
- `Deflate.inflate(_:)` — bit-for-bit unchanged. v0.1 consumers can adopt v0.2 without source edits.
- `DeflateError` cases — all eight v0.1 cases preserved.

### Limitations (out of scope for v0.2)
- Streaming encoding. v0.2 takes a single full `Bytes` input; streaming API ships with v0.3.
- Zopfli-style multi-pass size optimization. v0.2 commits to *correctness*; size/speed tuning lands as v0.2.x patch releases.
- Preset dictionary encoding. Future v0.3 if requested.

## [0.1.0] - 2026-05-10

### Added
- `Deflate.inflate(_ compressed: Bytes) throws(DeflateError) -> Bytes` — RFC 1951 INFLATE single-shot decompressor.
- All three RFC 1951 block types supported: stored (`00`), fixed Huffman (`01`), dynamic Huffman (`10`). Reserved block type `11` surfaces as `.reservedBlockType`.
- `DeflateError` typed-throws enum with 8 cases covering truncation, invalid block types, malformed Huffman tables, invalid back-reference distances, and the implementation-imposed output-size cap.
- LSB-first `BitReader` with peek-and-consume API; zero-pads at EOF so end-of-block Huffman codes near the truncated tail still decode correctly.
- Canonical Huffman decoder per RFC 1951 § 3.2.2, with full table replication (shorter codes occupy `2^(maxLength - L)` slots) for one-peek-one-lookup decoding.
- Sliding-window back-references up to 32 KiB per the spec; per-byte copy handles the run-length-encoded case (length > distance) correctly.
- Output capped at 32 MiB in v0.1 (configurable limit lands in v0.2).
- 11 tests across 5 suites covering: empty stream, fixed-Huffman vectors (single literal, mixed payload, repeated-byte back-reference), dynamic-Huffman vector, stored blocks (single byte + LEN/NLEN check), and error paths (empty input, reserved block type, truncated fixed-Huffman block).

All test vectors were generated by stripping the gzip header + trailer from `gzip -c` output and verifying decompression matches the input.

### Dependencies
- `swift-bytes` 0.1.0 — input/output buffer.

### Limitations (out of scope for v0.1)
- DEFLATE encoder. Per RFC-0012 the v0.2 minor release adds compression once the decoder is stable.
- Streaming / partial decompression. v0.1 takes a single full `Bytes` payload; streaming API ships with the v0.2 encoder.
- Block-by-block introspection / debugging APIs.
- Custom dictionary preset (the 4-byte DICTID lives in zlib framing, not raw DEFLATE).
- `Codable` bridging — same Foundation-free / non-Codable differentiator as the rest of the ecosystem.
