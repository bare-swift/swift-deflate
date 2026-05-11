// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
// Copyright (c) 2026 The bare-swift Project Authors.

/// LZ77 hash-chain match finder over a sliding 32 KiB window.
///
/// `findMatch(at:)` must be called for every position 0..<input.count
/// in order — it both records the position in the hash chain and queries
/// for the best match ending at that position.
struct Matcher {
    static let minMatch = 3
    static let maxMatch = 258
    static let windowSize = 32_768
    static let hashBits = 15
    static let hashSize = 1 << hashBits
    static let hashMask = UInt32(hashSize - 1)

    private let input: ContiguousArray<UInt8>
    private let maxChain: Int

    /// `head[h]` = the most recent position whose 3-byte hash is `h`, or
    /// `-1` if no such position has been seen.
    private var head: [Int]

    /// `prev[i & (windowSize-1)]` = the previous position with the same
    /// 3-byte hash as position `i`, or `-1` if `i` was the first.
    private var prev: [Int]

    init(_ input: ContiguousArray<UInt8>, maxChain: Int) {
        self.input = input
        self.maxChain = maxChain
        self.head = [Int](repeating: -1, count: Self.hashSize)
        self.prev = [Int](repeating: -1, count: Self.windowSize)
    }

    /// Returns `(length, distance)` for the best match at `pos`, or
    /// `(0, 0)` if no 3-byte match is found. Also inserts `pos` into the
    /// hash chain so future positions can find it.
    mutating func findMatch(at pos: Int) -> (length: Int, distance: Int) {
        guard pos + Self.minMatch <= input.count else {
            return (0, 0)
        }
        let h = hash3(at: pos)
        let chainStart = head[Int(h)]
        head[Int(h)] = pos
        prev[pos & (Self.windowSize - 1)] = chainStart

        guard chainStart >= 0 else { return (0, 0) }

        var bestLen = 0
        var bestDist = 0
        var candidate = chainStart
        var chainLeft = maxChain
        let minPos = max(0, pos - Self.windowSize)
        let maxLen = min(Self.maxMatch, input.count - pos)

        while candidate >= minPos && chainLeft > 0 {
            if bestLen >= maxLen { break }  // already maximal — no point continuing.
            if bestLen >= Self.minMatch {
                if input[candidate + bestLen] != input[pos + bestLen] {
                    candidate = prev[candidate & (Self.windowSize - 1)]
                    chainLeft -= 1
                    continue
                }
            }
            var k = 0
            while k < maxLen && input[candidate + k] == input[pos + k] {
                k += 1
            }
            if k >= Self.minMatch && k > bestLen {
                bestLen = k
                bestDist = pos - candidate
                if k >= Self.maxMatch { break }
            }
            candidate = prev[candidate & (Self.windowSize - 1)]
            chainLeft -= 1
        }
        return (bestLen, bestDist)
    }

    private func hash3(at pos: Int) -> UInt32 {
        let a = UInt32(input[pos])
        let b = UInt32(input[pos + 1])
        let c = UInt32(input[pos + 2])
        let h = (a &<< 10) ^ (b &<< 5) ^ c
        return h & Self.hashMask
    }
}
