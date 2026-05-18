// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

import Bytes

extension Deflate.Streaming {
    /// Streaming DEFLATE encoder. Feed chunks via ``update(_:)`` and
    /// terminate with ``finish()``. The encoder emits one DEFLATE block
    /// per ``update(_:)`` call (dynamic-Huffman for non-`.none` levels;
    /// stored blocks for `.none`). Each block is independent — no LZ77
    /// match search crosses chunk boundaries in v0.3 (deferred to v0.4
    /// for ratio improvement).
    ///
    /// Usage:
    /// ```swift
    /// var encoder = Deflate.Streaming.Encoder(level: .default)
    /// encoder.update(chunk1)
    /// encoder.update(chunk2)
    /// let compressed = try encoder.finish()
    /// let plain = try Deflate.inflate(compressed)
    /// // plain == chunk1 + chunk2
    /// ```
    ///
    /// `Encoder` is a value type. Copying mid-stream produces two
    /// divergent encoders. Treat as single-owner.
    ///
    /// After ``finish()`` the encoder is in the finished state.
    /// ``update(_:)`` after finish is a silent no-op; double-finish throws
    /// ``DeflateError/encoderFinished``.
    ///
    /// Streaming `.fast` / `.default` / `.best` all emit dynamic-Huffman
    /// blocks. The 3-candidate pick-smallest from
    /// ``Deflate/encode(_:level:)`` one-shot does not apply in streaming
    /// (requires future visibility).
    public struct Encoder: Sendable {
        private enum State: Sendable {
            case open
            case finished
        }

        public let level: Deflate.Encoder.Level

        private var writer: BitWriter
        private var state: State

        public init(level: Deflate.Encoder.Level = .default) {
            self.level = level
            self.writer = BitWriter()
            self.state = .open
        }

        /// Feed a chunk to the encoder. Emits one DEFLATE block per call
        /// (or N stored blocks if `level == .none` and `chunk.count > 65 535`).
        /// Empty chunk = no-op. Silent no-op when called after ``finish()``.
        public mutating func update(_ chunk: Bytes) {
            guard case .open = state else { return }
            if chunk.isEmpty { return }

            switch level {
            case .none:
                emitStoredBlocks(chunk: chunk, isFinal: false)
            case .fast, .default, .best:
                emitDynamicBlock(chunk: chunk, isFinal: false)
            }
        }

        /// Return the byte-aligned portion of the accumulated stream so far,
        /// resetting the internal byte buffer. The encoder remains in the
        /// open state — subsequent ``update(_:)`` and ``finish()`` calls
        /// produce the remainder of the stream.
        ///
        /// Concatenating all `drain()` returns with the final `finish()`
        /// return produces the **same bytes** as a single `finish()` call
        /// would have produced (byte-for-byte equality, per RFC 1951).
        ///
        /// Does NOT byte-align (the partial-byte buffer survives drain) and
        /// does NOT emit a terminator block (that is `finish()`'s job).
        /// Silent no-op (returns empty `Bytes`) when called after `finish()`.
        ///
        /// Added in v0.4 for multi-coding HTTP streaming composition via
        /// swift-content-encoding v0.6.
        public mutating func drain() -> Bytes {
            guard case .open = state else { return Bytes() }
            return writer.drain()
        }

        /// Emit a 5-byte empty stored block terminator (RFC 1951 § 3.2.4)
        /// and return the accumulated bytes. Throws
        /// ``DeflateError/encoderFinished`` on double-call.
        public mutating func finish() throws(DeflateError) -> Bytes {
            guard case .open = state else { throw .encoderFinished }
            state = .finished

            // Terminator: empty stored block with BFINAL=1.
            //   BFINAL=1, BTYPE=00, align, LEN=0x0000, NLEN=0xFFFF.
            writer.writeBits(1, count: 1)
            writer.writeBits(0, count: 2)
            writer.alignToByte()
            writer.writeByte(0x00); writer.writeByte(0x00)
            writer.writeByte(0xFF); writer.writeByte(0xFF)

            return writer.finish()
        }

        // MARK: - Internal block emit

        private mutating func emitDynamicBlock(chunk: Bytes, isFinal: Bool) {
            let tokens = collectTokens(chunk: chunk)
            BlockEncoder.emitDynamic(tokens: tokens, isFinal: isFinal, writer: &writer)
        }

        private mutating func emitStoredBlocks(chunk: Bytes, isFinal: Bool) {
            let total = chunk.storage.count
            var pos = 0
            while pos < total {
                let blockSize = Swift.min(Deflater.storedBlockMax, total - pos)
                let isLastOfChunk = (pos + blockSize) == total
                let blockIsFinal = isFinal && isLastOfChunk

                writer.writeBits(blockIsFinal ? 1 : 0, count: 1)
                writer.writeBits(0, count: 2)
                writer.alignToByte()
                let len = UInt16(blockSize)
                let nlen = ~len
                writer.writeByte(UInt8(truncatingIfNeeded: len & 0xFF))
                writer.writeByte(UInt8(truncatingIfNeeded: (len >> 8) & 0xFF))
                writer.writeByte(UInt8(truncatingIfNeeded: nlen & 0xFF))
                writer.writeByte(UInt8(truncatingIfNeeded: (nlen >> 8) & 0xFF))
                for i in 0..<blockSize {
                    writer.writeByte(chunk.storage[pos + i])
                }
                pos += blockSize
            }
        }

        /// Per-chunk LZ77. Matcher state is fresh per call (no window carry
        /// across `update(_:)` calls in v0.3).
        private func collectTokens(chunk: Bytes) -> [Token] {
            let maxChain: Int = {
                switch level {
                case .none: return 0  // unreachable; .none path uses emitStoredBlocks.
                case .fast: return 8
                case .default: return 32
                case .best: return 4096
                }
            }()
            var matcher = Matcher(chunk.storage, maxChain: maxChain)
            var tokens: [Token] = []
            let total = chunk.storage.count
            var pos = 0
            while pos < total {
                let (matchLen, matchDist) = matcher.findMatch(at: pos)
                if matchLen >= Matcher.minMatch {
                    tokens.append(.match(length: matchLen, distance: matchDist))
                    for k in 1..<matchLen where pos + k + Matcher.minMatch <= total {
                        _ = matcher.findMatch(at: pos + k)
                    }
                    pos += matchLen
                } else {
                    tokens.append(.literal(chunk.storage[pos]))
                    pos += 1
                }
            }
            return tokens
        }
    }
}

extension Deflate.Streaming {
    /// Streaming DEFLATE decoder. Feed compressed chunks via ``update(_:)``
    /// and finalize with ``finish()``. The decoder mirrors
    /// ``Deflate/Streaming/Encoder``'s shape for API symmetry.
    ///
    /// Usage:
    /// ```swift
    /// var decoder = Deflate.Streaming.Decoder()
    /// decoder.update(compressedChunk1)
    /// decoder.update(compressedChunk2)
    /// let decompressed = try decoder.finish()
    /// // decompressed == Deflate.inflate(compressedChunk1 + compressedChunk2)
    /// ```
    ///
    /// **v0.6 implementation note:** the decoder runs a state-machine
    /// `StreamingInflater` internally, yielding decoded bytes incrementally
    /// per `update(_:)` call. The reader is checkpointed before each
    /// symbol read; truncated input rewinds to the checkpoint so the
    /// next `update(_:)` resumes cleanly. v0.5's buffering-wrap path is
    /// removed; the public API surface (init/update/finish) is unchanged.
    ///
    /// `Decoder` is a value type. Copying mid-stream produces two divergent
    /// decoders. Treat as single-owner.
    ///
    /// After ``finish()`` the decoder is in the finished state.
    /// ``update(_:)`` after finish is a silent no-op; double-finish throws
    /// ``DeflateError/decoderFinished``.
    ///
    /// Added in v0.5 per RFC-0035; refactored to true memory-streaming in
    /// v0.6 per RFC-0039.
    public struct Decoder: Sendable {
        private enum State: Sendable {
            case open
            case finished
        }

        private var inflater: StreamingInflater
        private var pendingError: DeflateError?
        private var state: State

        public init() {
            self.inflater = StreamingInflater()
            self.pendingError = nil
            self.state = .open
        }

        /// Feed a chunk of compressed input. The state-machine
        /// `StreamingInflater` consumes as much as buffered input allows
        /// and pauses cleanly at a symbol checkpoint when more input is
        /// needed. Empty chunk = no-op. Silent no-op when called after
        /// ``finish()``.
        ///
        /// Real `DeflateError` cases encountered during `update(_:)` are
        /// captured and surfaced at the next ``finish()`` call (the public
        /// API contract — same as v0.5: only ``finish()`` throws decode
        /// errors).
        public mutating func update(_ chunk: Bytes) {
            guard case .open = state else { return }
            if chunk.isEmpty { return }
            if pendingError != nil { return }
            inflater.feed(chunk.storage)
            do {
                try inflater.run()
            } catch {
                pendingError = error
            }
        }

        /// Finalize the stream. If a real decode error was captured during
        /// `update(_:)`, throws it now. Otherwise runs the state machine
        /// once more (in case the last `update(_:)` paused mid-symbol with
        /// the necessary trailing bytes already available), then requires
        /// the machine to have reached `.done`. Returns the accumulated
        /// decoded bytes.
        ///
        /// Throws ``DeflateError/decoderFinished`` on double-call. Throws
        /// other `DeflateError` cases (e.g. `.truncated`,
        /// `.invalidHuffmanTable`) if the buffered input is not a complete
        /// valid DEFLATE stream.
        public mutating func finish() throws(DeflateError) -> Bytes {
            guard case .open = state else { throw .decoderFinished }
            state = .finished
            if let err = pendingError {
                throw err
            }
            do {
                try inflater.run()
            } catch {
                throw error
            }
            switch inflater.phase {
            case .done:
                return Bytes(inflater.output)
            default:
                // Stream paused expecting more input that never arrived.
                throw .truncated
            }
        }
    }
}
